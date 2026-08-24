import AppKit
import SwiftUI

/// The standalone routing console: sources on top, one stable destination beneath them.
struct ContentView: View {
  @ObservedObject var model: MicMuxModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          sourceSection
          phoneSection
          processingSection
          outputSection
          monitorSection
          statusSection
        }
        .padding(22)
      }
    }
    .frame(minWidth: 780, minHeight: 590)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "waveform.badge.mic")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(.green)
      VStack(alignment: .leading, spacing: 2) {
        Text("MicMux").font(.title2.bold())
        Text("Many microphones. One clean input.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker(
        "Selection",
        selection: Binding(
          get: { model.selectionMode },
          set: { model.setSelectionMode($0) }
        )
      ) {
        ForEach(SelectionMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
      }
      .pickerStyle(.segmented)
      .frame(width: 240)

      Button(model.running ? "Stop" : "Start") {
        model.toggleRunning()
      }
      .buttonStyle(.borderedProminent)
      .tint(model.running ? .red : .green)
      .keyboardShortcut(.space, modifiers: [.command])
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 16)
  }

  private var phoneSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("iPhone & wearables").font(.headline)
        Text(model.phoneReceiverStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(alignment: .top, spacing: 16) {
        if let invitation = model.pairingInvitation {
          PairingQRCodeView(value: invitation)
            .frame(width: 112, height: 112)
          VStack(alignment: .leading, spacing: 8) {
            Text("Scan this in MicMux Phone, or copy it with Universal Clipboard.")
              .font(.callout)
            Button("Copy pairing invitation") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(invitation, forType: .string)
            }
            .buttonStyle(.bordered)
            Text("The invitation contains a private pairing secret. Share it only with your phone.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          ProgressView().controlSize(.small)
          Text("Waiting for an iroh address…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(14)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

      ForEach(model.remoteSources) { source in remoteSourceRow(source) }
    }
  }

  private func remoteSourceRow(_ source: RemoteSourcePresentation) -> some View {
    let active = model.activeSourceID == source.id
    return VStack(spacing: 10) {
      HStack(spacing: 12) {
        Toggle(
          "",
          isOn: Binding(
            get: { source.enabled },
            set: { model.setRemoteSourceEnabled($0, id: source.id) }
          )
        )
        .labelsHidden()

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(source.descriptor.name).fontWeight(.medium)
            Text("IPHONE").badgeStyle(color: .purple)
            if active {
              Text(model.selectionMode == .blend ? "LEAD" : "ACTIVE").badgeStyle(color: .green)
            }
          }
          Text(
            source.descriptor.detail
              + source.descriptor.rttMilliseconds.map { " · \($0) ms RTT" }.orEmpty
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Pin") { model.pin(source.id) }
          .buttonStyle(.bordered)
          .disabled(!source.enabled || !source.descriptor.connected)
      }

      HStack(spacing: 14) {
        WaveformView(samples: source.waveform, active: active)
          .frame(height: 52)
        metric("Level", String(format: "%.1f dB", source.rmsDB))
        metric("SNR", String(format: "%.1f dB", source.snrDB))
        metric("Score", String(format: "%.1f", source.score))
        Circle()
          .fill(
            source.voiceActive
              ? Color.green : (source.descriptor.connected ? Color.secondary : Color.red)
          )
          .frame(width: 9, height: 9)
      }
    }
    .padding(14)
    .background(active ? Color.green.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(active ? Color.green.opacity(0.7) : Color.secondary.opacity(0.18), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .opacity(source.enabled ? 1 : 0.58)
  }

  private var sourceSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Sources").font(.headline)
        Text("MicMux listens only while running")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if model.sources.isEmpty {
        ContentUnavailableView(
          "No microphones found",
          systemImage: "mic.slash",
          description: Text("Connect an input device and it will appear here.")
        )
        .frame(height: 180)
      } else {
        ForEach(model.sources) { source in sourceRow(source) }
      }
    }
  }

  private func sourceRow(_ source: SourcePresentation) -> some View {
    let active = model.activeSourceID == source.id
    return VStack(spacing: 10) {
      HStack(spacing: 12) {
        Toggle(
          "",
          isOn: Binding(
            get: { source.enabled },
            set: { model.setSourceEnabled($0, id: source.id) }
          )
        )
        .labelsHidden()

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(source.device.name).fontWeight(.medium)
            if source.device.isDefaultInput {
              Text("DEFAULT").badgeStyle(color: .blue)
            }
            if source.device.isVirtual {
              Text("VIRTUAL").badgeStyle(color: .orange)
            }
            if active {
              Text("ACTIVE").badgeStyle(color: .green)
            }
          }
          Text(
            "\(source.device.transportLabel) · \(source.device.inputChannels) input channel\(source.device.inputChannels == 1 ? "" : "s")"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()

        if source.device.inputChannels > 1 {
          Picker(
            "Channel",
            selection: Binding(
              get: { source.channel },
              set: { model.setChannel($0, id: source.id) }
            )
          ) {
            ForEach(0..<source.device.inputChannels, id: \.self) { channel in
              Text("Channel \(channel + 1)").tag(channel)
            }
          }
          .frame(width: 120)
        }

        Button("Pin") { model.pin(source.id) }
          .buttonStyle(.bordered)
          .disabled(!source.enabled)
      }

      HStack(spacing: 14) {
        WaveformView(samples: source.waveform, active: active)
          .frame(height: 52)
        metric("Level", String(format: "%.1f dB", source.rmsDB))
        metric("SNR", String(format: "%.1f dB", source.snrDB))
        metric("Score", String(format: "%.1f", source.score))
        Circle()
          .fill(source.voiceActive ? Color.green : (source.healthy ? Color.secondary : Color.red))
          .frame(width: 9, height: 9)
          .help(source.voiceActive ? "Voice detected" : (source.healthy ? "Live" : "No audio"))
      }

      if let error = source.error {
        Text(error).font(.caption).foregroundStyle(.red).frame(
          maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(14)
    .background(active ? Color.green.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(active ? Color.green.opacity(0.7) : Color.secondary.opacity(0.18), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .opacity(source.enabled ? 1 : 0.58)
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.system(.caption, design: .monospaced)).frame(
        width: 68, alignment: .trailing)
    }
  }

  private var outputSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Output").font(.headline)
      HStack(spacing: 12) {
        Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
        Picker(
          "Forward selected audio to",
          selection: Binding(
            get: { model.selectedOutputID },
            set: { model.setOutput($0) }
          )
        ) {
          Text("Waveforms only — no output").tag("")
          ForEach(model.outputs) { output in
            Text(
              output.name
                + (output.name.localizedCaseInsensitiveContains("BlackHole")
                  ? " — recommended" : "")
            )
            .tag(output.id)
          }
        }
        .frame(maxWidth: 480)
        Spacer()
        Text("Select this device as the microphone in the receiving app.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(14)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private var processingSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Processing").font(.headline)
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Image(systemName: "speaker.wave.2.bubble.left.fill").foregroundStyle(.blue)
          Picker(
            "Mac speaker reference",
            selection: Binding(
              get: { model.echoReferenceID },
              set: { model.setEchoReference($0) }
            )
          ) {
            Text("Off — no echo subtraction").tag("")
            ForEach(model.sources.filter { $0.id != model.selectedOutputID }) { source in
              Text(source.device.name + (source.device.isVirtual ? " — loopback" : ""))
                .tag(source.id)
            }
          }
          .frame(maxWidth: 430)
          Spacer()
        }

        if !model.echoReferenceID.isEmpty {
          HStack(spacing: 18) {
            Stepper(
              "Reference delay: \(model.echoDelayMilliseconds) ms",
              value: Binding(
                get: { model.echoDelayMilliseconds },
                set: {
                  model.setEchoParameters(delayMilliseconds: $0, strength: model.echoStrength)
                }
              ),
              in: 0...250,
              step: 5
            )
            Picker(
              "Subtraction",
              selection: Binding(
                get: { model.echoStrength },
                set: {
                  model.setEchoParameters(
                    delayMilliseconds: model.echoDelayMilliseconds,
                    strength: $0
                  )
                }
              )
            ) {
              Text("Gentle").tag(0.6)
              Text("Normal").tag(1.0)
              Text("Strong").tag(1.2)
            }
            .frame(width: 180)
          }
          Text(
            "Route Mac system audio into this reference with BlackHole or a Multi-Output Device. Use a separate virtual device as MicMux Output."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if model.selectionMode == .blend {
          Label(
            "Blend time-aligns source queues, favors clearer voiced microphones, normalizes gain, and soft-limits the result.",
            systemImage: "waveform.path.ecg.rectangle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .padding(14)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private var monitorSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Monitor (test)").font(.headline)
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Image(systemName: "headphones").foregroundStyle(.orange)
          Picker(
            "Hear processed input through",
            selection: Binding(
              get: { model.monitorOutputID },
              set: { model.setMonitorOutput($0) }
            )
          ) {
            Text("Off").tag("")
            ForEach(model.safeMonitorOutputs) { output in
              Text(output.name).tag(output.id)
            }
          }
          .frame(maxWidth: 430)
          Spacer()
        }

        if !model.monitorOutputID.isEmpty {
          HStack(spacing: 12) {
            Text("Monitor volume")
            Slider(
              value: Binding(
                get: { model.monitorVolume },
                set: { model.setMonitorVolume($0) }
              ),
              in: 0...1
            )
            .frame(maxWidth: 260)
            Text("\(Int(model.monitorVolume * 100))%")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Label(
            "Use headphones when possible. Open-speaker monitoring can feed the processed microphone back into itself and howl.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }
      .padding(14)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private var statusSection: some View {
    HStack(spacing: 8) {
      Image(systemName: model.running ? "dot.radiowaves.left.and.right" : "pause.circle")
      Text(model.status)
      Spacer()
      Text("No audio is recorded or saved")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

extension Optional where Wrapped == String {
  fileprivate var orEmpty: String { self ?? "" }
}

extension View {
  fileprivate func badgeStyle(color: Color) -> some View {
    self
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(color.opacity(0.12), in: Capsule())
  }
}
