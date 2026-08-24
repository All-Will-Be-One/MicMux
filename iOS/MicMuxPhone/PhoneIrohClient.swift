import Foundation
import IrohLib

/// Dials the Mac by iroh key and keeps network work off the audio callback.
actor PhoneIrohClient {
  private var endpoint: Endpoint?
  private var connection: Connection?
  private var sequence: UInt64 = 0

  func connect(invitation: MicMuxWire.PairingInvitation, hello: MicMuxWire.Hello) async throws {
    await disconnect()
    let ticket = try EndpointTicket.fromString(str: invitation.ticket)
    let endpoint = try await Endpoint.bind(
      options: EndpointOptions(preset: presetN0(), alpns: [MicMuxWire.alpn])
    )
    let connection = try await endpoint.connect(
      addr: ticket.endpointAddr(),
      alpn: MicMuxWire.alpn
    )
    let control = try await connection.openBi()
    try await control.send().writeAll(buf: MicMuxWire.encodeControl(hello))
    try await control.send().finish()
    let acknowledgement: MicMuxWire.Acknowledgement = try await readControl(
      from: control.recv())
    guard acknowledgement.accepted else {
      throw ClientError.rejected(acknowledgement.message)
    }
    self.endpoint = endpoint
    self.connection = connection
    sequence = 0
  }

  func send(samples: [Float], sampleRate: Double) async throws {
    guard let connection else { throw ClientError.notConnected }
    let rate = UInt32(max(1, min(Double(UInt32.max), sampleRate.rounded())))
    for start in stride(from: 0, to: samples.count, by: MicMuxWire.maximumDatagramSamples) {
      let end = min(samples.count, start + MicMuxWire.maximumDatagramSamples)
      let packet = try MicMuxWire.AudioPacket(
        sequence: sequence,
        sampleRate: rate,
        samples: Array(samples[start..<end])
      )
      sequence &+= 1
      try await connection.sendDatagramWait(data: packet.encode())
    }
  }

  func roundTripMilliseconds() -> UInt64? {
    connection?.rtt()
  }

  func disconnect() async {
    if let connection {
      try? connection.close(errorCode: 0, reason: Data("stopped".utf8))
    }
    connection = nil
    if let endpoint { try? await endpoint.close() }
    endpoint = nil
  }

  private func readControl<Value: Decodable>(from stream: RecvStream) async throws -> Value {
    let header = try await stream.readExact(size: 4)
    let length = try MicMuxWire.controlBodyLength(from: header)
    let body = try await stream.readExact(size: UInt32(length))
    return try JSONDecoder().decode(Value.self, from: body)
  }

  enum ClientError: LocalizedError {
    case notConnected
    case rejected(String)

    var errorDescription: String? {
      switch self {
      case .notConnected: return "The iPhone is not connected to MicMux."
      case .rejected(let message): return "The Mac rejected this phone: \(message)"
      }
    }
  }
}
