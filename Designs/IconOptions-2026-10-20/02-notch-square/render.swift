import AppKit
import CoreGraphics
import Foundation

// Square revision of option 02. Coordinates match menubar.svg (18x18).
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func draw(_ ctx: CGContext) {
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.setLineWidth(1.5)
    ctx.addPath(CGPath(
        roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16),
        cornerWidth: 3, cornerHeight: 3, transform: nil
    ))
    ctx.strokePath()
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: 6, y: 1))
    notch.addLine(to: CGPoint(x: 12, y: 1))
    notch.addLine(to: CGPoint(x: 12, y: 2.25))
    notch.addCurve(to: CGPoint(x: 10.25, y: 4),
                   control1: CGPoint(x: 12, y: 3.216),
                   control2: CGPoint(x: 11.216, y: 4))
    notch.addLine(to: CGPoint(x: 7.75, y: 4))
    notch.addCurve(to: CGPoint(x: 6, y: 2.25),
                   control1: CGPoint(x: 6.784, y: 4),
                   control2: CGPoint(x: 6, y: 3.216))
    notch.closeSubpath()
    ctx.addPath(notch)
    ctx.fillPath()
}
for scale in [1, 2, 3] {
    let size = 18 * scale
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("menubar-\(size)px.png"))
}
var box = CGRect(x: 0, y: 0, width: 18, height: 18)
let consumer = CGDataConsumer(url: out.appendingPathComponent("menubar-template.pdf") as CFURL)!
let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
pdf.translateBy(x: 0, y: 18)
pdf.scaleBy(x: 1, y: -1)
draw(pdf)
pdf.endPDFPage()
pdf.closePDF()
print("Rendered square notch: SVG-compatible PNG 18/36/54 px and PDF")

