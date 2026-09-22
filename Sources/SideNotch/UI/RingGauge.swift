import SwiftUI

/// Battery-style arc around a logo: full when there is plenty left, shrinking
/// back toward the start as the allowance is used up. Open at the bottom so the
/// glyph inside still reads at 34pt.
struct ArcGauge: View {
    /// Fraction **remaining**, 0...1.
    var remaining: Double
    var color: Color
    var lineWidth: CGFloat = 2.5

    /// 260° of sweep beginning at the lower left, leaving a 100° gap at the base.
    private let sweep: Double = 260
    private let startAngle: Double = 140

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep / 360)
                .stroke(Theme.track, style: stroke)
            Circle()
                .trim(from: 0, to: sweep / 360 * clamped)
                .stroke(color, style: stroke)
                .animation(Motion.value, value: clamped)
        }
        .rotationEffect(.degrees(startAngle))
    }

    private var clamped: Double { max(0, min(1, remaining)) }
    private var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .round) }
}

/// Flat horizontal meter used inside the panel. Also fills by what is left.
struct Meter: View {
    var remaining: Double
    var color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geo.size.width * min(1, max(0, remaining))))
                    .animation(Motion.value, value: remaining)
            }
        }
        .frame(height: height)
    }
}
