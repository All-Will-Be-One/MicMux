import AVFoundation
import Foundation

struct SourcePresentation: Identifiable, Equatable {
  let device: AudioDeviceDescriptor
  var enabled: Bool
  var channel: Int
  var waveform = [Float](repeating: 0, count: 100)
  var rmsDB = -96.0
  var snrDB = 0.0
  var score = -96.0
  var voiceActive = false
  var healthy = false
  var error: String?

  var id: String { device.uid }
}

struct RemoteSourcePresentation: Identifiable, Equatable {
  let descriptor: RemoteSourceDescriptor
  var enabled: Bool
  var waveform = [Float](repeating: 0, count: 100)
  var rmsDB = -96.0
  var snrDB = 0.0
  var score = -96.0
  var voiceActive = false
  var healthy = false
  var error: String?

  var id: String { descriptor.id }
}

/// Main-actor state for discovery, permissions, configuration, and the SwiftUI surface.
@MainActor
final class MicMuxModel: ObservableObject {
  private enum PreferenceKey {
    static let selectedOutputID = "routing.selectedOutputID"
    static let echoReferenceID = "routing.echoReferenceID"
    static let echoDelayMilliseconds = "routing.echoDelayMilliseconds"
    static let echoStrength = "routing.echoStrength"
    static let monitorOutputID = "routing.monitorOutputID"
    static let monitorVolume = "routing.monitorVolume"
  }

  @Published private(set) var sources: [SourcePresentation] = []
  @Published private(set) var remoteSources: [RemoteSourcePresentation] = []
  @Published private(set) var outputs: [AudioDeviceDescriptor] = []
  @Published var selectedOutputID = ""
  @Published var selectionMode: SelectionMode = .automatic
  @Published var pinnedSourceID: String?
  @Published var echoReferenceID = ""
  @Published var echoDelayMilliseconds = 35
  @Published var echoStrength = 1.0
  @Published var monitorOutputID = ""
  @Published var monitorVolume = 0.35
  @Published private(set) var pairingInvitation: String?
  @Published private(set) var phoneReceiverStatus = "Starting iPhone receiver…"
  @Published private(set) var activeSourceID: String?
  @Published private(set) var running = false
  @Published private(set) var status = "Ready"

  private let monitor = AudioDeviceMonitor()
  private let remoteServer = RemoteAudioServer()
  private let remoteSampleSink = RemoteSampleSink()
  private let preferences: UserDefaults
  private var coordinator: AudioCoordinator?

