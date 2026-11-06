import SwiftUI

/// The island outline: flat top that blends into the screen edge, small
/// inward "ears" at the top corners (like the hardware notch) and rounded
/// bottom corners. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let tr = min(topRadius, w / 4), br = min(bottomRadius, h / 2, w / 4)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY + h - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.minY + h),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - tr - br, y: rect.minY + h))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w - tr, y: rect.minY + h - br),
                       control: CGPoint(x: rect.minX + w - tr, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w, y: rect.minY),
                       control: CGPoint(x: rect.minX + w - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
