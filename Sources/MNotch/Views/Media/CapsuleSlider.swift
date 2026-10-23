import SwiftUI

/// Alcove-style slider: a thin capsule that thickens on hover/drag.
/// Reports live values while scrubbing and commits on release.
struct CapsuleSlider: View {
    /// 0...1
    var value: Double
    var fill: Color = .white
    var onScrub: ((Double) -> Void)?
    var onCommit: (Double) -> Void

    @State private var hovering = false
    @State private var dragValue: Double?

    /// Clamped: sources without a duration report raw elapsed seconds as the
    /// fraction, which would render a fill hundreds of times the track width.
    private var displayed: Double { SafeNumeric.unit(dragValue ?? value) }
    private var thick: Bool { hovering || dragValue != nil }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                Capsule()
                    .fill(fill)
                    .frame(width: max(geo.size.height, geo.size.width * displayed))
            }
            .frame(height: thick ? geo.size.height : geo.size.height * 0.6)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle().inset(by: -10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard geo.size.width.isFinite, geo.size.width > 0 else { return }
                        let next = SafeNumeric.unit(gesture.location.x / geo.size.width)
                        dragValue = next
                        onScrub?(next)
                    }
                    .onEnded { gesture in
                        guard geo.size.width.isFinite, geo.size.width > 0 else { dragValue = nil; return }
                        let final = SafeNumeric.unit(gesture.location.x / geo.size.width)
                        dragValue = nil
                        onCommit(final)
                    }
            )
        }
        .onHover { hovering = $0 }
        .animation(Anim.hud, value: thick)
    }
}
