import AudioToolbox
import Foundation

/// A bounded FIFO that drops the oldest samples when a producer outruns its sink.
struct FloatRingBuffer {
  private var storage: [Float]
  private var readIndex = 0
  private(set) var count = 0

  init(capacity: Int) {
    storage = [Float](repeating: 0, count: max(1, capacity))
  }

  var capacity: Int { storage.count }

  mutating func append(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    let incoming = samples.count > capacity ? Array(samples.suffix(capacity)) : samples
    for sample in incoming {
      if count == capacity {
        readIndex = (readIndex + 1) % capacity
        count -= 1
      }
      let writeIndex = (readIndex + count) % capacity
      storage[writeIndex] = sample
      count += 1
    }
  }

  mutating func read(into destination: UnsafeMutablePointer<Float>, count requested: Int) -> Int {
    let available = min(requested, count)
    for index in 0..<available {
      destination[index] = storage[(readIndex + index) % capacity]
    }
    readIndex = (readIndex + available) % capacity
    count -= available
    return available
  }

  mutating func read(count requested: Int) -> [Float] {
    let requested = max(0, requested)
    var result = [Float](repeating: 0, count: min(requested, count))
    let resultCount = result.count
    guard resultCount > 0 else { return [] }
    result.withUnsafeMutableBufferPointer { destination in
      _ = read(into: destination.baseAddress!, count: resultCount)
    }
    return result
  }

  mutating func popFirst() -> Float? {
    guard count > 0 else { return nil }
    let value = storage[readIndex]
    readIndex = (readIndex + 1) % capacity
    count -= 1
    return value
  }

  mutating func discardOldest(keeping newestCount: Int) {
    let keep = max(0, min(newestCount, count))
    let drop = count - keep
    readIndex = (readIndex + drop) % capacity
    count = keep
  }

  mutating func removeAll() {
    readIndex = 0
    count = 0
  }
}

struct BlendInput {
  let samples: [Float]
  let score: Double
  let voiceActive: Bool
}

/// Quality-weighted blending avoids both clipping and equal-gain room echo from weak microphones.
enum VoiceBlendMixer {
  static func mix(_ inputs: [BlendInput]) -> [Float] {
    let available = inputs.filter { !$0.samples.isEmpty }
    guard let frameCount = available.map(\.samples.count).min(), frameCount > 0 else { return [] }
    let voiced = available.filter(\.voiceActive)
    let contributors = voiced.isEmpty ? available : voiced
    let bestScore = contributors.map(\.score).max() ?? 0
    let rawWeights = contributors.map { input in
      Float(exp(max(-5, min(0, (input.score - bestScore) / 6))))
    }
    let total = max(0.000_1, rawWeights.reduce(0, +))

    var output = [Float](repeating: 0, count: frameCount)
    for (input, rawWeight) in zip(contributors, rawWeights) {
      let weight = rawWeight / total
      for frame in 0..<frameCount {
        output[frame] += input.samples[frame] * weight
      }
    }
    return output.map(softLimit)
  }

  private static func softLimit(_ sample: Float) -> Float {
    tanh(sample * 1.1) / tanh(1.1)
  }
}

/// A bounded normalized-LMS filter removes a delayed loudspeaker reference from microphone audio.
final class AdaptiveEchoCanceller {
  private let filterLength: Int
  private let stepSize: Float
  private var coefficients: [Float]
  private var history: [Float]
  private var historyIndex = 0
  private var historyPower: Float = 0
  private var delayLine: [Float]
  private var delayIndex = 0
  private var strength: Float

  init(
    filterLength: Int = 1_024,
    delayFrames: Int = 0,
    strength: Float = 1,
    stepSize: Float = 0.22
  ) {
    self.filterLength = max(8, filterLength)
    self.stepSize = max(0.01, min(0.8, stepSize))
    self.strength = max(0, min(1.25, strength))
    coefficients = [Float](repeating: 0, count: self.filterLength)
    history = [Float](repeating: 0, count: self.filterLength)
    delayLine = [Float](repeating: 0, count: max(0, delayFrames))
  }

