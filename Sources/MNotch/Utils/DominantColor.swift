import CoreImage
import Foundation

enum DominantColor {
    struct Components: Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Average artwork color, pushed toward a vivid, glow-friendly tone.
    /// Accepting Data keeps the entire Core Image render off the main actor.
    nonisolated static func accent(from imageData: Data) -> Components {
        guard let ciImage = CIImage(data: imageData) else { return white }
        let extent = ciImage.extent
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ]), let output = filter.outputImage else { return white }

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

        let red = Double(pixel[0]) / 255
        let green = Double(pixel[1]) / 255
        let blue = Double(pixel[2]) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        var hue = 0.0
        if delta > 0 {
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maximum == 0 ? 0 : delta / maximum
        return rgb(
            hue: hue,
            saturation: min(max(saturation * 1.6, 0.45), 1),
            brightness: min(max(maximum, 0.65), 0.95)
        )
    }

    private nonisolated static let white = Components(red: 1, green: 1, blue: 1)

    private nonisolated static func rgb(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> Components {
        let i = floor(hue * 6)
        let fraction = hue * 6 - i
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - fraction * saturation)
        let t = brightness * (1 - (1 - fraction) * saturation)
        return switch Int(i).quotientAndRemainder(dividingBy: 6).remainder {
        case 0: Components(red: brightness, green: t, blue: p)
        case 1: Components(red: q, green: brightness, blue: p)
        case 2: Components(red: p, green: brightness, blue: t)
        case 3: Components(red: p, green: q, blue: brightness)
        case 4: Components(red: t, green: p, blue: brightness)
        default: Components(red: brightness, green: p, blue: q)
        }
    }
}
