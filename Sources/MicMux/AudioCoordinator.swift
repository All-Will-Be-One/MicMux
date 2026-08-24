import Foundation

enum SelectionMode: String, CaseIterable, Identifiable {
  case automatic = "Auto"
  case blend = "Blend"
  case pinned = "Pinned"
  var id: String { rawValue }
}

struct SourceConfiguration {
  let device: AudioDeviceDescriptor
  var enabled: Bool
  var channel: Int
}

struct SourceSnapshot: Identifiable, Equatable {
  let id: String
  let waveform: [Float]
  let rmsDB: Double
  let snrDB: Double
  let score: Double
  let voiceActive: Bool
  let healthy: Bool
  let error: String?
}

/// Coordinates independent device clocks, source scoring, selection, and stable output fan-out.
final class AudioCoordinator {
  var onSnapshots: (([SourceSnapshot], String?) -> Void)?
  var onStatus: ((String) -> Void)?

  private final class Runtime {
    let id: String
    var enabled: Bool
    var waveform = [Float](repeating: 0, count: 100)
    var rmsDB = -96.0
    var snrDB = 0.0
    var score = -96.0
    var voiceActive = false
    var lastSeen: TimeInterval = 0
    var error: String?
    var resampler: StreamingLinearResampler?
    var sourceRate = 0.0
    var audio = FloatRingBuffer(capacity: Int(AudioSamplePipe.sampleRate * 3))
    let qualityTracker = SignalQualityTracker()

    init(id: String, enabled: Bool) {
      self.id = id
      self.enabled = enabled
    }
  }

  private let processingQueue = DispatchQueue(label: "audio.micmux.processing")
  private let pipe = AudioSamplePipe()
  private let monitorPipe = AudioSamplePipe()
  private var output: AudioOutput?
  private var monitorOutput: AudioOutput?
  private var captures: [String: InputCapture] = [:]
  private var referenceCapture: InputCapture?
  private var referenceResampler: StreamingLinearResampler?
  private var referenceRate = 0.0
  private var referenceAudio = FloatRingBuffer(capacity: Int(AudioSamplePipe.sampleRate * 3))
  private var echoCanceller: AdaptiveEchoCanceller?
  private var runtimes: [String: Runtime] = [:]
  private var selector = AutomaticSelector()
  private var mode: SelectionMode
  private var pinnedID: String?
  private var mixTimer: DispatchSourceTimer?
  private var publishTimer: DispatchSourceTimer?
  private var running = false

  init(mode: SelectionMode, pinnedID: String?) {
    self.mode = mode
    self.pinnedID = pinnedID
  }

  func start(
    sources: [SourceConfiguration],
    remoteSourceIDs: [String],
    outputDevice: AudioDeviceDescriptor?,
    monitorDevice: AudioDeviceDescriptor?,
    monitorVolume: Float,
    echoReference: SourceConfiguration?,
    echoDelayMilliseconds: Int,
    echoStrength: Float
  ) {
    guard !running else { return }
    running = true

    for configuration in sources where configuration.enabled {
      startCapture(configuration)
    }
    processingQueue.sync {
      for id in remoteSourceIDs where runtimes[id] == nil {
        runtimes[id] = Runtime(id: id, enabled: true)
      }
    }
    if let echoReference {
      startReferenceCapture(echoReference)
      echoCanceller = AdaptiveEchoCanceller(
        filterLength: 512,
        delayFrames: Int(AudioSamplePipe.sampleRate * Double(echoDelayMilliseconds) / 1_000),
        strength: echoStrength
      )
    }

    if let outputDevice {
      do {
        let output = AudioOutput(pipe: pipe)
        try output.start(device: outputDevice)
        self.output = output
        onStatus?("Forwarding to \(outputDevice.name)")
      } catch {
        onStatus?("Output failed: \(error.localizedDescription)")
      }
    } else {
      onStatus?("Waveforms live — choose an output to forward audio")
    }

    if let monitorDevice {
      do {
        let monitorOutput = AudioOutput(pipe: monitorPipe)
        try monitorOutput.start(device: monitorDevice, volume: monitorVolume)
        self.monitorOutput = monitorOutput
        onStatus?(
          "Forwarding to \(outputDevice?.name ?? "no sink") · monitoring \(monitorDevice.name)")
      } catch {
        onStatus?("Monitor failed: \(error.localizedDescription)")
      }
    }

    let mixTimer = DispatchSource.makeTimerSource(queue: processingQueue)
    mixTimer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
    mixTimer.setEventHandler { [weak self] in self?.mixNextBlock() }
    self.mixTimer = mixTimer
    mixTimer.resume()

    let publishTimer = DispatchSource.makeTimerSource(queue: processingQueue)
    publishTimer.schedule(
      deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(15))
    publishTimer.setEventHandler { [weak self] in self?.evaluateAndPublish() }
    self.publishTimer = publishTimer
    publishTimer.resume()
  }

