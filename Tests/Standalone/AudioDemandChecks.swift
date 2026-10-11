import Foundation

// Run against the production source without XCTest (Command Line Tools-only Macs).
@main
struct AudioDemandChecks {
  static func main() {
    typealias P = AudioDemandMonitor.Process
    let processes = [
      P(pid: 1, bundleID: "audio.micmux.app", inputRunning: true, inputDevices: [42]),
      P(pid: 2, bundleID: "now.typeless.desktop.helper", inputRunning: true, inputDevices: [42]),
      P(pid: 3, bundleID: "com.openai.codex.helper", inputRunning: true, inputDevices: [42]),
      P(pid: 4, bundleID: "player", inputRunning: false, inputDevices: [42]),
      P(pid: 5, bundleID: "other-mic", inputRunning: true, inputDevices: [99]),
      P(pid: 6, bundleID: "", inputRunning: true, inputDevices: []),
    ]
    precondition(
      AudioDemandMonitor.consumers(processes, device: 42, ownPID: 1).map(\.pid) == [2, 3])
    precondition(AudioDemandMonitor.consumers(processes, device: nil, ownPID: 1).isEmpty)
    precondition(AudioDemandMonitor.consumers(processes, device: 42, ownPID: 2).map(\.pid) == [3])
    var gate = AudioDemandGate()
    precondition(gate.update(enabled: true, demanded: false, running: false, now: 0) == .none)
    precondition(gate.update(enabled: true, demanded: true, running: false, now: 1) == .start)
    precondition(gate.update(enabled: true, demanded: true, running: true, now: 100) == .none)
    precondition(gate.update(enabled: true, demanded: false, running: true, now: 101) == .none)
    precondition(gate.update(enabled: true, demanded: false, running: true, now: 101.9) == .none)
    // A new consumer within the grace period cancels the pending stop.
    precondition(gate.update(enabled: true, demanded: true, running: true, now: 101.95) == .none)
    precondition(gate.idleSince == nil)
    precondition(gate.update(enabled: true, demanded: false, running: true, now: 102) == .none)
    precondition(gate.update(enabled: true, demanded: false, running: true, now: 103) == .stop)
    precondition(gate.update(enabled: true, demanded: false, running: false, now: 104) == .none)
    // Manual mode and an explicit disable must never restart from demand alone.
    precondition(gate.update(enabled: false, demanded: true, running: false, now: 105) == .none)
    precondition(gate.idleSince == nil)
    print("PASS: 15 demand matching and lifecycle checks (no microphone capture)")
  }
}
