import SwiftUI

/// A compact rolling envelope; the view receives already-downsampled audio-thread data.
struct WaveformView: View {
  let samples: [Float]
  let active: Bool

  var body: some View {
    Canvas { context, size in
      guard samples.count > 1 else { return }
      let middle = size.height / 2
      let stride = size.width / CGFloat(samples.count - 1)
      var upper = Path()
      var lower = Path()

      for (index, value) in samples.enumerated() {
        let x = CGFloat(index) * stride
        let amplitude = max(1, CGFloat(min(1, value)) * middle * 0.92)
        if index == 0 {
          upper.move(to: CGPoint(x: x, y: middle - amplitude))
          lower.move(to: CGPoint(x: x, y: middle + amplitude))
        } else {
          upper.addLine(to: CGPoint(x: x, y: middle - amplitude))
          lower.addLine(to: CGPoint(x: x, y: middle + amplitude))
        }
      }
      context.stroke(upper, with: .color(active ? .green : .secondary), lineWidth: 1.3)
      context.stroke(lower, with: .color(active ? .green : .secondary), lineWidth: 1.3)
    }
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityLabel(active ? "Active microphone waveform" : "Microphone waveform")
  }
}
