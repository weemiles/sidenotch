import SwiftUI

enum Theme {
    /// One accent only. Everything else is neutral; emphasis comes from
    /// type weight and spacing rather than from more colour.
    static let accent = Color(red: 0x56 / 255, green: 0xE8 / 255, blue: 0x93 / 255)
    static let warn   = Color(red: 0xE8 / 255, green: 0x92 / 255, blue: 0x4A / 255)
    static let danger = Color(red: 0xE8 / 255, green: 0x68 / 255, blue: 0x5A / 255)

    static let shell          = Color.black
    static let textPrimary    = Color.white.opacity(0.95)
    static let textSecondary  = Color.white.opacity(0.48)
    static let textTertiary   = Color.white.opacity(0.30)
    static let track          = Color.white.opacity(0.10)
    static let hairline       = Color.white.opacity(0.12)

    /// Brand marks keep their own colour — that is what makes them readable at
    /// 34pt. The status colour lives in the ring around them, not in the mark.
    static let claudeMark = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let openaiMark = Color.white.opacity(0.92)

    /// Reads like a battery: plenty left is green, nearly gone is red.
    /// `remaining` is the fraction still available, not the fraction used.
    static func tint(remaining: Double) -> Color {
        if remaining <= 0.10 { return danger }
        if remaining <= 0.30 { return warn }
        return accent
    }
}

enum Metrics {
    /// Size of the concave fillet where the rail meets the screen edge.
    /// This is what makes it read as a notch rather than a floating bar.
    static let flare: CGFloat = 12
    static let railWidth: CGFloat = 51
    static let railCorner: CGFloat = 18
    static let railPaddingV: CGFloat = 10
    static let rowHeight: CGFloat = 52
    static let iconDiameter: CGFloat = 30
    static let ringWidth: CGFloat = 2.4

    static let detailWidth: CGFloat = 248
    static let detailPadding: CGFloat = 13
    static let detailCorner: CGFloat = 18
    /// The bulge starts under the rail so the two solid-black shapes merge.
    /// It has to reach past the rail's corner radius, otherwise the rail's
    /// top-right curve and the bulge's top-left curve bend opposite ways and
    /// leave a dent at the join.
    static let panelOverlap: CGFloat = railCorner + 2

    /// The island is one fixed box that only ever changes width. Letting the
    /// height follow the contents made it jump between widgets, which broke the
    /// illusion that it is a single physical thing.
    ///
    /// It is exactly as tall as the logo column, so expanding is purely
    /// horizontal. Every widget's detail has to be written to fit this.
    static func contentHeight(gauges: Int, shortcuts: Int) -> CGFloat {
        max(railHeight(gauges: gauges, shortcuts: shortcuts), 124)
    }

    /// Widest the single shape ever gets — the window is sized from this.
    static var expandedWidth: CGFloat { railWidth + detailWidth + detailPadding }

    /// Width the bulge grows to: the slice hidden behind the rail, plus the
    /// visible content and its trailing gutter.
    static var bulgeWidth: CGFloat { panelOverlap + detailWidth + detailPadding }

    /// Concave curve where the bulge rejoins the rail below it.
    static let bulgeFillet: CGFloat = 11

    /// Height of just the gauge rows. The sideways bulge is sized to this, so it
    /// stays beside Claude and Codex instead of stretching down past the
    /// shortcuts the way a full-height expansion did.
    static func gaugeBlockHeight(gauges: Int) -> CGFloat {
        railPaddingV * 2 + CGFloat(max(gauges, 1)) * rowHeight
    }

    /// Size of the rail across the edge it is docked to (its thickness).
    static var railThickness: CGFloat { railWidth }

    /// Full silhouette length along the edge, flares included.
    static func islandLength(gauges: Int, shortcuts: Int) -> CGFloat {
        contentHeight(gauges: gauges, shortcuts: shortcuts) + flare * 2
    }

    // MARK: Bulge sizing
    //
    // Text always reads horizontally, so the detail block is the same 248 × gauge
    // block whichever edge the notch is on. What changes is which of those two
    // numbers points away from the edge.

    /// Size of the detail block perpendicular to the edge.
    static func detailAcross(edge: NotchEdge, gauges: Int) -> CGFloat {
        edge.isVertical ? detailWidth : gaugeBlockHeight(gauges: gauges)
    }

    /// Size of the detail block along the edge.
    static func detailAlong(edge: NotchEdge, gauges: Int) -> CGFloat {
        edge.isVertical ? gaugeBlockHeight(gauges: gauges) : detailWidth
    }