  func process(microphone: [Float], reference: [Float]) -> [Float] {
    let count = min(microphone.count, reference.count)
    guard count > 0 else { return microphone }
    var output = microphone

    for frame in 0..<count {
      let delayedReference = delay(reference[frame])
      let expired = history[historyIndex]
      historyPower = max(
        0,
        historyPower + delayedReference * delayedReference - expired * expired
      )
      history[historyIndex] = delayedReference

      var estimate: Float = 0
      var sampleIndex = historyIndex
      for tap in 0..<filterLength {
        estimate += coefficients[tap] * history[sampleIndex]
        sampleIndex = sampleIndex == 0 ? filterLength - 1 : sampleIndex - 1
      }

      let error = microphone[frame] - estimate
      output[frame] = max(-1, min(1, microphone[frame] - strength * estimate))
      if historyPower > 0.000_001 {
        let scale = stepSize * error / (historyPower + 0.000_1)
        sampleIndex = historyIndex
        for tap in 0..<filterLength {
          coefficients[tap] = coefficients[tap] * 0.999_999 + scale * history[sampleIndex]
          sampleIndex = sampleIndex == 0 ? filterLength - 1 : sampleIndex - 1
        }
      }
      historyIndex = (historyIndex + 1) % filterLength
    }
    return output
  }

  func reset(delayFrames: Int, strength: Float) {
    coefficients = [Float](repeating: 0, count: filterLength)
    history = [Float](repeating: 0, count: filterLength)
    historyIndex = 0
    historyPower = 0
    delayLine = [Float](repeating: 0, count: max(0, delayFrames))
    delayIndex = 0
    self.strength = max(0, min(1.25, strength))
  }

  private func delay(_ sample: Float) -> Float {
    guard !delayLine.isEmpty else { return sample }
    let delayed = delayLine[delayIndex]
    delayLine[delayIndex] = sample
    delayIndex = (delayIndex + 1) % delayLine.count
    return delayed
  }
}

/// Streaming linear interpolation is sufficient for voice and keeps source clocks independent.
final class StreamingLinearResampler {
  private let sourceRate: Double
  private let targetRate: Double
  private var previousSample: Float?
  private var nextPosition = 0.0

  init(sourceRate: Double, targetRate: Double) {
    self.sourceRate = sourceRate
    self.targetRate = targetRate
  }

  func process(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty else { return [] }
    guard abs(sourceRate - targetRate) > 0.5 else { return samples }

    let step = sourceRate / targetRate
    let input: [Float]
    if let previousSample {
      input = [previousSample] + samples
    } else {
      input = samples
      nextPosition = 0
    }
    guard input.count >= 2 else {
      previousSample = input.last
      return []
    }

    var output: [Float] = []
    output.reserveCapacity(Int(Double(samples.count) * targetRate / sourceRate) + 2)
    var position = nextPosition
    while position < Double(input.count - 1) {
      let lower = Int(position)
      let fraction = Float(position - Double(lower))
      output.append(input[lower] + (input[lower + 1] - input[lower]) * fraction)
      position += step
    }

    nextPosition = position - Double(input.count - 1)
    previousSample = input.last
    return output
  }
}

struct SignalQuality: Equatable {
  let peak: Float
  let rmsDB: Double
  let snrDB: Double
  let score: Double
  let voiceActive: Bool
}

/// Learns each microphone's own noise floor before comparing speech quality across devices.
final class SignalQualityTracker {
  private var noiseFloor: Float = 0.003
  private var calibrationBuffers = 0

  func reset() {
    noiseFloor = 0.003
    calibrationBuffers = 0
  }