  init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
    selectedOutputID = preferences.string(forKey: PreferenceKey.selectedOutputID) ?? ""
    echoReferenceID = preferences.string(forKey: PreferenceKey.echoReferenceID) ?? ""
    if preferences.object(forKey: PreferenceKey.echoDelayMilliseconds) != nil {
      echoDelayMilliseconds = preferences.integer(forKey: PreferenceKey.echoDelayMilliseconds)
    }
    if preferences.object(forKey: PreferenceKey.echoStrength) != nil {
      echoStrength = preferences.double(forKey: PreferenceKey.echoStrength)
    }
    monitorOutputID = preferences.string(forKey: PreferenceKey.monitorOutputID) ?? ""
    if preferences.object(forKey: PreferenceKey.monitorVolume) != nil {
      monitorVolume = preferences.double(forKey: PreferenceKey.monitorVolume)
    }
    refreshDevices()
    monitor.onChange = { [weak self] in self?.hardwareChanged() }
    monitor.start()
    remoteServer.onInvitation = { [weak self] invitation in
      self?.pairingInvitation = invitation
    }
    remoteServer.onSourcesChanged = { [weak self] sources in
      self?.applyRemoteDescriptors(sources)
    }
    remoteServer.onSamples = { [weak remoteSampleSink] id, samples, rate in
      remoteSampleSink?.ingest(samples, rate: rate, sourceID: id)
    }
    remoteServer.onStatus = { [weak self] value in self?.phoneReceiverStatus = value }
    remoteServer.start()
  }

  func toggleRunning() {
    if running {
      stop()
    } else if sources.contains(where: { $0.enabled }) || !echoReferenceID.isEmpty {
      requestPermissionAndStart()
    } else {
      start()
    }
  }

  func stop() {
    coordinator?.stop()
    coordinator = nil
    remoteSampleSink.setCoordinator(nil)
    running = false
    activeSourceID = nil
    status = "Stopped"
    for index in sources.indices {
      sources[index].healthy = false
      sources[index].voiceActive = false
      sources[index].waveform = [Float](repeating: 0, count: 100)
    }
    for index in remoteSources.indices {
      remoteSources[index].healthy = false
      remoteSources[index].voiceActive = false
      remoteSources[index].waveform = [Float](repeating: 0, count: 100)
    }
  }

  func setSourceEnabled(_ enabled: Bool, id: String) {
    guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
    if id == selectedOutputID && enabled {
      status = "The output device cannot also be an input source."
      return
    }
    if id == echoReferenceID && enabled {
      echoReferenceID = ""
      persistRoutingPreferences()
      status = "Disabled echo cancellation so this device can be used as a microphone."
    }
    if id == monitorOutputID && enabled {
      monitorOutputID = ""
      persistRoutingPreferences()
      status = "Disabled monitoring because the same device became an input source."
    }
    sources[index].enabled = enabled
    restartIfRunning()
  }

  func setRemoteSourceEnabled(_ enabled: Bool, id: String) {
    guard let index = remoteSources.firstIndex(where: { $0.id == id }) else { return }
    remoteSources[index].enabled = enabled
    restartIfRunning()
  }

  func setChannel(_ channel: Int, id: String) {
    guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
    sources[index].channel = channel
    coordinator?.setChannel(channel, for: id)
  }

  func setOutput(_ id: String) {
    selectedOutputID = id
    if let index = sources.firstIndex(where: { $0.id == id }), sources[index].enabled {
      sources[index].enabled = false
      status = "Disabled the output device as an input to prevent a routing loop."
    }
    if echoReferenceID == id {
      echoReferenceID = ""
      status = "Disabled echo cancellation because its reference became the MicMux output."
    }
    if monitorOutputID == id {
      monitorOutputID = ""
      status = "Disabled monitoring because its device became the MicMux output."
    }
    persistRoutingPreferences()
    restartIfRunning()
  }

  func setEchoReference(_ id: String) {
    guard id != selectedOutputID else {
      status = "Use a different BlackHole device for speaker reference and MicMux output."
      return
    }
    echoReferenceID = id
    if let index = sources.firstIndex(where: { $0.id == id }) {
      sources[index].enabled = false
    }
    persistRoutingPreferences()
    restartIfRunning()
  }

  func setEchoParameters(delayMilliseconds: Int, strength: Double) {
    echoDelayMilliseconds = max(0, min(250, delayMilliseconds))
    echoStrength = max(0, min(1.25, strength))
    persistRoutingPreferences()
    restartIfRunning()
  }

  func setMonitorOutput(_ id: String) {
    guard id.isEmpty || safeMonitorOutputs.contains(where: { $0.id == id }) else {
      status = "Choose a physical monitor that is not also an input, sink, or loopback device."
      return
    }
    monitorOutputID = id
    persistRoutingPreferences()
    restartIfRunning()
  }

  func setMonitorVolume(_ volume: Double) {
    monitorVolume = max(0, min(1, volume))
    persistRoutingPreferences()
    coordinator?.setMonitorVolume(Float(monitorVolume))
  }

  var safeMonitorOutputs: [AudioDeviceDescriptor] {
    let enabledSourceIDs = Set(sources.filter(\.enabled).map(\.id))
    return outputs.filter {
      $0.id != selectedOutputID
        && $0.id != echoReferenceID
        && !enabledSourceIDs.contains($0.id)
        && !$0.isVirtual
        && !$0.name.localizedCaseInsensitiveContains("MicMux Speaker Reference")
    }
  }

  func setSelectionMode(_ mode: SelectionMode) {
    selectionMode = mode
    if mode == .pinned, pinnedSourceID == nil {
      pinnedSourceID =
        activeSourceID
        ?? sources.first(where: \.enabled)?.id
        ?? remoteSources.first(where: \.enabled)?.id
    }
    coordinator?.updateMode(mode, pinnedID: pinnedSourceID)
  }

  func pin(_ id: String) {
    pinnedSourceID = id
    selectionMode = .pinned
    coordinator?.updateMode(.pinned, pinnedID: id)
  }

  private func requestPermissionAndStart() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      start()
    case .notDetermined:
      status = "Waiting for microphone permission…"
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        Task { @MainActor in
          if granted { self?.start() } else { self?.status = "Microphone permission was denied." }
        }
      }
    default:
      status = "Enable MicMux under Privacy & Security › Microphone."
    }
  }

  private func start() {
    let enabledSources = sources.filter { $0.enabled && $0.id != selectedOutputID }
    let enabledRemoteSources = remoteSources.filter(\.enabled)
    guard !enabledSources.isEmpty || !enabledRemoteSources.isEmpty else {
      status = "Enable at least one input source."
      return
    }
    let coordinator = AudioCoordinator(mode: selectionMode, pinnedID: pinnedSourceID)
    coordinator.onSnapshots = { [weak self] snapshots, activeID in
      self?.apply(snapshots: snapshots, activeID: activeID)
    }
    coordinator.onStatus = { [weak self] value in self?.status = value }
    self.coordinator = coordinator
    remoteSampleSink.setCoordinator(coordinator)
    running = true
    let echoReference = sources.first(where: { $0.id == echoReferenceID }).map {
      SourceConfiguration(device: $0.device, enabled: true, channel: $0.channel)
    }
    coordinator.start(
      sources: enabledSources.map {
        SourceConfiguration(device: $0.device, enabled: $0.enabled, channel: $0.channel)
      },
      remoteSourceIDs: enabledRemoteSources.map(\.id),
      outputDevice: outputs.first(where: { $0.id == selectedOutputID }),
      monitorDevice: outputs.first(where: { $0.id == monitorOutputID }),
      monitorVolume: Float(monitorVolume),
      echoReference: echoReference,
      echoDelayMilliseconds: echoDelayMilliseconds,
      echoStrength: Float(echoStrength)
    )
  }

  private func restartIfRunning() {
    guard running else { return }
    coordinator?.stop()
    coordinator = nil
    running = false
    start()
  }

  private func apply(snapshots: [SourceSnapshot], activeID: String?) {
    activeSourceID = activeID
    for snapshot in snapshots {
      guard let index = sources.firstIndex(where: { $0.id == snapshot.id }) else { continue }
      sources[index].waveform = snapshot.waveform
      sources[index].rmsDB = snapshot.rmsDB
      sources[index].snrDB = snapshot.snrDB
      sources[index].score = snapshot.score
      sources[index].voiceActive = snapshot.voiceActive
      sources[index].healthy = snapshot.healthy
      sources[index].error = snapshot.error
      continue
    }
    for snapshot in snapshots {
      guard let index = remoteSources.firstIndex(where: { $0.id == snapshot.id }) else { continue }
      remoteSources[index].waveform = snapshot.waveform
      remoteSources[index].rmsDB = snapshot.rmsDB
      remoteSources[index].snrDB = snapshot.snrDB
      remoteSources[index].score = snapshot.score
      remoteSources[index].voiceActive = snapshot.voiceActive
      remoteSources[index].healthy = snapshot.healthy
      remoteSources[index].error = snapshot.error
    }
  }

  private func applyRemoteDescriptors(_ descriptors: [RemoteSourceDescriptor]) {
    let prior = Dictionary(uniqueKeysWithValues: remoteSources.map { ($0.id, $0) })
    let priorIDs = Set(prior.keys)
    remoteSources = descriptors.map { descriptor in
      if let existing = prior[descriptor.id] {
        return RemoteSourcePresentation(
          descriptor: descriptor,
          enabled: existing.enabled,
          waveform: existing.waveform,
          rmsDB: existing.rmsDB,
          snrDB: existing.snrDB,
          score: existing.score,
          voiceActive: existing.voiceActive,
          healthy: descriptor.connected && existing.healthy,
          error: existing.error
        )
      }
      return RemoteSourcePresentation(descriptor: descriptor, enabled: true)
    }
    if running, descriptors.contains(where: { !priorIDs.contains($0.id) }) {
      restartIfRunning()
    }
  }

  private func refreshDevices() {
    let snapshot = AudioDeviceCatalog.snapshot()
    let prior = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    sources = snapshot.inputs.map { device in
      if var existing = prior[device.uid] {
        existing = SourcePresentation(
          device: device,
          enabled: existing.enabled,
          channel: min(existing.channel, max(0, device.inputChannels - 1)),
          waveform: existing.waveform,
          rmsDB: existing.rmsDB,
          snrDB: existing.snrDB,
          score: existing.score,
          voiceActive: existing.voiceActive,
          healthy: existing.healthy,
          error: existing.error
        )
        return existing
      }
      return SourcePresentation(
        device: device,
        enabled: !device.isVirtual,
        channel: 0
      )
    }
    outputs = snapshot.outputs

    if selectedOutputID.isEmpty || !outputs.contains(where: { $0.id == selectedOutputID }) {
      selectedOutputID =
        outputs.first(where: {
          $0.name.localizedCaseInsensitiveContains("BlackHole 2ch")
        })?.id ?? ""
    }
    if !selectedOutputID.isEmpty,
      let index = sources.firstIndex(where: { $0.id == selectedOutputID })
    {
      sources[index].enabled = false
    }
    if !echoReferenceID.isEmpty,
      !sources.contains(where: { $0.id == echoReferenceID }) || echoReferenceID == selectedOutputID
    {
      echoReferenceID = ""
    }
    if !monitorOutputID.isEmpty,
      !safeMonitorOutputs.contains(where: { $0.id == monitorOutputID })
    {
      monitorOutputID = ""
    }
    persistRoutingPreferences()
  }

  private func persistRoutingPreferences() {
    preferences.set(selectedOutputID, forKey: PreferenceKey.selectedOutputID)
    preferences.set(echoReferenceID, forKey: PreferenceKey.echoReferenceID)
    preferences.set(echoDelayMilliseconds, forKey: PreferenceKey.echoDelayMilliseconds)
    preferences.set(echoStrength, forKey: PreferenceKey.echoStrength)
    preferences.set(monitorOutputID, forKey: PreferenceKey.monitorOutputID)
    preferences.set(monitorVolume, forKey: PreferenceKey.monitorVolume)
  }

  private func hardwareChanged() {
    let wasRunning = running
    if wasRunning { stop() }
    refreshDevices()
    if wasRunning { start() }
  }

  deinit {
    monitor.stop()
    coordinator?.stop()
    remoteServer.stop()
  }
}

/// Lets the network callback reach the current coordinator without hopping through the main actor.
private final class RemoteSampleSink {
  private let lock = NSLock()
  private weak var coordinator: AudioCoordinator?

  func setCoordinator(_ coordinator: AudioCoordinator?) {
    lock.withLock { self.coordinator = coordinator }
  }

  func ingest(_ samples: [Float], rate: Double, sourceID: String) {
    let coordinator: AudioCoordinator? = lock.withLock { self.coordinator }
    coordinator?.ingestRemote(samples, rate: rate, sourceID: sourceID)
  }
}
