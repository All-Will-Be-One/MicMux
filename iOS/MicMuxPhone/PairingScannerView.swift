import AVFoundation
import SwiftUI
import UIKit

/// Small native QR scanner dedicated to the Mac's private MicMux invitation.
struct PairingScannerView: UIViewControllerRepresentable {
  let onCode: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

  func makeUIViewController(context: Context) -> ScannerViewController {
    let controller = ScannerViewController()
    context.coordinator.configure(controller)
    return controller
  }

  func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

  final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let onCode: (String) -> Void
    private var delivered = false

    init(onCode: @escaping (String) -> Void) {
      self.onCode = onCode
    }

    func configure(_ controller: ScannerViewController) {
      guard let camera = AVCaptureDevice.default(for: .video),
        let input = try? AVCaptureDeviceInput(device: camera),
        controller.session.canAddInput(input)
      else { return }
      controller.session.addInput(input)
      let output = AVCaptureMetadataOutput()
      guard controller.session.canAddOutput(output) else { return }
      controller.session.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main)
      output.metadataObjectTypes = [.qr]
      controller.start()
    }

    func metadataOutput(
      _ output: AVCaptureMetadataOutput,
      didOutput metadataObjects: [AVMetadataObject],
      from connection: AVCaptureConnection
    ) {
      guard !delivered,
        let code = metadataObjects.compactMap({
          ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
        }).first
      else { return }
      delivered = true
      onCode(code)
    }
  }
}

final class ScannerViewController: UIViewController {
  let session = AVCaptureSession()
  private lazy var preview = AVCaptureVideoPreviewLayer(session: session)

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview.frame = view.bounds
  }

  func start() {
    DispatchQueue(label: "audio.micmux.qr-camera").async { [session] in
      session.startRunning()
    }
  }

  deinit { session.stopRunning() }
}
