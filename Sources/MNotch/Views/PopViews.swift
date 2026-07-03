import SwiftUI

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
        HStack {
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

            Spacer(minLength: geometry.notchWidth)

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
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.top, 2)
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
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text(shortName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)

            Spacer(minLength: geometry.notchWidth)

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
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.top, 2)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.15)) {
                ringProgress = Double(battery ?? 0) / 100
            }
        }
    }

    private var shortName: String {
        name.count > 14 ? String(name.prefix(13)) + "…" : name
    }

    private func batteryColor(_ level: Int) -> Color {
        switch level {
        case ..<20: .red
        case ..<40: .yellow
        default: .green
        }
    }
}
