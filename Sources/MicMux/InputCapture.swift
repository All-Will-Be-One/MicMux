import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Owns one input-only AUHAL instance so several unrelated devices can run concurrently.
final class InputCapture {
  typealias SampleHandler = (_ samples: [Float], _ sampleRate: Double, _ hostTime: UInt64) -> Void

  let device: AudioDeviceDescriptor
  var onSamples: SampleHandler?
  var onError: ((String) -> Void)?

  private let channelLock = NSLock()
  private let renderErrorLock = NSLock()
  private var selectedChannel = 0
  private var reportedRenderError = false
  private var audioUnit: AudioUnit?
  private var captureFormat: AVAudioFormat?

  init(device: AudioDeviceDescriptor, channel: Int) {
    self.device = device
    selectedChannel = max(0, min(channel, device.inputChannels - 1))
  }

  func setChannel(_ channel: Int) {
    channelLock.lock()
    selectedChannel = max(0, min(channel, device.inputChannels - 1))
    channelLock.unlock()
  }

  func start() throws {
    guard audioUnit == nil else { return }
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
      throw CaptureError.stage("Core Audio did not provide an AUHAL component")
    }
    var candidate: AudioUnit?
    try check(AudioComponentInstanceNew(component, &candidate), stage: "creating capture")
    guard let unit = candidate else {
      throw CaptureError.stage("Core Audio returned no capture unit")
    }

    do {
      try setIOEnabled(false, unit: unit, scope: kAudioUnitScope_Output, bus: 0)
      try setIOEnabled(true, unit: unit, scope: kAudioUnitScope_Input, bus: 1)

      var deviceID = device.objectID
      try check(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_CurrentDevice,
          kAudioUnitScope_Global,
          0,
          &deviceID,
          UInt32(MemoryLayout<AudioDeviceID>.size)
        ),
        stage: "opening \(device.name)"
      )

      var hardwareDescription = AudioStreamBasicDescription()
      var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      try check(
        AudioUnitGetProperty(
          unit,
          kAudioUnitProperty_StreamFormat,
          kAudioUnitScope_Input,
          1,
          &hardwareDescription,
          &descriptionSize
        ),
        stage: "reading \(device.name)'s format"
      )
      guard hardwareDescription.mSampleRate > 0,
        hardwareDescription.mChannelsPerFrame > 0,
        let format = AVAudioFormat(
          standardFormatWithSampleRate: hardwareDescription.mSampleRate,
          channels: hardwareDescription.mChannelsPerFrame
        )
      else {
        throw CaptureError.stage("\(device.name) has no usable input format")
      }
      var clientDescription = format.streamDescription.pointee
      try check(
        AudioUnitSetProperty(
          unit,
          kAudioUnitProperty_StreamFormat,
          kAudioUnitScope_Output,
          1,
          &clientDescription,
          UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ),
        stage: "matching \(device.name)'s sample rate"
      )

      var callback = AURenderCallbackStruct(
        inputProc: { reference, flags, timestamp, _, frameCount, _ in
          Unmanaged<InputCapture>
            .fromOpaque(reference)
            .takeUnretainedValue()
            .render(flags: flags, timestamp: timestamp, frameCount: frameCount)
        },
        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
      )
      try check(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_SetInputCallback,
          kAudioUnitScope_Global,
          0,
          &callback,
          UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ),
        stage: "installing \(device.name)'s callback"
      )
      try check(AudioUnitInitialize(unit), stage: "initializing \(device.name)")

      audioUnit = unit
      captureFormat = format
      renderErrorLock.lock()
      reportedRenderError = false
      renderErrorLock.unlock()
      let status = AudioOutputUnitStart(unit)
      if status != noErr {
        audioUnit = nil
        captureFormat = nil
        AudioUnitUninitialize(unit)
        throw CaptureError.stage("starting \(device.name): OSStatus \(status)")
      }
    } catch {
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
      throw error
    }
  }

  func stop() {
    guard let unit = audioUnit else { return }
    AudioOutputUnitStop(unit)
    audioUnit = nil
    captureFormat = nil
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
  }

  private func render(
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32
  ) -> OSStatus {
    guard let unit = audioUnit,
      let format = captureFormat,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else {
      return kAudio_ParamError
    }
    guard prepareBufferForAudioUnitRender(buffer, frameCount: frameCount) else {
      return kAudio_ParamError
    }
    let status = AudioUnitRender(
      unit,
      flags,
      timestamp,
      1,
      frameCount,
      buffer.mutableAudioBufferList
    )
    guard status == noErr else {
      reportRenderError(status)
      return status
    }

    channelLock.lock()
    let channel = selectedChannel
    channelLock.unlock()
    guard let channels = buffer.floatChannelData,
      channel < Int(buffer.format.channelCount)
    else { return kAudio_ParamError }
    let samples = Array(UnsafeBufferPointer(start: channels[channel], count: Int(frameCount)))
    onSamples?(samples, format.sampleRate, timestamp.pointee.mHostTime)
    return noErr
  }

  private func reportRenderError(_ status: OSStatus) {
    renderErrorLock.lock()
    let shouldReport = !reportedRenderError
    reportedRenderError = true
    renderErrorLock.unlock()
    guard shouldReport else { return }
    DispatchQueue.main.async { [weak self] in
      self?.onError?("Audio render failed: OSStatus \(status)")
    }
  }

  private func setIOEnabled(
    _ enabled: Bool,
    unit: AudioUnit,
    scope: AudioUnitScope,
    bus: AudioUnitElement
  ) throws {
    var value: UInt32 = enabled ? 1 : 0
    try check(
      AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_EnableIO,
        scope,
        bus,
        &value,
        UInt32(MemoryLayout<UInt32>.size)
      ),
      stage: "configuring \(device.name)"
    )
  }

  private func check(_ status: OSStatus, stage: String) throws {
    guard status == noErr else { throw CaptureError.stage("\(stage): OSStatus \(status)") }
  }

  deinit { stop() }

  enum CaptureError: LocalizedError {
    case stage(String)
    var errorDescription: String? {
      guard case .stage(let detail) = self else { return "Audio capture failed" }
      return detail
    }
  }
}

/// Publishes the writable byte capacity that AUHAL validates before rendering into a PCM buffer.
func prepareBufferForAudioUnitRender(
  _ buffer: AVAudioPCMBuffer,
  frameCount: UInt32
) -> Bool {
  guard frameCount > 0, frameCount <= buffer.frameCapacity else { return false }
  buffer.frameLength = frameCount
  return UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).allSatisfy {
    $0.mData != nil && $0.mDataByteSize > 0
  }
}
