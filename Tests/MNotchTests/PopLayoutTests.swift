import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MNotch

@MainActor
final class PopLayoutTests: XCTestCase {
    private struct Fixture {
        let name: String
        let kind: PopKind
    }

    private var fixtures: [Fixture] {
        [
            .init(name: "accessibility", kind: .accessibility),
            .init(name: "charging", kind: .charging(percentage: 89)),
            .init(name: "low-battery", kind: .lowBattery(percentage: 10)),
            .init(name: "low-power-on", kind: .lowPower(on: true)),
            .init(name: "low-power-off", kind: .lowPower(on: false)),
            .init(name: "device-battery", kind: .device(
                name: "Tai nghe không dây của Hoàng Minh", symbol: "headphones", battery: 89
            )),
            .init(name: "device-no-battery", kind: .device(
                name: "Bàn phím không dây của Hoàng Minh", symbol: "keyboard", battery: nil
            )),
            .init(name: "focus-on", kind: .focus(
                name: "Tập trung làm việc không gián đoạn", symbol: "moon.fill", on: true
            )),
            .init(name: "focus-off", kind: .focus(
                name: "Tập trung làm việc không gián đoạn", symbol: "moon.fill", on: false
            )),
            .init(name: "event-now", kind: .event(
                title: "Cuộc họp tổng kết và phát hành ứng dụng", red: 0.2, green: 0.7, blue: 1,
                startingNow: true, start: Date()
            )),
            .init(name: "event-upcoming", kind: .event(
                title: "Cuộc họp tổng kết và phát hành ứng dụng", red: 0.2, green: 0.7, blue: 1,
                startingNow: false, start: Date().addingTimeInterval(300)
            )),
            .init(name: "agent-input", kind: .agent(
                name: "A very long project name", kind: "codex", needsInput: true
            )),
            .init(name: "agent-done", kind: .agent(
                name: "A very long project name", kind: "claude", needsInput: false
            )),
            .init(name: "agent-approved", kind: .agentConfirm(approved: true)),
            .init(name: "agent-rejected", kind: .agentConfirm(approved: false)),
            .init(name: "pomodoro", kind: .pomodoro(
                title: "Đã hoàn thành phiên tập trung", symbol: "timer", detail: "Nghỉ giải lao 25 phút"
            )),
        ]
    }

    func testEveryPopStaysInTheMenuBandWithIdleActivityAndHover() {
        withLayoutSettings {
            for physical in [false, true] {
                for height: CGFloat in [20, 24, 32, 33] {
                    let geometry = NotchGeometry(
                        notchWidth: physical ? 179 : 185,
                        notchHeight: height,
                        isPhysical: physical
                    )
                    for activeIdle in [false, true] {
                        let model = NotchViewModel(geometry: geometry)
                        model.pomodoroActive = activeIdle
                        let closedWidth = model.visualSize.width
                        for hovering in [false, true] {
                            model.setPointerInside(hovering)
                            XCTAssertEqual(model.visualSize.height, height)
                            XCTAssertEqual(model.visualSize.width, closedWidth + (hovering ? 18 : 0))
                            for fixture in fixtures {
                                show(fixture.kind, on: model)
                                XCTAssertEqual(model.status, .pop(fixture.kind), fixture.name)
                                XCTAssertEqual(model.visualSize.height, height, fixture.name)
                                XCTAssertGreaterThan(model.visualSize.width, closedWidth, fixture.name)
                                XCTAssertFalse(model.isAutoHidden, fixture.name)
                                model.collapse()
                                // Dismissing while hovered must not drop the notch down again.
                                XCTAssertEqual(model.visualSize.height, height, fixture.name)
                            }
                        }
                        model.setPointerInside(false)
                    }
                }
            }
        }
    }

