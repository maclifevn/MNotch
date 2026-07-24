#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: create-dmg-background.swift OUTPUT.png\n".utf8))
    exit(2)
}

let width = 640
let height = 380
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not allocate DMG background")
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create drawing context")
}
NSGraphicsContext.current = context

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSColor(calibratedRed: 0.045, green: 0.047, blue: 0.055, alpha: 1).setFill()
bounds.fill()

// A restrained highlight makes the black installer feel native without
// competing with the app and Applications icons placed by Finder.
let glow = NSGradient(colors: [
    NSColor(calibratedWhite: 1, alpha: 0.075),
    NSColor(calibratedWhite: 1, alpha: 0),
])!
glow.draw(
    fromCenter: NSPoint(x: width / 2, y: 225),
    radius: 0,
    toCenter: NSPoint(x: width / 2, y: 225),
    radius: 265,
    options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
)

func centered(_ string: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: 0.15,
    ]
    let size = string.size(withAttributes: attributes)
    string.draw(
        at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: y),
        withAttributes: attributes
    )
}

centered(
    "Install MNotch",
    y: 326,
    font: .systemFont(ofSize: 22, weight: .semibold),
    color: .white
)
centered(
    "Drag MNotch to Applications",
    y: 302,
    font: .systemFont(ofSize: 12.5, weight: .regular),
    color: NSColor(calibratedWhite: 0.72, alpha: 1)
)

// Center arrow between the Finder icons. Rounded strokes keep it legible at
// 1× while remaining quiet on Retina displays.
NSColor(calibratedWhite: 1, alpha: 0.58).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 284, y: 176))
arrow.line(to: NSPoint(x: 356, y: 176))
arrow.move(to: NSPoint(x: 344, y: 188))
arrow.line(to: NSPoint(x: 357, y: 176))
arrow.line(to: NSPoint(x: 344, y: 164))
arrow.stroke()

centered(
    "macOS 15+  ·  Apple silicon",
    y: 31,
    font: .systemFont(ofSize: 10.5, weight: .medium),
    color: NSColor(calibratedWhite: 0.42, alpha: 1)
)

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode DMG background")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
