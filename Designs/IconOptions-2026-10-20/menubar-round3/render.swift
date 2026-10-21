import AppKit
import CoreGraphics
import Foundation

struct OptionSet: Decodable { let canvas: CGFloat; let options: [Option] }
struct Option: Decodable {
    let id: String
    let name: String
    let tag: String
    let description: String
    let shapes: [Shape]
}
struct Shape: Decodable {
    let commands: [[Component]]
    let fill: Bool
    let strokeWidth: CGFloat
}
enum Component: Decodable {
    case command(String), number(CGFloat)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) { self = .number(CGFloat(number)) }
        else { self = .command(try value.decode(String.self)) }
    }
    var string: String { if case let .command(value) = self { return value }; preconditionFailure() }
    var number: CGFloat { if case let .number(value) = self { return value }; preconditionFailure() }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let set = try JSONDecoder().decode(OptionSet.self, from: Data(contentsOf: root.appendingPathComponent("options.json")))
func draw(_ option: Option, in ctx: CGContext, ink: CGColor = CGColor(gray: 0, alpha: 1)) {
    ctx.setFillColor(ink)
    ctx.setStrokeColor(ink)
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    for shape in option.shapes {
        let path = CGMutablePath()
        for cmd in shape.commands {
            switch cmd[0].string {
            case "M": path.move(to: CGPoint(x: cmd[1].number, y: cmd[2].number))
            case "L": path.addLine(to: CGPoint(x: cmd[1].number, y: cmd[2].number))
            case "C": path.addCurve(to: CGPoint(x: cmd[5].number, y: cmd[6].number),
                                   control1: CGPoint(x: cmd[1].number, y: cmd[2].number),
                                   control2: CGPoint(x: cmd[3].number, y: cmd[4].number))
            case "Z": path.closeSubpath()
            default: preconditionFailure("Unknown path command")
            }
        }
        ctx.addPath(path)
        if shape.fill { ctx.fillPath() }
        else { ctx.setLineWidth(shape.strokeWidth); ctx.strokePath() }
    }
}
for option in set.options {
    let out = root.appendingPathComponent(option.id, isDirectory: true)
    for scale in [1, 2, 3] {
        let pixels = Int(set.canvas) * scale
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        draw(option, in: ctx)
        let image = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try image.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("menubar-\(pixels)px.png"))
    }
    var box = CGRect(x: 0, y: 0, width: set.canvas, height: set.canvas)
    let consumer = CGDataConsumer(url: out.appendingPathComponent("menubar-template.pdf") as CFURL)!
    let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil); pdf.translateBy(x: 0, y: set.canvas); pdf.scaleBy(x: 1, y: -1)
    draw(option, in: pdf)
    pdf.endPDFPage(); pdf.closePDF()
    print("Rendered \(option.id)")
}

// Exported design board: 1440x740. The browser preview remains responsive.
let boardWidth = 1440
let boardHeight = 740
let board = CGContext(data: nil, width: boardWidth, height: boardHeight,
                      bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
board.translateBy(x: 0, y: CGFloat(boardHeight))
board.scaleBy(x: 1, y: -1)
func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func box(_ rect: CGRect, radius: CGFloat, fill: UInt32, border: UInt32? = nil) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    board.addPath(path); board.setFillColor(color(fill)); board.fillPath()
    if let border {
        board.addPath(path); board.setStrokeColor(color(border)); board.setLineWidth(1); board.strokePath()
    }
}
func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
          size: CGFloat, weight: NSFont.Weight = .regular, shade: UInt32 = 0xf1f4fa) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 3
    (value as NSString).draw(in: CGRect(x: x, y: y, width: width, height: 65), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color(shade))!,
        .paragraphStyle: style
    ])
}
func symbol(_ option: Option, x: CGFloat, y: CGFloat, size: CGFloat, ink: UInt32) {
    board.saveGState(); board.translateBy(x: x, y: y)
    board.scaleBy(x: size / set.canvas, y: size / set.canvas)
    draw(option, in: board, ink: color(ink)); board.restoreGState()
}
board.setFillColor(color(0x111317))
board.fill(CGRect(x: 0, y: 0, width: boardWidth, height: boardHeight))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: board, flipped: true)
text("MNotch", x: 40, y: 33, width: 300, size: 18, weight: .semibold)
text("MENUBAR EXPLORATION / ROUND 03", x: 1170, y: 39, width: 250, size: 10, shade: 0x747e8e)
text("Năm hướng mới cho menubar.", x: 40, y: 94, width: 1100, size: 36, weight: .semibold)
text("Mảng hình gọn, khoảng trống rõ. Mẫu 16 px trên nền sáng và tối.", x: 40, y: 148, width: 1100, size: 13, shade: 0x8793a6)
for (i, option) in set.options.enumerated() {
    let x = CGFloat(40 + i * 276)
    let width: CGFloat = 256
    box(CGRect(x: x, y: 205, width: width, height: 450), radius: 20, fill: 0x1b1e25, border: 0x303641)
    text(String(format: "%02d", i + 1), x: x + 20, y: 226, width: 35, size: 12, weight: .semibold, shade: 0xadbaff)
    text(option.tag, x: x + 86, y: 228, width: 160, size: 9, shade: 0x737f91)
    symbol(option, x: x + 88, y: 282, size: 80, ink: 0xf1f4fb)
    text(option.name, x: x + 20, y: 389, width: 220, size: 25, weight: .medium)
    text(option.description, x: x + 20, y: 431, width: 215, size: 11, shade: 0x929daf)
    text("TRÊN MENUBAR · 16 PX", x: x + 20, y: 485, width: 215, size: 8, shade: 0x68758a)
    for (n, dark) in [false, true].enumerated() {
        let y = CGFloat(505 + n * 42)
        let ink: UInt32 = dark ? 0xf1f4fa : 0x202632
        box(CGRect(x: x + 18, y: y, width: width - 36, height: 34), radius: 7,
            fill: dark ? 0x111419 : 0xe9ecf2, border: dark ? 0x2d333f : nil)
        text("MNotch", x: x + 28, y: y + 10, width: 80, size: 9, weight: .semibold, shade: ink)
        symbol(option, x: x + 140, y: y + 9, size: 16, ink: ink)
        text("14:28", x: x + 190, y: y + 10, width: 45, size: 9, shade: ink)
    }
    board.setStrokeColor(color(0x2c323e)); board.setLineWidth(1)
    board.move(to: CGPoint(x: x + 20, y: 600)); board.addLine(to: CGPoint(x: x + 236, y: 600)); board.strokePath()
    text("32 px", x: x + 22, y: 619, width: 50, size: 9, shade: 0x68758a)
    symbol(option, x: x + 203, y: 610, size: 32, ink: 0xa9b5c7)
}
text("01 / M mềm       02 / Cắt chéo       03 / Quỹ đạo       04 / Dải gập       05 / Widget",
     x: 40, y: 694, width: 1000, size: 11, shade: 0x68758a)
text("SVG / PDF / PNG 16 · 32 · 48 px", x: 1180, y: 694, width: 240, size: 10, shade: 0x68758a)
NSGraphicsContext.restoreGraphicsState()
let sheet = NSBitmapImageRep(cgImage: board.makeImage()!)
try sheet.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("comparison.png"))
print("Exported 1440x740 contact sheet")