    func testRenderedPopsHaveOpaqueBottomNoOverflowAndVisibleWings() throws {
        _ = NSApplication.shared
        try withLayoutSettings {
            for physical in [false, true] {
                for height: CGFloat in [20, 24, 32, 33] {
                    for scale: CGFloat in [1, 2] {
                        for outline in [false, true] {
                            SettingsStore.shared.contrastOutline = outline
                            // Every notification gets the common 33pt render;
                            // dense content and the formerly taller cases also
                            // exercise the smaller supported menu bar bands.
                            let renderFixtures = height == 33 ? fixtures : fixtures.filter {
                                ["accessibility", "charging", "device-battery", "agent-approved", "agent-rejected"]
                                    .contains($0.name)
                            }
                            for fixture in renderFixtures {
                                try autoreleasepool {
                                    let model = NotchViewModel(geometry: .init(
                                        notchWidth: physical ? 179 : 185,
                                        notchHeight: height,
                                        isPhysical: physical
                                    ))
                                    show(fixture.kind, on: model)
                                    defer { model.collapse() }
                                    let renderer = ImageRenderer(content: NotchRootView(viewModel: model)
                                        .environment(\.displayScale, scale))
                                    renderer.scale = scale
                                    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                                    let context = "\(fixture.name), physical=\(physical), height=\(height), scale=\(scale), outline=\(outline)"
                                    try assertBandPixels(bitmap, model: model, scale: scale, context: context)
                                    try exportIfRequested(bitmap, fixture: fixture, physical: physical,
                                                          height: height, scale: scale, outline: outline)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func show(_ kind: PopKind, on model: NotchViewModel) {
        if case .agentConfirm(let approved) = kind {
            // Exercise the real Approve/Reject transition as well as ordinary pops.
            model.confirmAgentDecision(approved: approved)
        } else {
            model.showPop(kind)
        }
    }

    private func assertBandPixels(
        _ bitmap: NSBitmapImageRep,
        model: NotchViewModel,
        scale: CGFloat,
        context: String
    ) throws {
        let bandBottom = Int(model.geometry.notchHeight * scale)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4, bitmap.hasAlpha else {
            XCTFail("Unexpected render pixel format: \(context)")
            return
        }
        let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        func alphaAt(_ x: Int, _ y: Int) -> UInt8 {
            bytes[y * bitmap.bytesPerRow + x * 4 + alpha]
        }

        let inset = model.topRadius + model.bottomRadius + 2
        let left = Int(((NotchViewModel.panelSize.width - model.visualSize.width) / 2 + inset) * scale)
        let right = bitmap.pixelsWide - left
        let translucentBottom = (left..<right).first { alphaAt($0, bandBottom - 1) != 255 }
        XCTAssertNil(translucentBottom, "Transparent slit in flat bottom: \(context)")

        // Check the complete canvas below the menu bar, including the rounded
        // corners and the old agent confirmation shadow, not just the center.
        var firstOverflow: (x: Int, y: Int)?
        for y in bandBottom..<bitmap.pixelsHigh {
            if let x = (0..<bitmap.pixelsWide).first(where: { alphaAt($0, y) != 0 }) {
                firstOverflow = (x, y)
                break
            }
        }
        XCTAssertNil(firstOverflow, "Pixels below menu band at \(String(describing: firstOverflow)): \(context)")

        let center = NotchViewModel.panelSize.width / 2
        let cutoutLeft = Int((center - model.geometry.notchWidth / 2) * scale)
        let cutoutRight = Int((center + model.geometry.notchWidth / 2) * scale)
        let innerRows = Int(2 * scale)..<(bandBottom - Int(2 * scale))
        // A fully clipped/empty notification must not satisfy the bounds test.
        // The 0.25 threshold excludes the optional 14% contrast outline.
        func visibleContent(in columns: Range<Int>) throws -> Int {
            var count = 0
            for y in innerRows {
                for x in columns {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.25 {
                        count += 1
                    }
                }
            }
            return count
        }
        XCTAssertGreaterThan(try visibleContent(in: left..<cutoutLeft), Int(5 * scale * scale),
                             "Missing left wing content: \(context)")
        XCTAssertGreaterThan(try visibleContent(in: cutoutRight..<right), Int(5 * scale * scale),
                             "Missing right wing content: \(context)")
        XCTAssertEqual(try visibleContent(in: cutoutLeft..<cutoutRight), 0,
                       "Notification content covered by camera cutout: \(context)")
    }

    private func exportIfRequested(
        _ bitmap: NSBitmapImageRep,
        fixture: Fixture,
        physical: Bool,
        height: CGFloat,
        scale: CGFloat,
        outline: Bool
    ) throws {
        guard let path = ProcessInfo.processInfo.environment["MNOTCH_POP_RENDER_DIR"],
              physical, scale == 2, outline, [20, 33].contains(height) else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(fixture.name)-\(Int(height))pt@2x.png"))
    }

    private func withLayoutSettings(_ body: () throws -> Void) rethrows {
        let settings = SettingsStore.shared
        let previous = (
            settings.expandOnHover, settings.idleActivity, settings.idleMostRecent,
            settings.calendarEnabled, settings.panelShadow, settings.contrastOutline,
            settings.batteryHideLabel, settings.batteryHidePercentage, settings.focusHideLabel,
            settings.autoHideSimulatedNotch
        )
        settings.expandOnHover = false
        settings.idleActivity = .none
        settings.idleMostRecent = false
        settings.calendarEnabled = false
        settings.panelShadow = true
        settings.batteryHideLabel = false
        settings.batteryHidePercentage = false
        settings.focusHideLabel = false
        settings.autoHideSimulatedNotch = true
        defer {
            settings.expandOnHover = previous.0
            settings.idleActivity = previous.1
            settings.idleMostRecent = previous.2
            settings.calendarEnabled = previous.3
            settings.panelShadow = previous.4
            settings.contrastOutline = previous.5
            settings.batteryHideLabel = previous.6
            settings.batteryHidePercentage = previous.7
            settings.focusHideLabel = previous.8
            settings.autoHideSimulatedNotch = previous.9
        }
        try body()
    }
}
