import AVFoundation
import XCTest

@testable import MicMux

final class AudioAlgorithmsTests: XCTestCase {
  func test_capture_buffer_advertises_writable_bytes_before_audio_unit_render() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
    )
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))

    XCTAssertTrue(prepareBufferForAudioUnitRender(buffer, frameCount: 512))
    XCTAssertEqual(buffer.frameLength, 512)
    XCTAssertTrue(
      UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).allSatisfy {
        $0.mData != nil && $0.mDataByteSize == 512 * UInt32(MemoryLayout<Float>.size)
      }
    )
  }

  func test_ring_buffer_keeps_the_newest_samples_after_overflow() {
    var ring = FloatRingBuffer(capacity: 4)
    ring.append([1, 2, 3, 4, 5, 6])
    var output = [Float](repeating: 0, count: 4)
    let read = output.withUnsafeMutableBufferPointer {
      ring.read(into: $0.baseAddress!, count: $0.count)
    }
    XCTAssertEqual(read, 4)
    XCTAssertEqual(output, [3, 4, 5, 6])
  }

  func test_ring_buffer_can_be_consumed_one_realtime_sample_at_a_time() {
    var ring = FloatRingBuffer(capacity: 3)
    ring.append([0.1, 0.2])
    XCTAssertEqual(ring.popFirst(), 0.1)
    XCTAssertEqual(ring.popFirst(), 0.2)
    XCTAssertNil(ring.popFirst())
  }

  func test_blend_favors_the_clearer_voiced_microphone_without_clipping() {
    let mixed = VoiceBlendMixer.mix([
      BlendInput(samples: [0.8, 0.8], score: 20, voiceActive: true),
      BlendInput(samples: [-0.8, -0.8], score: 2, voiceActive: true),
    ])

    XCTAssertEqual(mixed.count, 2)
    XCTAssertGreaterThan(mixed[0], 0.55)
    XCTAssertLessThanOrEqual(mixed[0], 1)
  }

  func test_echo_canceller_learns_a_delayed_speaker_reference() {
    var state: UInt32 = 0x1234_5678
    let reference = (0..<12_000).map { _ -> Float in
      state = state &* 1_664_525 &+ 1_013_904_223
      return (Float(state & 0xFFFF) / Float(UInt16.max) - 0.5) * 0.35
    }
    let delay = 12
    let microphone = reference.indices.map { index in
      index >= delay ? reference[index - delay] * 0.7 : 0
    }
    let canceller = AdaptiveEchoCanceller(
      filterLength: 48,
      delayFrames: delay,
      stepSize: 0.3
    )
    var cleaned: [Float] = []
    for start in stride(from: 0, to: reference.count, by: 240) {
      let end = min(reference.count, start + 240)
      cleaned += canceller.process(
        microphone: Array(microphone[start..<end]),
        reference: Array(reference[start..<end])
      )
    }

    let tail = cleaned.suffix(2_000)
    let residual = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
    XCTAssertLessThan(residual, 0.015)
  }

  func test_resampler_preserves_duration_across_common_voice_rates() {
    let resampler = StreamingLinearResampler(sourceRate: 44_100, targetRate: 48_000)
    let input = [Float](repeating: 0.25, count: 4_410)
    let output = resampler.process(input)
    XCTAssertEqual(output.count, 4_800, accuracy: 2)
    XCTAssertTrue(output.allSatisfy { abs($0 - 0.25) < 0.0001 })
  }

  func test_quality_tracker_learns_quiet_then_detects_nearby_speech() {
    let tracker = SignalQualityTracker()
    for _ in 0..<14 {
      _ = tracker.update(samples: [Float](repeating: 0.001, count: 480))
    }
    let speech = tracker.update(samples: [Float](repeating: 0.04, count: 480))
    XCTAssertTrue(speech.voiceActive)
    XCTAssertGreaterThan(speech.snrDB, 20)
    XCTAssertGreaterThan(speech.score, 10)
  }

  func test_live_catalog_returns_well_formed_devices_without_opening_them() {
    let snapshot = AudioDeviceCatalog.snapshot()
    for device in snapshot.inputs + snapshot.outputs {
      XCTAssertFalse(device.uid.isEmpty)
      XCTAssertFalse(device.name.isEmpty)
    }
  }

  func test_selector_requires_a_sustained_quality_advantage() {
    var selector = AutomaticSelector()
    let first = [
      SourceCandidate(id: "desk", score: 12, voiceActive: true, eligible: true),
      SourceCandidate(id: "bed", score: 8, voiceActive: true, eligible: true),
    ]
    XCTAssertEqual(selector.choose(candidates: first, now: 0), "desk")

    let challenger = [
      SourceCandidate(id: "desk", score: 8, voiceActive: true, eligible: true),
      SourceCandidate(id: "bed", score: 18, voiceActive: true, eligible: true),
    ]
    XCTAssertEqual(selector.choose(candidates: challenger, now: 1), "desk")
    XCTAssertEqual(selector.choose(candidates: challenger, now: 1.2), "desk")
    XCTAssertEqual(selector.choose(candidates: challenger, now: 1.4), "bed")
  }

  func test_selector_fails_over_immediately_when_the_active_source_disappears() {
    var selector = AutomaticSelector()
    _ = selector.choose(
      candidates: [SourceCandidate(id: "desk", score: 10, voiceActive: false, eligible: true)],
      now: 0
    )
    let selected = selector.choose(
      candidates: [
        SourceCandidate(id: "desk", score: 10, voiceActive: false, eligible: false),
        SourceCandidate(id: "phone", score: 6, voiceActive: false, eligible: true),
      ],
      now: 1
    )
    XCTAssertEqual(selected, "phone")
  }
}