  func stop() {
    guard running else { return }
    running = false
    mixTimer?.cancel()
    mixTimer = nil
    publishTimer?.cancel()
    publishTimer = nil
    for capture in captures.values { capture.stop() }
    captures.removeAll()
    referenceCapture?.stop()
    referenceCapture = nil
    output?.stop()
    output = nil
    monitorOutput?.stop()
    monitorOutput = nil
    pipe.flush()
    monitorPipe.flush()
    processingQueue.sync {
      runtimes.removeAll()
      selector.force(nil)
      referenceAudio.removeAll()
      referenceResampler = nil
      referenceRate = 0
      echoCanceller = nil
    }
  }

  func updateMode(_ mode: SelectionMode, pinnedID: String?) {
    processingQueue.async { [weak self] in
      self?.mode = mode
      self?.pinnedID = pinnedID
      if mode == .pinned { self?.selector.force(pinnedID) }
      self?.pipe.flush()
      self?.monitorPipe.flush()
    }
  }

  func setMonitorVolume(_ volume: Float) {
    monitorOutput?.setVolume(volume)
  }

  func ingestRemote(_ samples: [Float], rate: Double, sourceID: String) {
    processingQueue.async { [weak self] in
      self?.ingest(samples, rate: rate, sourceID: sourceID)
    }
  }

  func setChannel(_ channel: Int, for id: String) {
    captures[id]?.setChannel(channel)
    processingQueue.async { [weak self] in
      guard let runtime = self?.runtimes[id] else { return }
      runtime.waveform = [Float](repeating: 0, count: 100)
      runtime.qualityTracker.reset()
      runtime.resampler = nil
    }
  }

  private func startCapture(_ configuration: SourceConfiguration) {
    let id = configuration.device.uid
    let runtime = Runtime(id: id, enabled: true)
    processingQueue.sync { runtimes[id] = runtime }

    let capture = InputCapture(device: configuration.device, channel: configuration.channel)
    capture.onSamples = { [weak self] samples, rate, _ in
      self?.processingQueue.async {
        self?.ingest(samples, rate: rate, sourceID: id)
      }
    }
    capture.onError = { [weak self] message in
      self?.processingQueue.async {
        self?.runtimes[id]?.error = message
      }
    }
    captures[id] = capture
    do {
      try capture.start()
    } catch {
      processingQueue.async { [weak self] in
        self?.runtimes[id]?.error = error.localizedDescription
      }
    }
  }

  private func startReferenceCapture(_ configuration: SourceConfiguration) {
    let capture = InputCapture(
      device: configuration.device,
      channel: configuration.channel
    )
    capture.onSamples = { [weak self] samples, rate, _ in
      self?.processingQueue.async {
        self?.ingestReference(samples, rate: rate)
      }
    }
    capture.onError = { [weak self] message in
      self?.onStatus?("Echo reference failed: \(message)")
    }
    referenceCapture = capture
    do {
      try capture.start()
    } catch {
      onStatus?("Echo reference failed: \(error.localizedDescription)")
    }
  }

