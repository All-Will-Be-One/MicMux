import Foundation
import IrohLib
import XCTest

@testable import MicMux
@testable import MicMuxShared

final class RemoteAudioServerTests: XCTestCase {
  func test_authenticated_iroh_phone_audio_reaches_the_remote_source_boundary() async throws {
    let invitationReady = expectation(description: "server publishes invitation")
    let sourceReady = expectation(description: "server publishes remote source")
    let samplesReady = expectation(description: "server receives audio")
    let server = RemoteAudioServer()
    var invitationValue: String?
    var receivedSamples: [Float]?

    server.onInvitation = { value in
      guard let value else { return }
      invitationValue = value
      invitationReady.fulfill()
    }
    server.onSourcesChanged = { sources in
      if sources.contains(where: { $0.connected && $0.name == "Test AirPods" }) {
        sourceReady.fulfill()
      }
    }
    server.onSamples = { _, samples, _ in
      receivedSamples = samples
      samplesReady.fulfill()
    }
    server.start()
    defer { server.stop() }
    await fulfillment(of: [invitationReady], timeout: 8)

    let invitation = try MicMuxWire.PairingInvitation.parse(try XCTUnwrap(invitationValue))
    let ticket = try EndpointTicket.fromString(str: invitation.ticket)
    let client = try await Endpoint.bind(
      options: EndpointOptions(preset: presetMinimal(), alpns: [MicMuxWire.alpn])
    )
    defer { Task { try? await client.close() } }
    let connection = try await client.connect(addr: ticket.endpointAddr(), alpn: MicMuxWire.alpn)
    let control = try await connection.openBi()
    let hello = MicMuxWire.Hello(
      secret: invitation.secret,
      sourceID: "test-phone/airpods",
      sourceName: "Test AirPods",
      routeKind: "Bluetooth HFP",
      sampleRate: 48_000
    )
    try await control.send().writeAll(buf: MicMuxWire.encodeControl(hello))
    try await control.send().finish()
    let header = try await control.recv().readExact(size: 4)
    let length = try MicMuxWire.controlBodyLength(from: header)
    let body = try await control.recv().readExact(size: UInt32(length))
    let acknowledgement = try JSONDecoder().decode(
      MicMuxWire.Acknowledgement.self,
      from: body
    )
    XCTAssertTrue(acknowledgement.accepted)

    let packet = try MicMuxWire.AudioPacket(
      sequence: 0,
      sampleRate: 48_000,
      samples: [0.25, -0.25, 0.5]
    )
    try await connection.sendDatagramWait(data: packet.encode())
    await fulfillment(of: [sourceReady, samplesReady], timeout: 5)

    let samples = try XCTUnwrap(receivedSamples)
    XCTAssertEqual(samples[0], 0.25, accuracy: 0.000_1)
    XCTAssertEqual(samples[1], -0.25, accuracy: 0.000_1)
    XCTAssertEqual(samples[2], 0.5, accuracy: 0.000_1)
  }
}
