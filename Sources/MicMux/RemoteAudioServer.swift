import Foundation
import IrohLib
import MicMuxShared
import Security

struct RemoteSourceDescriptor: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let detail: String
  let connected: Bool
  let rttMilliseconds: UInt64?
}

/// Accepts authenticated iroh phone streams and exposes them as ordinary MicMux sources.
final class RemoteAudioServer {
  var onInvitation: ((String?) -> Void)?
  var onSourcesChanged: (([RemoteSourceDescriptor]) -> Void)?
  var onSamples: ((String, [Float], Double) -> Void)?
  var onStatus: ((String) -> Void)?

  private let stateLock = NSLock()
  private var endpoint: Endpoint?
  private var runTask: Task<Void, Never>?
  private var sources: [String: RemoteSourceDescriptor] = [:]
  private var pairingSecret = Data()

  func start() {
    stateLock.withLock {
      guard runTask == nil else { return }
      runTask = Task { [weak self] in
        guard let self else { return }
        await self.run()
      }
    }
  }

  func stop() {
    let (task, endpoint) = stateLock.withLock {
      let values = (runTask, self.endpoint)
      runTask = nil
      self.endpoint = nil
      return values
    }
    task?.cancel()
    if let endpoint {
      Task { try? await endpoint.close() }
    }
  }

  private func run() async {
    publishStatus("Starting secure iroh receiver…")
    do {
      let identity = try PersistentIrohIdentity.loadOrCreate()
      pairingSecret = identity.pairingSecret
      let endpoint = try await Endpoint.bind(
        options: EndpointOptions(
          preset: presetN0(),
          secretKey: identity.secretKey,
          alpns: [MicMuxWire.alpn]
        )
      )
      stateLock.withLock { self.endpoint = endpoint }

      try publishInvitation(for: endpoint)
      publishStatus("iPhone receiver ready on LAN; establishing relay fallback…")
      Task { [weak self] in
        await endpoint.online()
        guard !Task.isCancelled else { return }
        try? self?.publishInvitation(for: endpoint)
        self?.publishStatus("iPhone receiver ready")
      }

      while !Task.isCancelled, let incoming = await endpoint.acceptNext() {
        Task { [weak self] in await self?.handle(incoming) }
      }
    } catch {
      publishStatus("iPhone receiver failed: \(error.localizedDescription)")
      publishInvitation(nil)
    }
    stateLock.withLock {
      endpoint = nil
      runTask = nil
    }
  }

  private func handle(_ incoming: Incoming) async {
    var sourceID: String?
    do {
      let accepting = try await incoming.accept()
      guard try await accepting.alpn() == MicMuxWire.alpn else {
        throw ServerError.unsupportedProtocol
      }
      let connection = try await accepting.connect()
      let control = try await connection.acceptBi()
      let hello: MicMuxWire.Hello = try await readControl(from: control.recv())
      guard hello.version == MicMuxWire.version,
        constantTimeEqual(hello.secret, pairingSecret),
        !hello.sourceID.isEmpty,
        !hello.sourceName.isEmpty,
        hello.sampleRate > 0
      else {
        try await writeControl(
          MicMuxWire.Acknowledgement(accepted: false, message: "Pairing secret rejected"),
          to: control.send()
        )
        throw ServerError.authenticationFailed
      }

      let remoteID = connection.remoteId().description
      let stableID = "iroh:\(remoteID):\(hello.sourceID)"
      sourceID = stableID
      updateSource(
        RemoteSourceDescriptor(
          id: stableID,
          name: hello.sourceName,
          detail: "\(hello.routeKind) via iPhone",
          connected: true,
          rttMilliseconds: connection.rtt()
        )
      )
      try await writeControl(
        MicMuxWire.Acknowledgement(accepted: true, message: "Connected to MicMux"),
        to: control.send()
      )

      var lastSequence: UInt64?
      while !Task.isCancelled {
        let data = try await connection.readDatagram()
        let packet = try MicMuxWire.AudioPacket.decode(data)
        if let lastSequence, packet.sequence <= lastSequence { continue }
        lastSequence = packet.sequence
        onSamples?(stableID, packet.samples, Double(packet.sampleRate))
      }
    } catch {
      if let sourceID { markDisconnected(sourceID) }
      if !isExpectedConnectionEnd(error) {
        publishStatus("Phone stream ended: \(error.localizedDescription)")
      }
    }
  }

