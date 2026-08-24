import AVFoundation
import Foundation

/// Pulls MicMux's stable mono stream into any Core Audio output, including BlackHole.
final class AudioOutput {
  private let pipe: AudioSamplePipe
  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?

  init(pipe: AudioSamplePipe) {
    self.pipe = pipe
  }

  func start(device: AudioDeviceDescriptor, volume: Float = 1) throws {
    stop()
    let engine = AVAudioEngine()
    let output = engine.outputNode
    try output.auAudioUnit.setDeviceID(device.objectID)

    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: AudioSamplePipe.sampleRate,
        channels: 1
      )
    else {
      throw OutputError.invalidFormat
    }
    let pipe = self.pipe
    let source = AVAudioSourceNode(format: format) { _, _, frames, audioBufferList in
      pipe.render(audioBufferList, frames: Int(frames))
      return noErr
    }

    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = max(0, min(1, volume))
    engine.prepare()
    try engine.start()
    self.engine = engine
    sourceNode = source
  }

  func setVolume(_ volume: Float) {
    engine?.mainMixerNode.outputVolume = max(0, min(1, volume))
  }

  func stop() {
    sourceNode = nil
    engine?.stop()
    engine?.reset()
    engine = nil
    pipe.flush()
  }

  deinit { stop() }

  enum OutputError: LocalizedError {
    case invalidFormat
    var errorDescription: String? { "MicMux could not create its 48 kHz mono output format." }
  }
}
