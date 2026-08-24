import AudioToolbox
import CoreAudio
import Foundation

/// Discovers Core Audio endpoints without changing the user's system-wide defaults.
struct AudioDeviceDescriptor: Identifiable, Hashable {
  let objectID: AudioDeviceID
  let uid: String
  let name: String
  let transportType: UInt32
  let inputChannels: Int
  let outputChannels: Int
  let isDefaultInput: Bool
  let isDefaultOutput: Bool

  var id: String { uid }
  var hasInput: Bool { inputChannels > 0 }
  var hasOutput: Bool { outputChannels > 0 }

  var isVirtual: Bool {
    if transportType == kAudioDeviceTransportTypeVirtual { return true }
    let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    return ["blackhole", "zoom", "teams audio", "loopback", "soundflower"]
      .contains(where: folded.contains)
  }

  var transportLabel: String {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    default: return "Audio device"
    }
  }
}

struct AudioDeviceSnapshot {
  let inputs: [AudioDeviceDescriptor]
  let outputs: [AudioDeviceDescriptor]
}

enum AudioDeviceCatalog {
  static func snapshot() -> AudioDeviceSnapshot {
    let defaultInput =
      scalarProperty(
        AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultInputDevice
      ) ?? kAudioObjectUnknown
    let defaultOutput =
      scalarProperty(
        AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultOutputDevice
      ) ?? kAudioObjectUnknown

    let devices = objectIDs(
      AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDevices
    ).compactMap { id -> AudioDeviceDescriptor? in
      guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
        let name = stringProperty(id, selector: kAudioObjectPropertyName)
      else {
        return nil
      }
      return AudioDeviceDescriptor(
        objectID: id,
        uid: uid,
        name: name,
        transportType: scalarProperty(id, selector: kAudioDevicePropertyTransportType) ?? 0,
        inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
        outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
        isDefaultInput: id == defaultInput,
        isDefaultOutput: id == defaultOutput
      )
    }

    func order(_ left: AudioDeviceDescriptor, _ right: AudioDeviceDescriptor) -> Bool {
      if left.isVirtual != right.isVirtual { return !left.isVirtual }
      let leftDefault = left.isDefaultInput || left.isDefaultOutput
      let rightDefault = right.isDefaultInput || right.isDefaultOutput
      if leftDefault != rightDefault { return leftDefault }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    return AudioDeviceSnapshot(
      inputs: devices.filter(\.hasInput).sorted(by: order),
      outputs: devices.filter(\.hasOutput).sorted(by: order)
    )
  }

  private static func scalarProperty(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(objectID, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  private static func stringProperty(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(objectID, &address) else { return nil }
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
      let value
    else {
      return nil
    }
    return value.takeUnretainedValue() as String
  }

  private static func objectIDs(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
      size > 0
    else { return [] }
    var values = [AudioObjectID](
      repeating: kAudioObjectUnknown,
      count: Int(size) / MemoryLayout<AudioObjectID>.size
    )
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values) == noErr else {
      return []
    }
    return values
  }

  private static func channelCount(
    _ deviceID: AudioDeviceID,
    scope: AudioObjectPropertyScope
  ) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
      size >= UInt32(MemoryLayout<AudioBufferList>.size)
    else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
      return 0
    }
    let list = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }
}

/// Coalesces noisy hardware notifications into a single catalog refresh.
final class AudioDeviceMonitor {
  var onChange: (() -> Void)?

  private typealias Listener = AudioObjectPropertyListenerBlock
  private struct Registration {
    var address: AudioObjectPropertyAddress
    let listener: Listener
  }

  private let systemObject = AudioObjectID(kAudioObjectSystemObject)
  private var registrations: [Registration] = []
  private var pendingRefresh: DispatchWorkItem?

  func start() {
    guard registrations.isEmpty else { return }
    for selector in [
      kAudioHardwarePropertyDevices,
      kAudioHardwarePropertyDefaultInputDevice,
      kAudioHardwarePropertyDefaultOutputDevice,
    ] {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      let listener: Listener = { [weak self] _, _ in self?.scheduleRefresh() }
      guard AudioObjectAddPropertyListenerBlock(systemObject, &address, .main, listener) == noErr
      else {
        continue
      }
      registrations.append(Registration(address: address, listener: listener))
    }
  }

  func stop() {
    pendingRefresh?.cancel()
    pendingRefresh = nil
    for registration in registrations {
      var address = registration.address
      AudioObjectRemovePropertyListenerBlock(
        systemObject,
        &address,
        .main,
        registration.listener
      )
    }
    registrations.removeAll()
  }

  private func scheduleRefresh() {
    pendingRefresh?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pendingRefresh = nil
      self?.onChange?()
    }
    pendingRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }

  deinit { stop() }
}
