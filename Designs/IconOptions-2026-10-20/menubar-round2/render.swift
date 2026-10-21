import AppKit
import CoreGraphics
import Foundation

struct OptionSet: Decodable { let canvas: CGFloat; let options: [Option] }
struct Option: Decodable { let id: String; let shapes: [Shape] }
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

// A fixed-size contact sheet is an exported design artifact. The browser
// preview remains responsive and uses the user's normal window dimensions.
let boardWidth = 1280
let boardHeight = 660
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
          size: CGFloat, weight: NSFont.Weight = .regular, shade: UInt32 = 0x20242d) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 3
    (value as NSString).draw(in: CGRect(x: x, y: y, width: width, height: 70), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color(shade))!,
        .paragraphStyle: style
    ])
}
func symbol(_ option: Option, x: CGFloat, y: CGFloat, size: CGFloat, ink: UInt32) {
    board.saveGState(); board.translateBy(x: x, y: y); board.scaleBy(x: size / 16, y: size / 16)
    draw(option, in: board, ink: color(ink)); board.restoreGState()
}
board.setFillColor(color(0xf4f5f8))
board.fill(CGRect(x: 0, y: 0, width: boardWidth, height: boardHeight))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: board, flipped: true)
text("MNotch", x: 40, y: 30, width: 300, size: 17, weight: .bold)
text("MENUBAR EXPLORATION / ROUND 02", x: 975, y: 35, width: 280, size: 10, shade: 0x8993a4)
text("4 hướng menubar mới.", x: 40, y: 80, width: 900, size: 34, weight: .bold)
text("Bản phóng lớn và mẫu 16 px trên nền sáng / tối.", x: 40, y: 128, width: 900, size: 13, shade: 0x7d8798)
let names = ["Notch thuần", "Chữ M", "Khung mở", "Âm bản"]
let details = ["Chỉ giữ dấu notch, bỏ khung bao quanh.",
               "Hai đỉnh núi, cùng nhận diện với icon app 01.",
               "Bốn góc tách rời, đặt notch ở giữa cạnh trên.",
               "Khối vuông đặc với notch khoét âm phía trên."]
for (i, option) in set.options.enumerated() {
    let x = CGFloat(40 + i * 304)
    let width: CGFloat = 288
    box(CGRect(x: x, y: 180, width: width, height: 410), radius: 20, fill: 0xffffff, border: 0xe1e5ed)
    text(String(format: "%02d", i + 1), x: x + 20, y: 201, width: 80, size: 13, weight: .semibold, shade: 0x4667b6)
    symbol(option, x: x + 108, y: 241, size: 72, ink: 0x272f3c)
    text(names[i], x: x + 20, y: 340, width: 250, size: 22, weight: .semibold)
    text(details[i], x: x + 20, y: 378, width: 245, size: 12, shade: 0x7d8798)
    text("TRÊN MENUBAR · 16 PX", x: x + 20, y: 434, width: 240, size: 9, shade: 0x939dac)
    for (n, dark) in [false, true].enumerated() {
        let y = CGFloat(455 + n * 42)
        let ink: UInt32 = dark ? 0xf6f8fc : 0x292e38
        box(CGRect(x: x + 18, y: y, width: width - 36, height: 34), radius: 7,
            fill: dark ? 0x242833 : 0xedf0f6)
        text("MNotch", x: x + 28, y: y + 10, width: 80, size: 10, weight: .semibold, shade: ink)
        symbol(option, x: x + 162, y: y + 9, size: 16, ink: ink)
        text("14:28", x: x + 209, y: y + 10, width: 45, size: 10, shade: ink)
    }
    text("16 px", x: x + 22, y: 553, width: 40, size: 10, shade: 0x939dac)
    symbol(option, x: x + 70, y: 550, size: 16, ink: 0x454d5d)
    text("32 px", x: x + 159, y: 553, width: 40, size: 10, shade: 0x939dac)
    symbol(option, x: x + 219, y: 542, size: 32, ink: 0x454d5d)
}
text("Gợi ý: 02 đồng bộ với icon app · 03 thoáng và nhẹ hơn khung kín", x: 40, y: 617, width: 850, size: 11, shade: 0x7d8798)
text("SVG / PDF / PNG 16 · 32 · 48 px", x: 1030, y: 617, width: 220, size: 10, shade: 0x939dac)
NSGraphicsContext.restoreGraphicsState()
let contactSheet = NSBitmapImageRep(cgImage: board.makeImage()!)
try contactSheet.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("comparison.png"))
print("Exported 1280x660 contact sheet")

