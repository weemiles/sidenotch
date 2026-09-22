import SwiftUI

/// Minimal SVG path-data parser — enough to render brand marks shipped as a
/// single `d` string. Supports M/L/H/V/C/S/Q/T/A/Z in both absolute and relative
/// form, which covers everything the embedded logos use.
enum SVGPath {

    private static var cache: [String: Path] = [:]
    private static let lock = NSLock()

    static func path(_ data: String) -> Path {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[data] { return hit }
        let built = build(data)
        cache[data] = built
        return built
    }

    // MARK: Scanner

    private struct Scanner {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n"
                    || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard i < chars.count, chars[i].isLetter else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        var peekIsNumber: Bool {
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "," || chars[j] == "\n"
                    || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
            guard j < chars.count else { return false }
            return chars[j].isNumber || chars[j] == "-" || chars[j] == "+" || chars[j] == "."
        }

        mutating func number() -> CGFloat {
            skipSeparators()
            var s = ""
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            var sawDot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { s.append(c); i += 1 }
                else if c == ".", !sawDot { sawDot = true; s.append(c); i += 1 }
                else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                } else { break }
            }
            return CGFloat(Double(s) ?? 0)
        }

        /// Arc flags are single digits and may be packed without separators.
        mutating func flag() -> Bool {
            skipSeparators()
            guard i < chars.count else { return false }
            defer { i += 1 }
            return chars[i] == "1"
        }
    }

    // MARK: Builder

    private static func build(_ data: String) -> Path {
        var path = Path()
        var scanner = Scanner(data)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character = "M"

        while true {
            if let c = scanner.nextCommand() {
                command = c
            } else if !scanner.peekIsNumber {
                break
            } else if command == "M" {
                command = "L"          // repeated pairs after moveto are linetos
            } else if command == "m" {
                command = "l"
            }

            let relative = command.isLowercase
            func abs(_ p: CGPoint) -> CGPoint {
                relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
            }

            switch command.uppercased().first! {
            case "M":
                let p = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                path.move(to: p); current = p; subpathStart = p
                lastControl = nil; lastQuadControl = nil

            case "L":
                let p = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                path.addLine(to: p); current = p
                lastControl = nil; lastQuadControl = nil

            case "H":
                let x = scanner.number()
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: p); current = p
                lastControl = nil; lastQuadControl = nil

            case "V":
                let y = scanner.number()
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: p); current = p
                lastControl = nil; lastQuadControl = nil

            case "C":
                let c1 = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                let c2 = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                let p  = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2; lastQuadControl = nil

            case "S":
                let c1 = reflect(lastControl, around: current)
                let c2 = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                let p  = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2; lastQuadControl = nil

            case "Q":
                let c = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                let p = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                path.addQuadCurve(to: p, control: c)
                current = p; lastQuadControl = c; lastControl = nil

            case "T":
                let c = reflect(lastQuadControl, around: current)
                let p = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                path.addQuadCurve(to: p, control: c)
                current = p; lastQuadControl = c; lastControl = nil

            case "A":
                let rx = scanner.number(), ry = scanner.number()
                let rotation = scanner.number()
                let largeArc = scanner.flag(), sweep = scanner.flag()
                let p = abs(CGPoint(x: scanner.number(), y: scanner.number()))
                addArc(&path, from: current, to: p, rx: rx, ry: ry,
                       rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = p; lastControl = nil; lastQuadControl = nil

            case "Z":
                path.closeSubpath(); current = subpathStart
                lastControl = nil; lastQuadControl = nil

            default:
                break
            }

            if scanner.i >= scanner.chars.count && !scanner.peekIsNumber { break }
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// SVG endpoint-parameterised arc → centre parameterisation, drawn as a unit
    /// circle under a transform so unequal radii and x-axis rotation both work.
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx: CGFloat, ry: CGFloat, rotationDegrees: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        var rx = Swift.abs(rx), ry = Swift.abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else {
            path.addLine(to: p1); return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1 =  cosPhi * dx2 + sinPhi * dy2
        let y1 = -sinPhi * dx2 + cosPhi * dy2

        // Scale radii up if they are too small to span the endpoints.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda); rx *= s; ry *= s
        }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let numerator = max(0, rx*rx*ry*ry - rx*rx*y1*y1 - ry*ry*x1*x1)
        let denominator = rx*rx*y1*y1 + ry*ry*x1*x1
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)

        let cx1 =  coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat) -> CGFloat { atan2(uy, ux) }
        let theta1 = angle((x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta  = angle((-x1 - cx1) / rx, (-y1 - cy1) / ry) - theta1
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let transform = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: phi)
            .scaledBy(x: rx, y: ry)
        path.addArc(center: .zero, radius: 1,
                    startAngle: .radians(Double(theta1)),
                    endAngle: .radians(Double(theta1 + delta)),
                    clockwise: !sweep,
                    transform: transform)
    }
}

/// Renders a 24×24 SVG path, aspect-fit and centred in the given rect.
struct SVGShape: Shape {
    let data: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        let size = viewBox * scale
        let transform = CGAffineTransform(
            translationX: rect.midX - size / 2,
            y: rect.midY - size / 2
        ).scaledBy(x: scale, y: scale)
        return SVGPath.path(data).applying(transform)
    }
}
