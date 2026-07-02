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

    private var displayed: Double { dragValue ?? value }
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
                        let next = min(max(gesture.location.x / geo.size.width, 0), 1)
                        dragValue = next
                        onScrub?(next)
                    }
                    .onEnded { gesture in
                        let final = min(max(gesture.location.x / geo.size.width, 0), 1)
                        dragValue = nil
                        onCommit(final)
                    }
            )
        }
        .onHover { hovering = $0 }
        .animation(Anim.hud, value: thick)
    }
}
