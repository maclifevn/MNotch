import SwiftUI

/// The notch outline: top corners flare outward (concave curves tangent to the
/// menu bar's top edge), bottom corners are convex rounded. Both radii animate,
/// which is what makes the open/close morph feel liquid rather than mechanical.
///
/// The rect passed in INCLUDES the top flares: the straight vertical sides sit
/// `topRadius` inside each horizontal edge of the rect.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        notchPath(in: rect, closesTopEdge: true)
    }

    fileprivate func notchPath(in rect: CGRect, closesTopEdge: Bool) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // top-left flare, curving inward and down
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        // left side down
        p.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        // bottom-left rounded corner
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        // bottom edge
        p.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        // bottom-right rounded corner
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        // right side up
        p.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        // top-right flare
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        // The fill/clip shape must close across the top. The visible outline
        // deliberately stays open there: stroking a closed path draws a bright
        // one-pixel seam directly under the menu bar/camera cutout.
        if closesTopEdge {
            p.closeSubpath()
        }
        return p
    }
}

/// Same geometry as ``NotchShape`` but without the invisible top closure.
/// Used only for the optional contrast border so no white seam is painted
/// across the top edge of either a physical or simulated notch.
struct NotchOutlineShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
            .notchPath(in: rect, closesTopEdge: false)
    }
}
