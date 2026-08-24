import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders the private iroh invitation locally; no pairing data leaves the Mac.
struct PairingQRCodeView: View {
  let value: String

  var body: some View {
    Group {
      if let image = qrImage {
        Image(nsImage: image)
          .resizable()
          .interpolation(.none)
          .antialiased(false)
      } else {
        Image(systemName: "qrcode")
          .resizable()
          .scaledToFit()
          .foregroundStyle(.secondary)
      }
    }
    .padding(6)
    .background(.white, in: RoundedRectangle(cornerRadius: 8))
  }

  private var qrImage: NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
      let cgImage = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(
      cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
  }
}
