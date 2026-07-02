import SwiftUI

/// Sliver HUD in the notch: SF Symbol on the left wing, capsule progress on
/// the right wing, hardware cutout untouched in between.
struct HUDView: View {
    let kind: HUDKind
    let value: Double
    let muted: Bool
    let geometry: NotchGeometry

    private var symbol: String {
        switch kind {
        case .volume:
            if muted || value <= 0 { return "speaker.slash.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return "sun.max.fill"
        case .keyboardBacklight:
            return "keyboard"
        }
    }

    var body: some View {
        HStack {
            Image(systemName: symbol, variableValue: value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, alignment: .leading)
                .contentTransition(.symbolEffect(.replace))

            Spacer(minLength: geometry.notchWidth)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule()
                        .fill(.white)
                        .frame(width: max(geo.size.height, geo.size.width * value))
                }
            }
            .frame(width: 60, height: 5)
            .animation(Anim.hud, value: value)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.top, 2)
    }
}
