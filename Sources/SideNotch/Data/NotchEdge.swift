import SwiftUI

/// Which screen edge the notch is docked to. The bottom is deliberately absent:
/// it collides with the Dock on most setups.
enum NotchEdge: String, Codable, CaseIterable {
    case left, top, right

    /// True when the rail runs up and down and the bulge opens sideways.
    var isVertical: Bool { self != .top }

    /// Direction the bulge grows, away from the screen edge.
    var opensTowardTrailing: Bool { self != .right }

    /// Where the gauges stack.
    var railAxis: Axis { isVertical ? .vertical : .horizontal }

    /// Distance from a point to this edge of `frame`, used for snapping.
    func distance(from point: CGPoint, in frame: CGRect) -> CGFloat {
        switch self {
        case .left:  return point.x - frame.minX
        case .right: return frame.maxX - point.x
        case .top:   return frame.maxY - point.y      // AppKit y grows upward
        }
    }

    static func nearest(to point: CGPoint, in frame: CGRect) -> NotchEdge {
        allCases.min { $0.distance(from: point, in: frame) < $1.distance(from: point, in: frame) } ?? .left
    }
}