  func update(samples: [Float]) -> SignalQuality {
    guard !samples.isEmpty else {
      return SignalQuality(peak: 0, rmsDB: -96, snrDB: 0, score: -96, voiceActive: false)
    }
    var sumSquares: Double = 0
    var peak: Float = 0
    var clipped = 0
    for sample in samples {
      let magnitude = abs(sample)
      peak = max(peak, magnitude)
      sumSquares += Double(sample * sample)
      if magnitude >= 0.985 { clipped += 1 }
    }
    let rms = Float(sqrt(sumSquares / Double(samples.count)))
    let rmsDB = Self.decibels(rms)

    let voiceActive: Bool
    if calibrationBuffers < 12 {
      noiseFloor =
        calibrationBuffers == 0
        ? max(0.000_1, rms)
        : noiseFloor * 0.8 + rms * 0.2
      calibrationBuffers += 1
      voiceActive = false
    } else {
      let threshold = max(0.003, noiseFloor * 2.4)
      voiceActive = rms > threshold
      if !voiceActive {
        noiseFloor = noiseFloor * 0.96 + rms * 0.04
      } else if rms < noiseFloor {
        noiseFloor = noiseFloor * 0.99 + rms * 0.01
      }
    }

    let snrDB = max(0, 20 * log10(Double(max(rms, 0.000_001) / max(noiseFloor, 0.000_001))))
    let clippingPenalty = Double(clipped) / Double(samples.count) * 80
    let score = snrDB + max(-18, rmsDB + 42) * 0.35 - clippingPenalty
    return SignalQuality(
      peak: peak,
      rmsDB: rmsDB,
      snrDB: snrDB,
      score: score,
      voiceActive: voiceActive
    )
  }

  private static func decibels(_ value: Float) -> Double {
    20 * log10(Double(max(value, 0.000_001)))
  }
}

struct SourceCandidate: Equatable {
  let id: String
  let score: Double
  let voiceActive: Bool
  let eligible: Bool
}

/// Avoids rapid source flapping while still failing over immediately when a source disappears.
struct AutomaticSelector {
  private(set) var activeID: String?
  private var challengerID: String?
  private var challengerSince: TimeInterval?

  mutating func choose(
    candidates: [SourceCandidate],
    now: TimeInterval,
    margin: Double = 4,
    hold: TimeInterval = 0.35
  ) -> String? {
    let eligible = candidates.filter(\.eligible)
    guard !eligible.isEmpty else {
      activeID = nil
      clearChallenger()
      return nil
    }

    let voiced = eligible.filter(\.voiceActive)
    let pool = voiced.isEmpty ? eligible : voiced
    guard let best = pool.max(by: { $0.score < $1.score }) else { return activeID }

    guard let currentID = activeID,
      let current = eligible.first(where: { $0.id == currentID })
    else {
      activeID = best.id
      clearChallenger()
      return activeID
    }
    guard best.id != current.id else {
      clearChallenger()
      return activeID
    }

    let currentIsInferior =
      (best.voiceActive && !current.voiceActive)
      || best.score >= current.score + margin
    guard currentIsInferior else {
      clearChallenger()
      return activeID
    }

    if challengerID != best.id {
      challengerID = best.id
      challengerSince = now
      return activeID
    }
    if now - (challengerSince ?? now) >= hold {
      activeID = best.id
      clearChallenger()
    }
    return activeID
  }

  mutating func force(_ id: String?) {
    activeID = id
    clearChallenger()
  }

  private mutating func clearChallenger() {
    challengerID = nil
    challengerSince = nil
  }
}

/// Thread-safe bridge between asynchronous input clocks and the output render callback.
final class AudioSamplePipe {
  static let sampleRate = 48_000.0

  private let lock = NSLock()
  private var ring = FloatRingBuffer(capacity: Int(sampleRate * 3))
  private let maximumQueuedFrames = Int(sampleRate * 0.30)

  func append(_ samples: [Float]) {
    lock.lock()
    ring.append(samples)
    if ring.count > maximumQueuedFrames {
      ring.discardOldest(keeping: maximumQueuedFrames)
    }
    lock.unlock()
  }

  func flush() {
    lock.lock()
    ring.removeAll()
    lock.unlock()
  }

  func render(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    guard frames > 0, !buffers.isEmpty else { return }

    lock.lock()
    for frame in 0..<frames {
      let sample = ring.popFirst() ?? 0
      for buffer in buffers {
        guard let data = buffer.mData else { continue }
        let channels = max(1, Int(buffer.mNumberChannels))
        let destination = data.assumingMemoryBound(to: Float.self)
        for channel in 0..<channels {
          destination[frame * channels + channel] = sample
        }
      }
    }
    lock.unlock()
  }
}
