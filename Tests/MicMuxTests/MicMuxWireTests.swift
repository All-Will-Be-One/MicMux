import Foundation
import XCTest

@testable import MicMuxShared

final class MicMuxWireTests: XCTestCase {
  func test_pairing_invitation_round_trips_reserved_characters() throws {
    let invitation = try MicMuxWire.PairingInvitation(
      ticket: "endpoint+ticket/with=symbols",
      secret: Data(0..<32),
      receiverName: "Fish's MacBook"
    )
    XCTAssertEqual(try MicMuxWire.PairingInvitation.parse(invitation.urlString), invitation)
  }

  func test_pcm_packet_round_trips_with_bounded_quantization_error() throws {
    let samples: [Float] = [-1, -0.5, 0, 0.25, 0.999]
    let packet = try MicMuxWire.AudioPacket(sequence: 42, sampleRate: 48_000, samples: samples)
    let decoded = try MicMuxWire.AudioPacket.decode(packet.encode())

    XCTAssertEqual(decoded.sequence, 42)
    XCTAssertEqual(decoded.sampleRate, 48_000)
    XCTAssertEqual(decoded.samples.count, samples.count)
    for (actual, expected) in zip(decoded.samples, samples) {
      XCTAssertEqual(actual, expected, accuracy: 1 / Float(Int16.max))
    }
  }

  func test_oversized_audio_datagram_is_refused() {
    XCTAssertThrowsError(
      try MicMuxWire.AudioPacket(
        sequence: 1,
        sampleRate: 48_000,
        samples: [Float](repeating: 0, count: MicMuxWire.maximumDatagramSamples + 1)
      )
    )
  }

  func test_control_message_carries_an_explicit_bounded_length() throws {
    let hello = MicMuxWire.Hello(
      secret: Data(repeating: 7, count: 32),
      sourceID: "phone/airpods",
      sourceName: "AirPods Pro",
      routeKind: "Bluetooth HFP",
      sampleRate: 48_000
    )
    let framed = try MicMuxWire.encodeControl(hello)
    let length = try MicMuxWire.controlBodyLength(from: framed.prefix(4))
    let decoded = try JSONDecoder().decode(MicMuxWire.Hello.self, from: framed.dropFirst(4))

    XCTAssertEqual(length, framed.count - 4)
    XCTAssertEqual(decoded, hello)
  }
}
