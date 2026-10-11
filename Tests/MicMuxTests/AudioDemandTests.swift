import XCTest

@testable import MicMux

final class AudioDemandTests: XCTestCase {
  private typealias Process = AudioDemandMonitor.Process

  func test_only_external_active_readers_of_the_selected_sink_create_demand() {
    let processes = [
      Process(pid: 1, bundleID: "self", inputRunning: true, inputDevices: [42]),
      Process(pid: 2, bundleID: "audio.micmux.app", inputRunning: true, inputDevices: [42]),
      Process(pid: 3, bundleID: "dictation", inputRunning: true, inputDevices: [42]),
      Process(pid: 4, bundleID: "conference", inputRunning: true, inputDevices: [42]),
      Process(pid: 5, bundleID: "player", inputRunning: false, inputDevices: [42]),
      Process(pid: 6, bundleID: "other-input", inputRunning: true, inputDevices: [99]),
      Process(pid: 7, bundleID: "", inputRunning: true, inputDevices: []),
    ]
    XCTAssertEqual(
      AudioDemandMonitor.consumers(processes, device: 42, ownPID: 1).map(\.pid), [3, 4])
    XCTAssertTrue(AudioDemandMonitor.consumers(processes, device: nil, ownPID: 1).isEmpty)
    XCTAssertTrue(AudioDemandMonitor.consumers([], device: 42, ownPID: 1).isEmpty)
  }

  func test_idle_does_not_start_and_demand_starts_immediately() {
    var gate = AudioDemandGate()
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: false, now: 0), .none)
    XCTAssertEqual(gate.update(enabled: true, demanded: true, running: false, now: 0.1), .start)
  }

  func test_an_open_input_session_keeps_capture_running_even_without_speech() {
    var gate = AudioDemandGate()
    XCTAssertEqual(gate.update(enabled: true, demanded: true, running: true, now: 0), .none)
    XCTAssertEqual(gate.update(enabled: true, demanded: true, running: true, now: 100), .none)
    XCTAssertNil(gate.idleSince)
  }

  func test_last_consumer_leaving_stops_after_the_grace_period() {
    var gate = AudioDemandGate()
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: true, now: 10), .none)
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: true, now: 10.99), .none)
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: true, now: 11), .stop)
  }

  func test_new_consumer_cancels_pending_stop_and_gets_a_fresh_grace_period() {
    var gate = AudioDemandGate()
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: true, now: 10), .none)
    XCTAssertEqual(gate.update(enabled: true, demanded: true, running: true, now: 10.5), .none)
    XCTAssertNil(gate.idleSince)
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: true, now: 11), .none)
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: true, now: 11.5), .none)
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: true, now: 12), .stop)
  }

  func test_manual_mode_never_restarts_from_demand_and_clears_pending_stop() {
    var gate = AudioDemandGate()
    _ = gate.update(enabled: true, demanded: false, running: true, now: 10)
    XCTAssertEqual(gate.update(enabled: false, demanded: true, running: false, now: 11), .none)
    XCTAssertNil(gate.idleSince)
    XCTAssertEqual(gate.update(enabled: false, demanded: false, running: true, now: 12), .none)
  }

  func test_an_already_stopped_graph_clears_the_previous_idle_deadline() {
    var gate = AudioDemandGate()
    _ = gate.update(enabled: true, demanded: false, running: true, now: 10)
    XCTAssertEqual(gate.update(enabled: true, demanded: false, running: false, now: 12), .none)
    XCTAssertNil(gate.idleSince)
    XCTAssertEqual(gate.update(enabled: true, demanded: true, running: false, now: 13), .start)
  }
}
