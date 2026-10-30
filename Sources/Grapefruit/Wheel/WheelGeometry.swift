import CoreGraphics
import Foundation

/// Wheel sizes in points.
/// Everything is drawn at these sizes, then the whole wheel is shown at `scale`.
struct WheelMetrics {
    var inner: CGFloat = 58          // segment inner radius
    var outer: CGFloat = 146         // segment outer radius
    var gap: CGFloat = 6             // clear space between glass petals
    var corner: CGFloat = 24         // outer corner rounding
    var pith: CGFloat = 152          // glass plate under the petals, its rim is the wheel's edge
    var hub: CGFloat = 49            // core that names the wheel and the lit segment
    var labelRadius: CGFloat = 105
    /// How far a segment pops out on drop.
    var pop: CGFloat = 16
    /// Where a drag counts as over a segment (the core is a dead zone).
    var hitInner: CGFloat = 46
    var hitOuter: CGFloat = 178
    var shadowMargin: CGFloat = 34
    /// The whole wheel is shown at 90% of the sizes above.
    var scale: CGFloat = 0.9

    /// Outer edge of the wheel, before `scale`.
    var radius: CGFloat { pith }
    var canvas: CGFloat { (max(radius, hitOuter) + shadowMargin) * 2 }

    static let standard = WheelMetrics()
}

enum WheelGeometry {
    /// Center angle of petal `i` of `n` (radians, 0 = east, counter-clockwise).
    /// Petal 0 sits at 12 o'clock and the rest follow clockwise; three petals start at 9.
    static func angle(_ i: Int, _ n: Int) -> CGFloat {
        (n == 3 ? .pi : .pi / 2) - 2 * .pi * CGFloat(i) / CGFloat(n)
    }

    /// Point at radius `r` and angle `a` around `c`, in a y-down space.
    static func point(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint {
        CGPoint(x: c.x + cos(a) * r, y: c.y - sin(a) * r)
    }

    /// Petal outline: an annular sector with rounded outer corners and a soft inner edge.
    static func petalPath(index i: Int, count n: Int, center c: CGPoint, metrics m: WheelMetrics) -> CGPath {
        let inner = m.inner
        let outer = m.outer
        let gap = m.gap
        let a = angle(i, n)
        let span = 2 * .pi / CGFloat(n)
        let l = a - span / 2
        let s = a + span / 2
        func half(_ r: CGFloat) -> CGFloat { asin(min(0.95, gap / 2 / max(r, gap / 2 + 0.01))) }
        let d = l + half(outer)
        let e = s - half(outer)
        let ci = l + half(inner)
        let g = s - half(inner)
        let f = min(0.15, (e - d) * 0.24)
        let u = min(0.18, (g - ci) * 0.18)
        let v = inner / max(0.01, cos(u))
        let y = v + inner * tan(u)
        let o = outer - m.corner
        func p(_ r: CGFloat, _ ang: CGFloat) -> CGPoint { point(c, r, ang) }

        let path = CGMutablePath()
        path.move(to: p(y, l + half(y)))
        path.addLine(to: p(o, l + half(o)))
        path.addQuadCurve(to: p(outer, d + f), control: p(outer, d))
        addArc(path, c, outer, from: d + f, to: e - f)
        path.addQuadCurve(to: p(o, s - half(o)), control: p(outer, e))
        path.addLine(to: p(y, s - half(y)))
        path.addQuadCurve(to: p(inner, g - u), control: p(v, s - half(v)))
        addArc(path, c, inner, from: g - u, to: ci + u)
        path.addQuadCurve(to: p(y, l + half(y)), control: p(v, l + half(v)))
        path.closeSubpath()
        return path
    }

    /// Circular arc as cubic Béziers, in either direction.
    static func addArc(_ path: CGMutablePath, _ c: CGPoint, _ r: CGFloat, from a0: CGFloat, to a1: CGFloat) {
        let total = a1 - a0
        let segments = max(1, Int(ceil(abs(total) / (.pi / 4))))
        let step = total / CGFloat(segments)
        var start = a0
        for _ in 0..<segments {
            let end = start + step
            let k = 4.0 / 3.0 * tan(step / 4)
            let p0 = point(c, r, start)
            let p3 = point(c, r, end)
            let c1 = CGPoint(x: p0.x - k * r * sin(start), y: p0.y - k * r * cos(start))
            let c2 = CGPoint(x: p3.x + k * r * sin(end), y: p3.y + k * r * cos(end))
            path.addCurve(to: p3, control1: c1, control2: c2)
            start = end
        }
    }

    /// Petal under a point given as an offset from the center (y-down), or nil.
    /// Crossing the thin gap between petals keeps the nearest one lit, so the
    /// highlight never blinks off mid-move.
    static func petal(at v: CGPoint, count n: Int, metrics m: WheelMetrics) -> Int? {
        guard n > 0 else { return nil }
        let dist = hypot(v.x, v.y)
        guard dist >= m.hitInner, dist <= m.hitOuter else { return nil }
        let ang = atan2(-v.y, v.x)
        let span = 2 * .pi / CGFloat(n)
        var rel = (angle(0, n) - ang).truncatingRemainder(dividingBy: 2 * .pi)
        if rel < 0 { rel += 2 * .pi }
        return Int((rel / span).rounded()) % n
    }

    /// Where a petal's label sits.
    static func labelPoint(index i: Int, count n: Int, center c: CGPoint, metrics m: WheelMetrics) -> CGPoint {
        point(c, m.labelRadius, angle(i, n))
    }

    /// Middle of a petal, used to center its shading.
    static func petalCentroid(index i: Int, count n: Int, center c: CGPoint, metrics m: WheelMetrics) -> CGPoint {
        point(c, (m.inner + m.outer) / 2, angle(i, n))
    }

    /// Offset that slides petal `i` outward by `distance` (y-down, for SwiftUI).
    static func outward(index i: Int, count n: Int, by distance: CGFloat) -> CGSize {
        let a = angle(i, n)
        return CGSize(width: cos(a) * distance, height: -sin(a) * distance)
    }
}
