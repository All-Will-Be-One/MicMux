import SwiftUI

/// iPhone companion that turns the active iOS audio route into a secure MicMux source.
@main
struct MicMuxPhoneApp: App {
  @StateObject private var model = PhoneModel()

  var body: some Scene {
    WindowGroup {
      PhoneContentView(model: model)
        .onOpenURL { model.acceptPairingURL($0) }
    }
  }
}
