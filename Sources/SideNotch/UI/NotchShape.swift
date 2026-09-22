import SwiftUI

/// The rail silhouette: flush against its screen edge, rounded on the inner
/// side, and joined to the edge by two *concave* fillets — the same inverted
/// corner the macOS notch uses, which is what sells it as part of the bezel
/// instead of a floating panel.
///
/// Only the left-edge form is written out. The other edges are the same path
/// under a transform, which keeps one description of the silhouette instead of
/// three that can drift apart.
struct NotchShape: Shape {
    var edge: NotchEdge
    var cornerRadius: CGFloat = Metrics.railCorner
    var flare: CGFloat = Metrics.flare

    func path(in rect: CGRect) -> Path {
        EdgeTransform.path(for: edge, in: rect) { canonical in
            leftPath(in: canonical)
        }
    }

    private func leftPath(in rect: CGRect) -> Path {
        let f = min(flare, rect.height / 4)
        let bodyTop = rect.minY + f
        let bodyBottom = rect.maxY - f
        let r = min(cornerRadius, rect.width, (bodyBottom - bodyTop) / 2)

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

/// The part that grows away from the edge. Its near side hides under the rail,
/// so that side is square — a radius there would curve away from the rail
/// instead of meeting it.
///
/// `farFillet` puts a concave curve where the bulge rejoins the rail further
/// along the edge, the same inverted corner the rail uses against the screen.
/// It is only wanted when the rail carries on past the bulge; when both end
/// together the corner is a plain rounded one.
struct BulgeShape: Shape {
    var edge: NotchEdge
    /// Depth of the slice that sits behind the rail.
    var inset: CGFloat
    var corner: CGFloat
    var farFillet: CGFloat

    func path(in rect: CGRect) -> Path {
        EdgeTransform.path(for: edge, in: rect) { canonical in
            leftPath(in: canonical)
        }
    }

    private func leftPath(in rect: CGRect) -> Path {
        let ins = min(inset, rect.width)
        let fillet = min(farFillet, rect.height / 3)
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

/// Maps a shape written for the left edge onto whichever edge is in use.
///
/// `right` mirrors across the vertical centre. `top` transposes, which swaps the
/// axes so the flush side lands on y = 0 and the body grows downward; the
/// canonical rect is built with its width and height swapped to match.
enum EdgeTransform {
    static func path(for edge: NotchEdge, in rect: CGRect,
                     canonical: (CGRect) -> Path) -> Path {
        switch edge {
        case .left:
            return canonical(CGRect(origin: .zero, size: rect.size))
                .applying(.init(translationX: rect.minX, y: rect.minY))
        case .right:
            let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0)
            return canonical(CGRect(origin: .zero, size: rect.size))
                .applying(mirror)
                .applying(.init(translationX: rect.minX, y: rect.minY))
        case .top:
            let swapped = CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
            let transpose = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
            return canonical(swapped)
                .applying(transpose)
                .applying(.init(translationX: rect.minX, y: rect.minY))
        }
    }
}
