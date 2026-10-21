import AppKit
import CoreGraphics
import Foundation

struct OptionSet: Decodable { let canvas: CGFloat; let options: [Option] }
struct Option: Decodable {
    let id: String
    let name: String
    let width: CGFloat
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
        let ctx = CGContext(data: nil, width: Int(option.width) * scale, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        draw(option, in: ctx)
        let image = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try image.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(scale == 1 ? "menubar.png" : "menubar@\(scale)x.png"))
    }
    var box = CGRect(x: 0, y: 0, width: option.width, height: set.canvas)
    let consumer = CGDataConsumer(url: out.appendingPathComponent("menubar-template.pdf") as CFURL)!
    let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil); pdf.translateBy(x: 0, y: set.canvas); pdf.scaleBy(x: 1, y: -1)
    draw(option, in: pdf)
    pdf.endPDFPage(); pdf.closePDF()
    print("Rendered \(option.id)")
}

// Native vector contact sheet for the single refined design.
let boardWidth = 1000
let boardHeight = 640
let board = CGContext(data: nil, width: boardWidth, height: boardHeight,
                      bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
board.translateBy(x: 0, y: CGFloat(boardHeight)); board.scaleBy(x: 1, y: -1)
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
        .foregroundColor: NSColor(cgColor: color(shade))!, .paragraphStyle: style
    ])
}
func symbol(_ option: Option, x: CGFloat, y: CGFloat, size: CGFloat, ink: UInt32) {
    board.saveGState(); board.translateBy(x: x, y: y); board.scaleBy(x: size/16, y: size/16)
    draw(option, in: board, ink: color(ink)); board.restoreGState()
}
board.setFillColor(color(0x111317)); board.fill(CGRect(x: 0, y: 0, width: boardWidth, height: boardHeight))
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: board, flipped: true)
text("MNotch", x: 40, y: 32, width: 300, size: 18, weight: .semibold)
text("M FLOW / REFINED", x: 820, y: 38, width: 170, size: 10, shade: 0x748094)
text("M gọn, chân phải lửng.", x: 40, y: 89, width: 850, size: 34, weight: .semibold)
text("Chân phải bằng một nửa chân trái. Sóng nhạc giữ ở giữa, nếp gấp bo nhẹ.", x: 40, y: 143, width: 900, size: 12, shade: 0x8793a6)
let option = set.options[0]
for (i, dark) in [true, false].enumerated() {
    let x = CGFloat(40+i*470)
    let ink: UInt32 = dark ? 0xf1f4fb : 0x202632
    let secondary: UInt32 = dark ? 0x7a879b : 0x8993a4
    box(CGRect(x: x, y: 190, width: 450, height: 385), radius: 20,
        fill: dark ? 0x1b1e25 : 0xf2f4f8, border: dark ? 0x303641 : 0xe0e5ee)
    text(dark ? "NỀN TỐI" : "NỀN SÁNG", x: x+22, y: 213, width: 150, size: 10, shade: secondary)
    text("16 × 16 px", x: x+362, y: 213, width: 80, size: 9, shade: secondary)
    symbol(option, x: x+177, y: 266, size: 96, ink: ink)
    text(dark ? "Nét bo tròn · Chân phải nửa" : "Sóng nằm giữa · Ba thanh và chấm",
         x: x+22, y: 398, width: 410, size: 12, shade: secondary)
    text("TRÊN MENUBAR · KÍCH THƯỚC THỰC", x: x+22, y: 443, width: 400, size: 8, shade: secondary)
    box(CGRect(x: x+18, y: 464, width: 414, height: 36), radius: 8,
        fill: dark ? 0x111419 : 0xe1e6ee, border: dark ? 0x2d333f : nil)
    text("MNotch", x: x+30, y: 475, width: 100, size: 10, weight: .semibold, shade: ink)
    symbol(option, x: x+326, y: 474, size: 16, ink: ink)
    text("14:28", x: x+379, y: 475, width: 45, size: 10, shade: ink)
    text("Phóng lớn 2×", x: x+22, y: 540, width: 130, size: 10, shade: secondary)
    symbol(option, x: x+389, y: 529, size: 32, ink: secondary)
}
text("M hẹp hơn · Chân phải ½ · Sóng ở giữa", x: 40, y: 609, width: 750, size: 11, shade: 0x68758a)
text("SVG / PDF / PNG 1× · 2× · 3×", x: 805, y: 609, width: 190, size: 10, shade: 0x68758a)
NSGraphicsContext.restoreGraphicsState()
let sheet = NSBitmapImageRep(cgImage: board.makeImage()!)
try sheet.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("preview.png"))
print("Exported refined M preview")


