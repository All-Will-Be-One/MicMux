import CoreAudio
import Foundation

/// Watches process metadata only. It never opens an audio stream or captures samples.
final class AudioDemandMonitor {
  struct Process: Equatable {
    let pid: UInt32
    let bundleID: String
    let inputRunning: Bool
    let inputDevices: [AudioObjectID]
  }

  var onChange: (([Process], String?) -> Void)?
  private struct Registration {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
  }
  private var registrations: [Registration] = []
  private var processIDs: [AudioObjectID] = []
  private var timer: DispatchSourceTimer?
  private var pending: DispatchWorkItem?

  func start() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    // Notifications provide fast wakeup; reconcile periodically after missed HAL events.
    timer.schedule(deadline: .now(), repeating: 1)
    timer.setEventHandler { [weak self] in self?.refresh() }
    self.timer = timer
    timer.resume()
    refresh()
  }

  func stop() {
    timer?.cancel()
    timer = nil
    pending?.cancel()
    pending = nil
    removeListeners()
    processIDs = []
  }

  private func listen(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, self.timer != nil, self.pending == nil else { return }
      let work = DispatchWorkItem { [weak self] in
        self?.pending = nil
        guard self?.timer != nil else { return }
        self?.refresh()
      }
      self.pending = work
      DispatchQueue.main.async(execute: work)
    }
    if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
      registrations.append(Registration(object: object, address: address, block: block))
    }
  }

  private func removeListeners() {
    for var registration in registrations {
      AudioObjectRemovePropertyListenerBlock(
        registration.object, &registration.address, .main, registration.block)
    }
    registrations.removeAll()
  }

  private func refresh() {
    guard
      let ids = Self.words(
        AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    else {
      onChange?([], "Cannot read audio usage — automatic capture paused")
      return
    }
    if ids != processIDs || registrations.isEmpty {
      removeListeners()
      processIDs = ids
      listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
      for id in ids {
        listen(id, kAudioProcessPropertyIsRunningInput)
        listen(id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
      }
    }
    var processes: [Process] = []
    var incomplete = false
    for id in ids {
      guard let pid = Self.words(id, kAudioProcessPropertyPID)?.first,
        let active = Self.words(id, kAudioProcessPropertyIsRunningInput)?.first
      else {
        incomplete = true
        continue
      }
      guard pid != UInt32(ProcessInfo.processInfo.processIdentifier), active != 0 else { continue }
      guard
        let devices = Self.words(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
      else {
        incomplete = true
        continue
      }
      processes.append(
        Process(
          pid: pid, bundleID: Self.bundleID(id),
          inputRunning: true, inputDevices: devices))
    }
    onChange?(processes, incomplete ? "Some audio process states are unavailable" : nil)
  }

  static func consumers(_ processes: [Process], device: AudioObjectID?, ownPID: UInt32) -> [Process]
  {
    guard let device else { return [] }
    return processes.filter {
      $0.pid != ownPID && $0.bundleID != "audio.micmux.app"
        && $0.inputRunning && $0.inputDevices.contains(device)
    }
  }

  private static func words(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> [UInt32]? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else {
      return nil
    }
    guard size > 0 else { return [] }
    guard size % 4 == 0 else { return nil }
    var values = [UInt32](repeating: 0, count: Int(size) / 4)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else {
      return nil
    }
    return Array(values.prefix(Int(size) / 4))
  }

  private static func bundleID(_ object: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
      return ""
    }
    return value?.takeRetainedValue() as String? ?? ""
  }

  deinit { stop() }
}

/// Stop hysteresis is independent of signal level: silence is still an active session.
struct AudioDemandGate {
  enum Action: Equatable { case none, start, stop }
  private(set) var idleSince: TimeInterval?

  mutating func update(enabled: Bool, demanded: Bool, running: Bool, now: TimeInterval) -> Action {
    guard enabled else {
      idleSince = nil
      return .none
    }
    if demanded {
      idleSince = nil
      return running ? .none : .start
    }
    guard running else {
      idleSince = nil
      return .none
    }
    if idleSince == nil { idleSince = now }
    return now - (idleSince ?? now) >= 1 ? .stop : .none
  }
}