    /// How far the bulge reaches away from the edge when open.
    static func bulgeDepth(edge: NotchEdge, gauges: Int) -> CGFloat {
        panelOverlap + detailAcross(edge: edge, gauges: gauges) + detailPadding
    }

    /// How long the rail's own shape runs. When the detail is longer than the
    /// rail — which is always the case on the top edge, where text is wide but
    /// two gauges are narrow — the rail grows to match so the two shapes end
    /// together instead of leaving a step at the rail's far end.
    static func railShapeLength(edge: NotchEdge, gauges: Int, shortcuts: Int,
                                open: Bool) -> CGFloat {
        let rail = contentHeight(gauges: gauges, shortcuts: shortcuts)
        guard open else { return rail }
        return max(rail, detailAlong(edge: edge, gauges: gauges))
    }

    /// A concave join is only wanted where the rail genuinely carries on past
    /// the bulge. Where they finish together it would carve into nothing.
    static func needsFillet(edge: NotchEdge, gauges: Int, shortcuts: Int) -> Bool {
        contentHeight(gauges: gauges, shortcuts: shortcuts)
            > detailAlong(edge: edge, gauges: gauges)
    }

    /// On the top edge the detail lives *inside* the shape, below the gauge row,
    /// so the whole black body grows right and down together instead of a second
    /// piece emerging from under it.
    static func topShellSize(gauges: Int, shortcuts: Int, open: Bool) -> CGSize {
        let railLength = contentHeight(gauges: gauges, shortcuts: shortcuts)
        guard open else {
            return CGSize(width: railLength, height: railThickness)
        }
        return CGSize(
            width: max(railLength, detailWidth + detailPadding * 2),
            height: railThickness + gaugeBlockHeight(gauges: gauges) + detailPadding
        )
    }

    /// Everything at its largest, so the window can be sized once.
    static func islandSize(edge: NotchEdge, gauges: Int, shortcuts: Int) -> CGSize {
        if edge == .top {
            let shell = topShellSize(gauges: gauges, shortcuts: shortcuts, open: true)
            return CGSize(width: shell.width + flare * 2, height: shell.height)
        }
        let across = railThickness + detailAcross(edge: edge, gauges: gauges) + detailPadding
        let along = max(contentHeight(gauges: gauges, shortcuts: shortcuts),
                        detailAlong(edge: edge, gauges: gauges) + bulgeFillet) + flare * 2
        return CGSize(width: across, height: along)
    }

    /// Slack around the content so shadows and the expand overshoot are not clipped.
    static let windowMargin: CGFloat = 32

    /// Shortcut rows carry no percentage caption, so they are shorter.
    static let shortcutRow: CGFloat = 42
    /// Spacing plus hairline between the gauges and the shortcuts below them.
    static let dividerBlock: CGFloat = 13

    static func railHeight(gauges: Int, shortcuts: Int) -> CGFloat {
        var h = railPaddingV * 2 + CGFloat(max(gauges, 1)) * rowHeight
        if shortcuts > 0 { h += dividerBlock + CGFloat(shortcuts) * shortcutRow }
        return h
    }
}

/// Timings lifted from the transitions.dev "gooey plus menu" spec: the panel
/// overshoots on the way out and returns without overshoot, faster, on the way
/// back — asymmetry is what stops it reading as a mechanical toggle.
enum Motion {
    static let open  = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.46)
    static let close = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.33)

    /// Per-row delay inside the panel, and the fade each row arrives with.
    static let stagger: Double = 0.052
    static let rowLead: Double = 0.155
    static let rowIn  = Animation.easeOut(duration: 0.235)
    static let rowOut = Animation.easeOut(duration: 0.155)

    /// Low damping on purpose: icons landing in the rail should wobble into
    /// place, the way the gooey menu's actions settle after they fan out.
    static let gooey = Animation.spring(response: 0.50, dampingFraction: 0.58)
    /// Even looser for the rail stretching as it takes on another row.
    static let stretch = Animation.spring(response: 0.42, dampingFraction: 0.66)

    /// Gliding to a snapped edge. Long and heavily eased-out so it reads as
    /// settling rather than jumping.
    static let snapDuration: Double = 0.62
    static let snap = Animation.timingCurve(0.22, 1, 0.36, 1, duration: snapDuration)

    static let value = Animation.easeOut(duration: 0.45)

    static func panel(active: Bool) -> Animation { active ? open : close }
}
