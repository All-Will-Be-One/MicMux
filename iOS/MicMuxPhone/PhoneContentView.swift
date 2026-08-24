import SwiftUI

struct PhoneContentView: View {
  @ObservedObject var model: PhoneModel

  var body: some View {
    NavigationStack {
      Form {
        Section("Mac pairing") {
          TextField("micmux://pair…", text: $model.invitationText, axis: .vertical)
            .lineLimit(2...4)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          HStack {
            Button("Scan QR") { model.openScanner() }
            Button("Paste") { model.pasteInvitation() }
          }
        }

        Section("Microphone") {
          if model.routes.isEmpty {
            Button("Find iPhone, AirPods & glasses") {
              model.requestPermissionAndDiscover()
            }
          } else {
            Picker(
              "Input",
              selection: Binding(
                get: { model.selectedRouteID },
                set: { model.selectRoute($0) }
              )
            ) {
              ForEach(model.routes) { route in
                Label(route.name, systemImage: route.isBluetooth ? "airpodspro" : "mic.fill")
                  .tag(route.id)
              }
            }
            if let current = model.routes.first(where: { $0.id == model.currentRouteID }) {
              LabeledContent("iOS active input", value: "\(current.name) · \(current.kind)")
            }
            if #available(iOS 26.0, *) {
              Toggle("AirPods high-quality recording", isOn: $model.highQualityAirPods)
                .disabled(model.running)
              if model.highQualityAirPods {
                Text(
                  "Full-bandwidth Bluetooth recording can add latency; turn it off for faster handoffs."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
            Text(
              "iOS exposes one active input at a time. Choosing another input while streaming reconnects automatically, and MicMux verifies the actual iOS route before sending audio."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        Section("Link") {
          Button(model.running ? "Stop streaming" : "Start streaming") {
            model.toggle()
          }
          .buttonStyle(.borderedProminent)
          .tint(model.running ? .red : .green)

          if let route = model.activeRoute {
            LabeledContent("Active", value: route.name)
          }
          if let rtt = model.rttMilliseconds {
            LabeledContent("iroh RTT", value: "\(rtt) ms")
          }
          Text(model.status)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section {
          Label("Audio is sent live and is never recorded by MicMux.", systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("MicMux Phone")
      .sheet(isPresented: $model.showingScanner) {
        PairingScannerView { model.acceptScannedCode($0) }
          .ignoresSafeArea()
      }
    }
  }
}