  private func readControl<Value: Decodable>(from stream: RecvStream) async throws -> Value {
    let header = try await stream.readExact(size: 4)
    let length = try MicMuxWire.controlBodyLength(from: header)
    let body = try await stream.readExact(size: UInt32(length))
    return try JSONDecoder().decode(Value.self, from: body)
  }

  private func writeControl<Value: Encodable>(_ value: Value, to stream: SendStream) async throws {
    try await stream.writeAll(buf: MicMuxWire.encodeControl(value))
    try await stream.finish()
  }

  private func publishInvitation(for endpoint: Endpoint) throws {
    let ticket = try EndpointTicket.fromAddr(addr: endpoint.addr()).description
    let invitation = try MicMuxWire.PairingInvitation(
      ticket: ticket,
      secret: pairingSecret,
      receiverName: Host.current().localizedName ?? "Mac"
    )
    publishInvitation(invitation.urlString)
  }

  private func publishInvitation(_ value: String?) {
    DispatchQueue.main.async { [weak self] in self?.onInvitation?(value) }
  }

  private func publishStatus(_ value: String) {
    DispatchQueue.main.async { [weak self] in self?.onStatus?(value) }
  }

  private func updateSource(_ source: RemoteSourceDescriptor) {
    let snapshot = stateLock.withLock {
      sources[source.id] = source
      return sources.values.sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    }
    DispatchQueue.main.async { [weak self] in self?.onSourcesChanged?(snapshot) }
  }

  private func markDisconnected(_ id: String) {
    let snapshot = stateLock.withLock {
      if let source = sources[id] {
        sources[id] = RemoteSourceDescriptor(
          id: source.id,
          name: source.name,
          detail: source.detail,
          connected: false,
          rttMilliseconds: source.rttMilliseconds
        )
      }
      return sources.values.sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    }
    DispatchQueue.main.async { [weak self] in self?.onSourcesChanged?(snapshot) }
  }

  private func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for (leftByte, rightByte) in zip(left, right) { difference |= leftByte ^ rightByte }
    return difference == 0
  }

  private func isExpectedConnectionEnd(_ error: Error) -> Bool {
    let description = error.localizedDescription.lowercased()
    return description.contains("closed") || description.contains("cancel")
  }

  deinit { stop() }

  private enum ServerError: LocalizedError {
    case authenticationFailed
    case unsupportedProtocol

    var errorDescription: String? {
      switch self {
      case .authenticationFailed: return "The phone did not present the pairing secret."
      case .unsupportedProtocol: return "The phone used an unsupported MicMux protocol."
      }
    }
  }
}

private enum PersistentIrohIdentity {
  struct Values {
    let secretKey: Data
    let pairingSecret: Data
  }

  static func loadOrCreate() throws -> Values {
    let fileManager = FileManager.default
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("MicMux", isDirectory: true)
    try fileManager.createDirectory(
      at: base,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return Values(
      secretKey: try loadOrCreate(path: base.appendingPathComponent("iroh-secret-key")),
      pairingSecret: try loadOrCreate(path: base.appendingPathComponent("pairing-secret"))
    )
  }

  private static func loadOrCreate(path: URL) throws -> Data {
    if let existing = try? Data(contentsOf: path), existing.count == 32 { return existing }
    var value = Data(count: 32)
    let status = value.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
    }
    guard status == errSecSuccess else { throw IdentityError.randomGenerationFailed(status) }
    try value.write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    return value
  }

  private enum IdentityError: LocalizedError {
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
      guard case .randomGenerationFailed(let status) = self else { return nil }
      return "Could not generate the MicMux pairing identity: OSStatus \(status)"
    }
  }
}
