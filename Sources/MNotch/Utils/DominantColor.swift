import AppKit
import CoreImage
import SwiftUI

enum DominantColor {
    /// Average color of the artwork, pushed toward a vivid, glow-friendly tone.
    static func accent(from image: NSImage) -> Color {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff)
        else { return .white }

        let extent = ciImage.extent
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ]), let output = filter.outputImage else { return .white }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let base = NSColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        ).usingColorSpace(.deviceRGB) ?? .white

        // Averages skew muddy; re-saturate and keep brightness in a band that
        // reads well against pure black.
        let vivid = NSColor(
            hue: base.hueComponent,
            saturation: min(max(base.saturationComponent * 1.6, 0.45), 1),
            brightness: min(max(base.brightnessComponent, 0.65), 0.95),
            alpha: 1
        )
        return Color(nsColor: vivid)
    }
}
