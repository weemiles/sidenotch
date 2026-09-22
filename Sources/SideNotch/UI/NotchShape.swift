import SwiftUI

/// The rail silhouette: flush against the left screen edge, rounded on the right,
/// and joined to the edge by two *concave* fillets at top and bottom — the same
/// inverted corner the macOS notch uses, which is what sells it as part of the bezel
/// instead of a floating panel.
///
/// The rect it is given includes the fillets, so the body occupies
/// `rect.insetBy(dy: flare)`.
struct LeftNotchShape: Shape {
    var cornerRadius: CGFloat = Metrics.railCorner
    var flare: CGFloat = Metrics.flare

    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.height / 4)
        let bodyTop = rect.minY + f
        let bodyBottom = rect.maxY - f
        let r = min(cornerRadius, min(rect.width, (bodyBottom - bodyTop) / 2))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Flare in from the edge.
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: bodyTop),
                       control: CGPoint(x: rect.minX, y: bodyTop))

        p.addLine(to: CGPoint(x: rect.maxX - r, y: bodyTop))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: bodyTop + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)

        p.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: bodyBottom - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)

        p.addLine(to: CGPoint(x: rect.minX + f, y: bodyBottom))

        // Flare back out to the edge.
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: bodyBottom))

        p.closeSubpath()
        return p
    }
}


/// The sideways bulge. Its left slice hides under the rail, so that edge is
/// square — a radius there would curve away from the rail instead of meeting it.
///
/// `bottomFillet` puts a concave curve where the bulge rejoins the rail, the
/// same inverted corner the rail uses against the screen edge. It is only wanted
/// when the rail carries on below the bulge; when both end together the bottom
/// is a plain rounded corner instead.
struct BulgeShape: Shape {
    /// Width of the slice that sits behind the rail.
    var inset: CGFloat
    var corner: CGFloat
    var bottomFillet: CGFloat

    func path(in rect: CGRect) -> Path {
        let ins = min(inset, rect.width)
        let fillet = min(bottomFillet, rect.height / 3)
        let bodyBottom = rect.maxY - fillet
        let r = min(corner, max(0, rect.width - ins) / 2, (bodyBottom - rect.minY) / 2)

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: max(rect.minX, rect.maxX - r), y: rect.minY))

        if r > 0 {
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: bodyBottom - r), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom))
        }

        if fillet > 0 {
            p.addLine(to: CGPoint(x: rect.minX + ins + fillet, y: bodyBottom))
            p.addQuadCurve(to: CGPoint(x: rect.minX + ins, y: rect.maxY),
                           control: CGPoint(x: rect.minX + ins, y: bodyBottom))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.addLine(to: CGPoint(x: rect.minX, y: bodyBottom))
        }

        p.closeSubpath()
        return p
    }
}
