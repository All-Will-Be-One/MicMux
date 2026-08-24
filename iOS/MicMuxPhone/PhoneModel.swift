import AVFoundation
import Foundation
import Security
import UIKit

struct CapturedPhoneFrame: Sendable {
  let samples: [Float]
  let sampleRate: Double
}

/// Main-actor state for pairing, route choice, and the bounded capture-to-network bridge.
@MainActor
final class PhoneModel: ObservableObject {
  @Published var invitationText: String {
    didSet { PairingKeychain.save(invitationText) }
  }
  @Published private(set) var routes: [PhoneInputRoute] = []
  @Published var selectedRouteID = ""
  @Published var highQualityAirPods = false
  @Published private(set) var currentRouteID = ""
  @Published private(set) var activeRoute: PhoneInputRoute?
  @Published private(set) var running = false
  @Published private(set) var status = "Pair with the MicMux app on your Mac."
  @Published private(set) var rttMilliseconds: UInt64?
  @Published var showingScanner = false

  private let capture = PhoneAudioCapture()
  private let client = PhoneIrohClient()
  private let frameContinuation: AsyncStream<CapturedPhoneFrame>.Continuation
  private var frameTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?

  init() {
    invitationText = PairingKeychain.load() ?? ""
    var continuation: AsyncStream<CapturedPhoneFrame>.Continuation!
    let frames = AsyncStream<CapturedPhoneFrame>(bufferingPolicy: .bufferingNewest(8)) {
      continuation = $0
    }
    frameContinuation = continuation
    frameTask = Task { [weak self, client] in
      for await frame in frames {
        do {
          try await client.send(samples: frame.samples, sampleRate: frame.sampleRate)
          let rtt = await client.roundTripMilliseconds()
          await MainActor.run { self?.rttMilliseconds = rtt }
        } catch {
          await MainActor.run {
            guard self?.running == true else { return }
            self?.status = "Audio link failed: \(error.localizedDescription)"
            self?.running = false
            self?.capture.stop()
          }
        }
      }
    }
    capture.onRoutesChanged = { [weak self] routes, currentID in
      Task { @MainActor in
        self?.routes = routes
        self?.currentRouteID = currentID ?? ""
        if self?.selectedRouteID.isEmpty == true {
          self?.selectedRouteID = currentID ?? routes.first?.id ?? ""
        }
      }
    }
    capture.onInterruption = { [weak self] message in
      Task { @MainActor in self?.status = message }
    }
    capture.onRouteInvalidated = { [weak self] message in
      Task { @MainActor in
        guard let self, self.running else { return }
        self.operationTask?.cancel()
        self.capture.stop()
        self.running = false
        self.activeRoute = nil
        self.rttMilliseconds = nil
        self.status = message
        Task { await self.client.disconnect() }
      }
    }
  }

  func requestPermissionAndDiscover() {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      discoverRoutes()
    case .undetermined:
      AVAudioApplication.requestRecordPermission { [weak self] granted in
        Task { @MainActor in
          if granted {
            self?.discoverRoutes()
          } else {
            self?.status = "Microphone access was denied."
          }
        }
      }
    case .denied:
      status = "Enable MicMux Phone under Settings › Privacy & Security › Microphone."
    @unknown default:
      status = "iOS returned an unknown microphone permission state."
    }
  }

  func toggle() {
    running ? stop() : start()
  }

  func start() {
    guard AVAudioApplication.shared.recordPermission == .granted else {
      requestPermissionAndDiscover()
      return
    }
    operationTask?.cancel()
    operationTask = Task { [weak self] in
      await self?.startStreaming()
    }
  }

  func stop() {
    operationTask?.cancel()
    operationTask = nil
    capture.stop()
    running = false
    activeRoute = nil
    rttMilliseconds = nil
    status = "Stopped"
    Task { await client.disconnect() }
  }

  func selectRoute(_ id: String) {
    guard id != selectedRouteID else { return }
    selectedRouteID = id
    guard running else {
      if let route = routes.first(where: { $0.id == id }) {
        status = "Selected \(route.name)."
      }
      return
    }

    operationTask?.cancel()
    capture.stop()
    running = false
    activeRoute = nil
    rttMilliseconds = nil
    status = "Switching microphone…"
    operationTask = Task { [weak self] in
      guard let self else { return }
      await self.client.disconnect()
      guard !Task.isCancelled else { return }
      await self.startStreaming()
    }
  }

  func acceptPairingURL(_ url: URL) {
    invitationText = url.absoluteString
    status = "Pairing invitation loaded."
  }

  func acceptScannedCode(_ value: String) {
    showingScanner = false
    guard (try? MicMuxWire.PairingInvitation.parse(value)) != nil else {
      status = "That QR code is not a MicMux invitation."
      return
    }
    invitationText = value
    status = "Pairing invitation loaded."
  }

  func openScanner() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      showingScanner = true
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor in
          if granted {
            self?.showingScanner = true
          } else {
            self?.status = "Camera access is needed only to scan the Mac's pairing QR code."
          }
        }
      }
    default:
      status = "Enable Camera access in Settings, or paste the invitation instead."
    }
  }

  func pasteInvitation() {
    if let value = UIPasteboard.general.string {
      invitationText = value
      status = "Pairing invitation pasted."
    }
  }

  private func discoverRoutes() {
    do {
      routes = try capture.discoverRoutes(highQualityBluetooth: highQualityAirPods)
      if !routes.contains(where: { $0.id == selectedRouteID }) {
        selectedRouteID = routes.first?.id ?? ""
      }
      status =
        routes.isEmpty ? "No microphone routes found." : "Choose a microphone and start streaming."
    } catch {
      status = error.localizedDescription
    }
  }

  private func startStreaming() async {
    do {
      status = "Selecting microphone…"
      let invitation = try MicMuxWire.PairingInvitation.parse(invitationText)
      let input = try await capture.prepare(
        preferredID: selectedRouteID.isEmpty ? nil : selectedRouteID,
        highQualityBluetooth: highQualityAirPods
      )
      try Task.checkCancellation()
      activeRoute = input.route
      currentRouteID = input.route.id
      selectedRouteID = input.route.id
      let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "iphone"
      let hello = MicMuxWire.Hello(
        secret: invitation.secret,
        sourceID: "\(deviceID)/\(input.route.id)",
        sourceName: input.route.name,
        routeKind: input.route.kind,
        sampleRate: input.sampleRate
      )
      status = "Connecting to \(invitation.receiverName)…"
      try await client.connect(invitation: invitation, hello: hello)
      try Task.checkCancellation()
      try capture.start { [frameContinuation] samples, rate in
        frameContinuation.yield(CapturedPhoneFrame(samples: samples, sampleRate: rate))
      }
      running = true
      status = "Streaming \(input.route.name) (\(input.route.kind)) to \(invitation.receiverName)"
    } catch {
      capture.stop()
      await client.disconnect()
      activeRoute = nil
      running = false
      rttMilliseconds = nil
      guard !Task.isCancelled else { return }
      status = error.localizedDescription
    }
  }

  deinit {
    operationTask?.cancel()
    frameContinuation.finish()
    frameTask?.cancel()
    capture.stop()
  }
}

private enum PairingKeychain {
  private static let service = "audio.micmux.phone"
  private static let account = "pairing-invitation"

  static func load() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ value: String) {
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
    let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insertion = identity
      insertion[kSecValueData as String] = Data(value.utf8)
      insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(insertion as CFDictionary, nil)
    }
  }
}
