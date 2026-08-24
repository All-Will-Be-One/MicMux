import AVFoundation
import Foundation
import os

struct PhoneInputRoute: Identifiable, Equatable {
  let id: String
  let name: String
  let kind: String
  let isBluetooth: Bool
}

struct PreparedPhoneInput {
  let route: PhoneInputRoute
  let sampleRate: Double
}

/// Owns the single iOS audio session and follows Meta's robust HFP capture pattern.
final class PhoneAudioCapture {
  var onRoutesChanged: (([PhoneInputRoute], String?) -> Void)?
  var onInterruption: ((String) -> Void)?
  var onRouteInvalidated: ((String) -> Void)?

  private var engine = AVAudioEngine()
  private var routeObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var tapInstalled = false
  private var prepared: PreparedPhoneInput?
  private var routeValidationTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "audio.micmux.phone", category: "audio-route")

  init() {
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      self?.routeDidChange()
    }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handleInterruption(notification)
    }
  }

  func discoverRoutes(highQualityBluetooth: Bool) throws -> [PhoneInputRoute] {
    try configureSession(highQualityBluetooth: highQualityBluetooth)
    return routes()
  }

  func prepare(
    preferredID: String?,
    highQualityBluetooth: Bool
  ) async throws -> PreparedPhoneInput {
    stopEngine(deactivate: false)
    prepared = nil
    try configureSession(highQualityBluetooth: highQualityBluetooth)
    let session = AVAudioSession.sharedInstance()
    let preferred: AVAudioSessionPortDescription?
    if let preferredID {
      guard let available = session.availableInputs?.first(where: { $0.uid == preferredID }) else {
        throw CaptureError.inputUnavailable(preferredID)
      }
      preferred = available
      try session.setPreferredInput(preferred)
    } else {
      preferred = nil
    }

    let input = try await waitForCurrentInput(expected: preferred)
    // AVAudioEngine caches the hardware graph it first observes. Build it only after
    // iOS confirms the requested HFP route so its input node cannot retain the phone mic.
    engine = AVAudioEngine()
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
    let prepared = PreparedPhoneInput(route: describe(input), sampleRate: format.sampleRate)
    self.prepared = prepared
    logger.info(
      "Prepared input name=\(input.portName, privacy: .public) type=\(input.portType.rawValue, privacy: .public) uid=\(input.uid, privacy: .private(mask: .hash)) rate=\(format.sampleRate, privacy: .public)"
    )
    publishRoutes()
    return prepared
  }

  func start(onSamples: @escaping @Sendable ([Float], Double) -> Void) throws {
    guard let prepared else { throw CaptureError.notPrepared }
    let current = AVAudioSession.sharedInstance().currentRoute.inputs.first
    guard current?.uid == prepared.route.id else {
      throw CaptureError.routeDidNotChange(
        requested: prepared.route.name,
        actual: current?.portName ?? "no input"
      )
    }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }

    input.installTap(onBus: 0, bufferSize: 480, format: format) { buffer, _ in
      guard let channel = buffer.floatChannelData?[0] else { return }
      let count = Int(buffer.frameLength)
      let samples = Array(UnsafeBufferPointer(start: channel, count: count))
      onSamples(samples, buffer.format.sampleRate)
    }
    tapInstalled = true
    engine.prepare()
    try engine.start()
  }

  func stop() {
    routeValidationTask?.cancel()
    routeValidationTask = nil
    stopEngine(deactivate: true)
    prepared = nil
  }

  private func configureSession(highQualityBluetooth: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .mixWithOthers]
    if #available(iOS 26.0, *), highQualityBluetooth {
      options.insert(.bluetoothHighQualityRecording)
    }
    try session.setCategory(.playAndRecord, mode: .default, options: options)
    try session.setActive(true)
  }

  private func stopEngine(deactivate: Bool) {
    if engine.isRunning { engine.stop() }
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine.reset()
    if deactivate {
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    }
  }

  private func routes() -> [PhoneInputRoute] {
    (AVAudioSession.sharedInstance().availableInputs ?? []).map(describe)
  }

  private func waitForCurrentInput(
    expected: AVAudioSessionPortDescription?
  ) async throws -> AVAudioSessionPortDescription {
    let session = AVAudioSession.sharedInstance()
    let expectedID = expected?.uid
    for _ in 0..<40 {
      try Task.checkCancellation()
      if let current = session.currentRoute.inputs.first,
        expectedID == nil || current.uid == expectedID
      {
        return current
      }
      try await Task.sleep(nanoseconds: 75_000_000)
    }
    throw CaptureError.routeDidNotChange(
      requested: expected?.portName ?? "an available microphone",
      actual: session.currentRoute.inputs.first?.portName ?? "no input"
    )
  }

  private func describe(_ port: AVAudioSessionPortDescription) -> PhoneInputRoute {
    PhoneInputRoute(
      id: port.uid,
      name: port.portName,
      kind: routeKind(port.portType),
      isBluetooth: port.portType == .bluetoothHFP
    )
  }

  private func routeKind(_ type: AVAudioSession.Port) -> String {
    switch type {
    case .bluetoothHFP: return "Bluetooth HFP"
    case .builtInMic: return "iPhone microphone"
    case .headsetMic: return "Headset microphone"
    case .usbAudio: return "USB microphone"
    case .carAudio: return "Car audio"
    default: return type.rawValue
    }
  }

  private func publishRoutes() {
    let current = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
    onRoutesChanged?(routes(), current)
  }

  private func routeDidChange() {
    publishRoutes()
    routeValidationTask?.cancel()
    guard let prepared else { return }
    routeValidationTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled, let self else { return }
      let current = AVAudioSession.sharedInstance().currentRoute.inputs.first
      guard current?.uid != prepared.route.id else { return }
      let actual = current?.portName ?? "no input"
      self.logger.error(
        "Active input changed unexpectedly requested=\(prepared.route.name, privacy: .public) actual=\(actual, privacy: .public)"
      )
      self.onRouteInvalidated?(
        "iOS changed the microphone from \(prepared.route.name) to \(actual). Reconnect the headset and try again."
      )
    }
  }

  private func handleInterruption(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    if type == .began {
      engine.pause()
      onInterruption?("Audio was interrupted. Tap Resume when the call or Siri ends.")
    }
  }

  deinit {
    routeValidationTask?.cancel()
    stop()
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
  }

  enum CaptureError: LocalizedError {
    case noInput
    case notPrepared
    case inputUnavailable(String)
    case routeDidNotChange(requested: String, actual: String)

    var errorDescription: String? {
      switch self {
      case .noInput: return "iOS did not provide a usable microphone route."
      case .notPrepared: return "Choose a microphone before starting capture."
      case .inputUnavailable:
        return "That microphone is no longer available. Reconnect it and refresh the list."
      case .routeDidNotChange(let requested, let actual):
        return
          "iOS kept \(actual) active instead of \(requested). Confirm the headset is connected for calls, then try again."
      }
    }
  }
}
