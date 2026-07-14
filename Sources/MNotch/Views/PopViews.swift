import SwiftUI

/// Two fixed-width wings flanking the camera cutout. Hard-frames both sides
/// so long content truncates inside its wing instead of stretching the
/// layout and sliding under the physical cutout (the overflow class already
/// fixed once in CalendarCompactView).
struct PopWings<Left: View, Right: View>: View {
    let geometry: NotchGeometry
    var wingWidth: CGFloat = 86
    var sidePadding: CGFloat = 14
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(spacing: 0) {
            left
                .frame(width: wingWidth, alignment: .leading)
            Spacer(minLength: geometry.notchWidth)
            right
                .frame(width: wingWidth, alignment: .trailing)
        }
        .padding(.horizontal, sidePadding)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.top, 2)
    }
}

/// Charging / low-battery / low-power pop: glyph (+ optional label) on the
/// left wing, percentage counting on the right.
struct BatteryPopView: View {
    enum Kind {
        case charging
        case low
        case lowPower(on: Bool)
    }

    let percentage: Int
    let kind: Kind
    let geometry: NotchGeometry

    private var settings: SettingsStore { .shared }

    private var tint: Color {
        switch kind {
        case .charging: .green
        case .low: .red
        case .lowPower: .yellow
        }
    }

    private var symbol: String {
        switch kind {
        case .charging: "bolt.fill"
        case .low: "battery.25percent"
        case .lowPower: "battery.75percent"
        }
    }

    private var label: String {
        switch kind {
        case .charging: "Charging"
        case .low: "Low Battery"
        case .lowPower(let on): on ? "Low Power On" : "Low Power Off"
        }
    }

    var body: some View {
        PopWings(geometry: geometry) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, options: .nonRepeating)
                if !settings.batteryHideLabel {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint.opacity(0.9))
                        .lineLimit(1)
                }
            }
        } right: {
            if !settings.batteryHidePercentage {
                Text("\(percentage)%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
    }
}

/// Focus mode change pop: mode glyph + name left, on/off state right.
struct FocusPopView: View {
    let name: String
    let symbol: String
    let on: Bool
    let geometry: NotchGeometry

    private var tint: Color { on ? .indigo : .white.opacity(0.6) }

    var body: some View {
        PopWings(geometry: geometry) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Color.indigo : .white.opacity(0.6))
                    .symbolEffect(.bounce, options: .nonRepeating)
                if !SettingsStore.shared.focusHideLabel {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
        } right: {
            Text(on ? "On" : "Off")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

/// Calendar Quick Peek pop: event title left, countdown right.
struct EventPopView: View {
    let title: String
    let color: Color
    let startingNow: Bool
    let start: Date
    let geometry: NotchGeometry

    private var indicator: Color {
        SettingsStore.shared.calendarColoredIndicator ? color : .white.opacity(0.7)
    }

    var body: some View {
        PopWings(geometry: geometry) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(indicator)
                    .frame(width: 3, height: 14)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        } right: {
            if startingNow {
                Text("Now")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(indicator)
            } else {
                Text(start, style: .relative)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }
}

/// Agent status pop: agent glyph + project name left, state right.
struct AgentPopView: View {
    let name: String
    let kind: String
    let needsInput: Bool
    let geometry: NotchGeometry

    private var symbol: String {
        switch kind {
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "sparkle"
        default: "terminal.fill"
        }
    }

    var body: some View {
        PopWings(geometry: geometry) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(needsInput ? Color.orange : .green)
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        } right: {
            Text(needsInput ? "Needs input" : "Done")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(needsInput ? Color.orange : .green)
        }
    }
}

/// Compact confirmation pill shown briefly after Approve/Reject (reference 2).
struct AgentConfirmView: View {
    let approved: Bool
    let geometry: NotchGeometry

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: approved ? "checkmark" : "xmark")
                .font(.system(size: 12, weight: .bold))
                .symbolEffect(.bounce, options: .nonRepeating)
            Text(approved ? "Approved" : "Rejected")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(
            approved
                ? Color(red: 0.40, green: 0.90, blue: 0.50)
                : Color(red: 0.95, green: 0.45, blue: 0.45)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, geometry.notchHeight - 4)
    }
}

/// Bluetooth device connect pop: device glyph + name left, battery ring right.
struct DevicePopView: View {
    let name: String
    let symbol: String
    let battery: Int?
    let geometry: NotchGeometry

    @State private var ringProgress: Double = 0

    var body: some View {
        PopWings(geometry: geometry) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        } right: {
            HStack(spacing: 6) {
                if let battery {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: ringProgress)
                            .stroke(
                                batteryColor(battery),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)
                    Text("\(battery)%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.15)) {
                ringProgress = Double(battery ?? 0) / 100
            }
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        switch level {
        case ..<20: .red
        case ..<40: .yellow
        default: .green
        }
    }
}
