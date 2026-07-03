import SwiftUI

/// Sliver HUD in the notch: SF Symbol on the left wing, capsule progress on
/// the right wing, hardware cutout untouched in between. Bar style, label,
/// percentage and icon flavor follow Settings → Display/Sound.
struct HUDView: View {
    let kind: HUDKind
    let value: Double
    let muted: Bool
    let geometry: NotchGeometry

    private var settings: SettingsStore { .shared }
    private var isVolume: Bool { kind == .volume }
    private var barStyle: HUDBarStyle {
        isVolume ? settings.soundBarStyle : settings.displayBarStyle
    }
    private var hideLabel: Bool {
        isVolume ? settings.soundHideLabel : settings.displayHideLabel
    }
    private var showPercentage: Bool {
        isVolume ? settings.soundShowPercentage : settings.displayShowPercentage
    }

    private var symbol: String {
        switch kind {
        case .volume:
            if muted || value <= 0 { return "speaker.slash.fill" }
            if settings.soundIconStyle == .device {
                return AppServices.shared.audio.outputSymbol
            }
            return "speaker.wave.3.fill"
        case .brightness:
            return "sun.max.fill"
        case .keyboardBacklight:
            return "keyboard"
        }
    }

    private var fill: AnyShapeStyle {
        switch barStyle {
        case .white:
            AnyShapeStyle(.white)
        case .accent:
            AnyShapeStyle(
                AppServices.shared.media.hasActiveMedia
                    ? AppServices.shared.media.accentColor
                    : Color(nsColor: .controlAccentColor)
            )
        case .decibel:
            AnyShapeStyle(
                LinearGradient(
                    colors: [.green, .yellow, .orange],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }

    var body: some View {
        HStack {
            if !hideLabel {
                Image(systemName: symbol, variableValue: value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, alignment: .leading)
                    .contentTransition(.symbolEffect(.replace))
            }

            Spacer(minLength: geometry.notchWidth)

            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule()
                            .fill(fill)
                            .frame(width: max(geo.size.height, geo.size.width * value))
                    }
                }
                .frame(width: showPercentage ? 46 : 60, height: 5)
                if showPercentage {
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .contentTransition(.numericText())
                }
            }
            .animation(Anim.hud, value: value)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.top, 2)
    }
}
