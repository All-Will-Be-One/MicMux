import AppKit
import Darwin
import SwiftUI

/// Application entry point shared by the single window and always-available menu-bar control.
@main
struct MicMuxApp: App {
  private let instanceLock: AppInstanceLock
  @StateObject private var model: MicMuxModel

  init() {
    let instanceLock = AppInstanceLock()
    self.instanceLock = instanceLock
    guard instanceLock.isPrimary else {
      instanceLock.activatePrimaryInstance()
      Darwin.exit(EXIT_SUCCESS)
    }
    _model = StateObject(wrappedValue: MicMuxModel())
  }

  var body: some Scene {
    Window("MicMux", id: "main") {
      ContentView(model: model)
    }
    .defaultSize(width: 900, height: 680)
    .commands {
      CommandGroup(after: .appInfo) {
        Divider()
        Button(
          model.onDemandEnabled
            ? "Disable on-demand capture" : (model.running ? "Stop MicMux" : "Start MicMux")
        ) {
          model.toggleRunning()
        }
        .keyboardShortcut(.space, modifiers: [.command])
      }
    }

    MenuBarExtra {
      MicMuxMenuBarContent(model: model)
    } label: {
      Label(
        "MicMux",
        systemImage: model.running ? "waveform.badge.mic" : "mic"
      )
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct MicMuxMenuBarContent: View {
  @ObservedObject var model: MicMuxModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(
      model.onDemandEnabled
        ? "Disable on-demand capture" : (model.running ? "Stop MicMux" : "Start MicMux")
    ) {
      model.toggleRunning()
    }

    Toggle(
      "On-demand capture",
      isOn: Binding(
        get: { model.onDemandEnabled }, set: { model.setOnDemandEnabled($0) }))
    Text(model.demandStatus)

    Menu("Selection: \(model.selectionMode.rawValue)") {
      ForEach(SelectionMode.allCases) { mode in
        Button(mode.rawValue) { model.setSelectionMode(mode) }
      }
    }

    Menu("Monitor: \(monitorName)") {
      Button("Off") { model.setMonitorOutput("") }
      Divider()
      ForEach(model.safeMonitorOutputs) { output in
        Button(output.name) { model.setMonitorOutput(output.id) }
      }
    }

    Divider()
    Button("Show MicMux") {
      openWindow(id: "main")
      _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
    Button("Quit MicMux") {
      NSApplication.shared.terminate(nil)
    }
  }

  private var monitorName: String {
    model.outputs.first(where: { $0.id == model.monitorOutputID })?.name ?? "Off"
  }
}