  private func ingest(_ samples: [Float], rate: Double, sourceID: String) {
    guard running, let runtime = runtimes[sourceID], !samples.isEmpty else { return }
    let now = ProcessInfo.processInfo.systemUptime
    runtime.lastSeen = now
    runtime.error = nil

    let quality = runtime.qualityTracker.update(samples: samples)
    runtime.rmsDB = quality.rmsDB
    runtime.snrDB = quality.snrDB
    runtime.score = quality.score
    runtime.voiceActive = quality.voiceActive
    runtime.waveform.removeFirst()
    runtime.waveform.append(min(1, quality.peak * 8))

    if runtime.resampler == nil || abs(runtime.sourceRate - rate) > 0.5 {
      runtime.sourceRate = rate
      runtime.resampler = StreamingLinearResampler(
        sourceRate: rate,
        targetRate: AudioSamplePipe.sampleRate
      )
    }
    let normalized = runtime.resampler?.process(samples) ?? samples
    runtime.audio.append(normalized)
    if runtime.audio.count > Int(AudioSamplePipe.sampleRate * 0.35) {
      runtime.audio.discardOldest(keeping: Int(AudioSamplePipe.sampleRate * 0.12))
    }
  }

  private func ingestReference(_ samples: [Float], rate: Double) {
    guard running, !samples.isEmpty else { return }
    if referenceResampler == nil || abs(referenceRate - rate) > 0.5 {
      referenceRate = rate
      referenceResampler = StreamingLinearResampler(
        sourceRate: rate,
        targetRate: AudioSamplePipe.sampleRate
      )
    }
    referenceAudio.append(referenceResampler?.process(samples) ?? samples)
    if referenceAudio.count > Int(AudioSamplePipe.sampleRate * 0.35) {
      referenceAudio.discardOldest(keeping: Int(AudioSamplePipe.sampleRate * 0.12))
    }
  }

  private func mixNextBlock() {
    guard running else { return }
    let frameCount = 480
    let now = ProcessInfo.processInfo.systemUptime
    let healthy = runtimes.values.filter {
      $0.enabled && now - $0.lastSeen < 1 && $0.error == nil && $0.audio.count > 0
    }

    let mixed: [Float]
    if mode == .blend {
      let commonFrames = min(frameCount, healthy.map(\.audio.count).min() ?? 0)
      let blocks = healthy.compactMap { runtime -> BlendInput? in
        let samples = runtime.audio.read(count: commonFrames)
        guard !samples.isEmpty else { return nil }
        return BlendInput(
          samples: samples,
          score: runtime.score,
          voiceActive: runtime.voiceActive
        )
      }
      mixed = VoiceBlendMixer.mix(blocks)
    } else if let activeID = selector.activeID,
      let runtime = runtimes[activeID]
    {
      for inactive in healthy where inactive.id != activeID {
        inactive.audio.discardOldest(keeping: 960)
      }
      mixed = runtime.audio.read(count: frameCount)
    } else {
      mixed = []
    }
    guard !mixed.isEmpty else { return }

    let processed: [Float]
    if let echoCanceller {
      let reference = referenceAudio.read(count: mixed.count)
      processed = echoCanceller.process(microphone: mixed, reference: reference)
    } else {
      processed = mixed
    }
    pipe.append(processed)
    monitorPipe.append(processed)
  }

  private func evaluateAndPublish() {
    guard running else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let previous = selector.activeID

    if mode == .pinned {
      let pinIsHealthy = pinnedID.flatMap { runtimes[$0] }.map { now - $0.lastSeen < 1 } ?? false
      selector.force(pinIsHealthy ? pinnedID : nil)
    } else {
      let candidates = runtimes.values.map { runtime in
        SourceCandidate(
          id: runtime.id,
          score: runtime.score,
          voiceActive: runtime.voiceActive,
          eligible: runtime.enabled && now - runtime.lastSeen < 1 && runtime.error == nil
        )
      }
      _ = selector.choose(candidates: candidates, now: now)
    }
    if selector.activeID != previous, mode != .blend {
      pipe.flush()
      monitorPipe.flush()
    }

    let snapshots = runtimes.values.map { runtime in
      SourceSnapshot(
        id: runtime.id,
        waveform: runtime.waveform,
        rmsDB: runtime.rmsDB,
        snrDB: runtime.snrDB,
        score: runtime.score,
        voiceActive: runtime.voiceActive,
        healthy: now - runtime.lastSeen < 1 && runtime.error == nil,
        error: runtime.error
      )
    }
    let active = selector.activeID
    DispatchQueue.main.async { [weak self] in self?.onSnapshots?(snapshots, active) }
  }

  deinit { stop() }
}
