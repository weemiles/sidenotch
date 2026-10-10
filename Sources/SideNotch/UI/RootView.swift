import SwiftUI

struct WidgetSpec: Identifiable {
    let id: String
    let logo: String
    let markColor: Color
    /// Fraction still available, 0...1 — everything is shown battery-style.
    let remaining: Double
    let caption: String
    let available: Bool
    /// "1", "2" … when a second account makes the logo ambiguous. Empty otherwise.
    var badge: String = ""
    /// SF Symbol drawn instead of `logo`, for things with no brand mark.
    var symbol: String? = nil
    /// Overrides the battery tint when the fill is not an allowance.
    var ringColor: Color? = nil
    /// Draw Grok Bot's face, whose eyes follow the pointer, instead of `logo`.
    var grokFace = false
    /// App a click opens, or brings forward if it is already running, in
    /// place of pinning the panel.
    var app: String? = nil
}

/// Reports interactive regions up to the hosting view so everything else stays
/// click-through. Coordinates are top-left origin, matching SwiftUI.
struct HitRectsKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

/// Height the open detail actually needs on the top edge.
struct DetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The rail's own frame, reported separately so the window knows where a
/// dropped file counts as landing on it.
struct DropRectKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    func reportHitRect(_ enabled: Bool = true) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: HitRectsKey.self,
                    value: enabled ? [geo.frame(in: .named("root"))] : []
                )
            }
        )
    }
}

/// One shape that grows, rather than a rail plus a panel that flies out.
/// The background and the clip come from the same `LeftNotchShape`, so the
/// silhouette itself is what animates and the detail is simply revealed inside
/// it — the Dynamic Island model.
struct RootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: PanelState
    var onHitRects: ([CGRect]) -> Void
    var onDropRect: (CGRect) -> Void

    private var specs: [WidgetSpec] {
        var out: [WidgetSpec] = []
        if store.config.showMemory {
            let m = store.memory
            // The one gauge that fills as it is used: RAM has no allowance to
            // run down, and "62%" reads as how full it is.
            out.append(WidgetSpec(
                id: "memory",
                logo: "",
                markColor: Theme.memoryMark,
                remaining: m.usedFraction,
                caption: m.available ? Fmt.percent(m.usedFraction) : "–",
                available: m.available,
                symbol: "memorychip",
                ringColor: Theme.tint(memory: m)
            ))
        }
        if store.config.showClaude {
            for account in store.claude {
                // The account's own figure wins. Failing that, without a
                // calibrated limit there is nothing honest to divide by, so the
                // rail shows a dash rather than a made-up percentage.
                let estimated = account.windowEnd != nil && account.budgetBasis != nil
                let left = account.quota?.headline?.remaining
                    ?? (estimated ? account.remaining : nil)
                out.append(WidgetSpec(
                    id: "claude:\(account.id)",
                    logo: BrandMark.claude,
                    markColor: Theme.claudeMark,
                    remaining: left ?? 1,
                    caption: left.map(Fmt.percent) ?? "–",
                    available: left != nil,
                    badge: account.label
                ))
            }
        }
        if store.config.showCodex {
            let p = store.codex.headline
            out.append(WidgetSpec(
                id: "codex",
                logo: BrandMark.openai,
                markColor: Theme.openaiMark,
                remaining: store.codex.remaining,
                caption: p.map { Fmt.percent($0.remaining) } ?? "–",
                available: p != nil,
                app: "/Applications/ChatGPT.app"
            ))
        }
        if store.config.showGrok {
            let g = store.grok
            out.append(WidgetSpec(
                id: "grok",
                logo: "",
                markColor: Theme.grokMark,
                remaining: g?.remaining ?? 1,
                caption: g.map { Fmt.percent($0.remaining) } ?? "–",
                available: g != nil,
                grokFace: true,
                app: "/Applications/Grok Bot.app"
            ))
        }
        if store.config.showCursor {
            let c = store.cursor
            out.append(WidgetSpec(
                id: "cursor",
                logo: BrandMark.cursor,
                markColor: Theme.cursorMark,
                remaining: c?.remaining ?? 1,
                caption: c.map { Fmt.percent($0.remaining) } ?? "–",
                available: c != nil,
                app: "/Applications/Cursor.app"
            ))
        }
        return out
    }

    private var isOpen: Bool { state.active != nil }
    private var shortcuts: [Shortcut] { store.config.shortcuts }
    private var displayedSpec: WidgetSpec? { specs.first { $0.id == state.displayed } }

    /// Shortcut rows plus the ghost slot shown while a file hovers over the rail.
    private var slotCount: Int { shortcuts.count + (state.dropTargeting ? 1 : 0) }

    /// A concave join only makes sense where the rail runs on past the bulge.
    private var bulgeFillet: CGFloat {
        Metrics.needsFillet(edge: edge, gauges: specs.count, shortcuts: slotCount)
            ? Metrics.bulgeFillet : 0
    }

    /// The rail's shape, which grows to meet the bulge when the bulge is longer.
    private var railShapeLength: CGFloat {
        Metrics.railShapeLength(edge: edge, gauges: specs.count,
                                shortcuts: slotCount, open: isOpen)
    }

    var body: some View {
        ZStack(alignment: rootAlignment) {
            Color.clear
            island
        }
        .coordinateSpace(name: "root")
        .animation(Motion.panel(active: isOpen), value: state.active)
        .animation(Motion.panel(active: isOpen), value: state.displayed)
        .animation(Motion.panel(active: state.revealed), value: state.revealed)
        .onPreferenceChange(HitRectsKey.self, perform: onHitRects)
        .onPreferenceChange(DropRectKey.self, perform: onDropRect)
    }

    private var edge: NotchEdge { store.config.edge }

    /// Pins the island to its edge inside the window. Without this it floats in
    /// the middle and only the left edge happens to look right.
    private var rootAlignment: Alignment {
        switch edge {
        case .left:  return .leading
        case .right: return .trailing
        case .top:   return .top
        }
    }

    /// Rail and bulge are two solid-black shapes, the bulge emerging from
    /// *under* the rail. Same colour, overlapping, so they read as one body —
    /// but the bulge only covers the gauge rows, so adding shortcuts lengthens
    /// the rail without lengthening what pops out.
    private var isTop: Bool { edge == .top }

    /// Hidden in the camera notch until the pointer reaches it.
    private var notchMode: Bool { store.config.notchMode && isTop }
    private var collapsed: Bool { notchMode && !state.revealed }
    /// Grown out of the notch, the icons sit below the camera housing, not behind it.
    private var notchInset: CGFloat { notchMode ? state.notchSize.height : 0 }

    private var island: some View {
        ZStack(alignment: islandAlignment) {
            // On the side edges the detail is a separate shape tucked under the
            // rail, so shortcuts can lengthen the rail without lengthening it.
            if !isTop { bulge }
            shell
        }
        .frame(width: islandSize.width, height: islandSize.height,
               alignment: islandAlignment)
        .animation(Motion.stretch, value: slotCount)
    }

    /// The black body. On the top edge it holds the detail too and simply grows
    /// right and down; on the sides it is just the rail.
    private var shell: some View {
        Group {
            if notchMode {
                notchBody
                    .opacity(collapsed ? 0 : 1)
                    .transformPreference(HitRectsKey.self) { if collapsed { $0 = [] } }
                    .transformPreference(DropRectKey.self) { if collapsed { $0 = .zero } }
            } else if isTop {
                VStack(alignment: .leading, spacing: 0) {
                    RailColumn(edge: edge, specs: specs, state: state, store: store)
                        .frame(width: railLength,
                               height: Metrics.railThickness(edge: edge),
                               alignment: .leading)
                        .padding(.top, notchInset)
                    if let spec = displayedSpec {
                        // Lined up with the first ring on the left and the last
                        // icon on the right, and only as tall as what it says.
                        WidgetBody(spec: spec, store: store)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: topDetailWidth, alignment: .topLeading)
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: DetailHeightKey.self,
                                                       value: geo.size.height)
                            })
                            .padding(.leading, topInsetLeading)
                            .padding(.top, Metrics.topDetailGap)
                            .opacity(isOpen ? 1 : 0)
                            .onHover(perform: holdOpen)
                    }
                }
                // Folded into the notch nothing inside may catch the mouse or a
                // dropped file: the shape is the size of the camera housing.
                .opacity(collapsed ? 0 : 1)
                .transformPreference(HitRectsKey.self) { if collapsed { $0 = [] } }
                .transformPreference(DropRectKey.self) { if collapsed { $0 = .zero } }
            } else {
                RailColumn(edge: edge, specs: specs, state: state, store: store)
                    .frame(width: railFrame.width, height: railFrame.height,
                           alignment: railContentAlignment)
            }
        }
        .frame(width: shellSize.width, height: shellSize.height,
               alignment: notchMode ? .top : .topLeading)
        .clipped()
        // The flares are drawn *outside* the content area; without this margin
        // the notch curves eat into the first and last rows.
        .padding(edge.isVertical ? .vertical : .horizontal, shellFlare)
        .background(shellShape.fill(Theme.shell))
        .clipShape(shellShape)
        // The wings differ in width, so the shape slides sideways by half the
        // difference to keep the gap between them over the camera.
        .offset(x: notchMode && !collapsed ? (wings.right - wings.left) / 2 : 0)
        .onPreferenceChange(DetailHeightKey.self) { detailHeight = $0 }
        .reportHitRect(isTop && (isOpen || notchMode))

    }

    private var shellSize: CGSize {
        if collapsed {
            // The flares are drawn outside this box, so they have to fit inside
            // the camera housing too; a point short on each side keeps the
            // antialiased edge from peeking past the hardware.
            return CGSize(width: max(state.notchSize.width - Metrics.notchFlare * 2 - 2, 0),
                          height: max(state.notchSize.height - 1, 0))
        }
        guard isTop else { return railFrame }
        if notchMode {
            var height = Metrics.wingStripHeight(notch: state.notchSize)
            if isOpen && detailHeight > 0 {
                height += Metrics.topDetailGap + detailHeight + Metrics.wingPadOuter
            }
            return CGSize(width: wings.left + state.notchSize.width + wings.right, height: height)
        }
        var height = Metrics.railThickness(edge: edge) + notchInset
        if isOpen && detailHeight > 0 {
            height += Metrics.topDetailGap + detailHeight + topInsetLeading
        }
        return CGSize(width: max(railLength, Metrics.detailWidth + topInsetLeading + topInsetTrailing),
                      height: height)
    }

    /// In notch mode the silhouette uses the camera housing's own corners, so
    /// folded it matches the hardware and grown it reads as the same object.
    private var shellFlare: CGFloat { notchMode ? Metrics.notchFlare : Metrics.flare }
    private var shellShape: NotchShape {
        notchMode
            ? NotchShape(edge: edge, cornerRadius: Metrics.notchCorner, flare: Metrics.notchFlare)
            : NotchShape(edge: edge)
    }

    private var wings: (left: CGFloat, right: CGFloat) {
        Metrics.wingWidths(gauges: specs.count, shortcuts: slotCount)
    }

    /// Grown out of the notch: one strip the height of the menu bar, gauges on
    /// the notch's left and shortcuts on its right, the detail opening under
    /// the gauges.
    private var notchBody: some View {
        let strip = Metrics.wingStripHeight(notch: state.notchSize)
        let height = max(Metrics.wingRing, Metrics.wingIcon)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(specs) { spec in
                        RailItem(spec: spec, state: state,
                                 isActive: state.active == spec.id, compact: true)
                            .frame(width: Metrics.wingGaugeSlot, height: height)
                    }
                }
                .padding(.leading, Metrics.wingPadOuter)
                .frame(width: wings.left, alignment: .leading)

                Color.clear.frame(width: state.notchSize.width, height: height)

                HStack(spacing: 0) {
                    ForEach(shortcuts) { shortcut in
                        ShortcutItem(shortcut: shortcut, axis: .horizontal,
                                     state: state, store: store,
                                     slot: Metrics.wingShortcutSlot,
                                     iconSize: Metrics.wingIcon)
                            .frame(width: Metrics.wingShortcutSlot, height: height)
                            .transition(.gooeyDrop)
                    }
                    if state.dropTargeting {
                        DropSlot()
                            .scaleEffect(Metrics.wingIcon / Metrics.iconDiameter)
                            .frame(width: Metrics.wingShortcutSlot, height: height)
                            .transition(.gooeyDrop)
                    }
                }
                .padding(.leading, Metrics.wingPadInner)
                .frame(width: wings.right, alignment: .leading)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: DropRectKey.self,
                                           value: geo.frame(in: .named("root")))
                })
                .animation(Motion.gooey, value: shortcuts)
            }
            .padding(.top, Metrics.wingPadTop)
            .frame(height: strip, alignment: .top)

            if let spec = displayedSpec {
                WidgetBody(spec: spec, store: store)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: max(Metrics.detailWidth,
                                      wings.left - Metrics.wingPadOuter - Metrics.wingPadInner),
                           alignment: .topLeading)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: DetailHeightKey.self, value: geo.size.height)
                    })
                    .padding(.leading, Metrics.wingPadOuter)
                    .padding(.top, Metrics.topDetailGap)
                    .opacity(isOpen ? 1 : 0)
                    .onHover(perform: holdOpen)
            }
        }
    }

    /// Measured height of the open detail on the top edge.
    @State private var detailHeight: CGFloat = 0

    /// Where the first ring starts inside the rail: the rail's own padding plus
    /// the space a gauge slot leaves either side of its ring.
    private var topInsetLeading: CGFloat {
        Metrics.railPaddingV + (Metrics.rowHeight - Metrics.iconDiameter) / 2
    }

    /// Where the last icon ends — a shortcut slot is narrower than a gauge slot.
    private var topInsetTrailing: CGFloat {
        let slot = slotCount > 0 ? Metrics.shortcutRow : Metrics.rowHeight
        return Metrics.railPaddingV + (slot - Metrics.iconDiameter) / 2
    }

    private var topDetailWidth: CGFloat {
        max(railLength, Metrics.detailWidth + topInsetLeading + topInsetTrailing)
            - topInsetLeading - topInsetTrailing
    }

    // MARK: Geometry

    private var railLength: CGFloat {
        Metrics.contentHeight(gauges: specs.count, shortcuts: slotCount)
    }
    private var gaugeBlock: CGFloat { Metrics.gaugeBlockHeight(gauges: specs.count) }
    private var bulgeDepth: CGFloat {
        isOpen ? Metrics.bulgeDepth(edge: edge, gauges: specs.count) : 0
    }

    private var railFrame: CGSize {
        let thickness = Metrics.railThickness(edge: edge)
        return edge.isVertical ? CGSize(width: thickness, height: railLength)
                               : CGSize(width: railLength, height: thickness)
    }

    private var railShapeFrame: CGSize {
        edge.isVertical ? CGSize(width: Metrics.railWidth, height: railShapeLength)
                        : CGSize(width: railShapeLength, height: Metrics.railWidth)
    }

    private var islandSize: CGSize {
        if notchMode {
            return Metrics.notchIslandSize(gauges: specs.count, shortcuts: slotCount,
                                           notch: state.notchSize)
        }
        var size = Metrics.islandSize(edge: edge, gauges: specs.count, shortcuts: slotCount)
        size.height += notchInset
        return size
    }

    /// The corner the island hangs from: the start of its edge.
    private var islandAlignment: Alignment {
        switch edge {
        case .left:  return .topLeading
        case .right: return .topTrailing
        case .top:   return notchMode ? .top : .topLeading
        }
    }

    private var railContentAlignment: Alignment {
        edge.isVertical ? .top : .leading
    }

    private var bulge: some View {
        ZStack(alignment: bulgeContentAlignment) {
            BulgeShape(edge: edge,
                       inset: Metrics.panelOverlap,
                       corner: Metrics.detailCorner,
                       farFillet: bulgeFillet)
                .fill(Theme.shell)

            if let spec = displayedSpec {
                WidgetBody(spec: spec, store: store)
                    // Top-aligned so a short panel does not float mid-block;
                    // the inset keeps its first line off the rounded corner.
                    .padding(.top, Metrics.detailPadding)
                    .frame(width: Metrics.detailWidth,
                           height: gaugeBlock,
                           alignment: .topLeading)
                    // Clear the slice that sits under the rail, or the first
                    // characters of every line disappear behind it.
                    .padding(bulgeNearEdge, Metrics.panelOverlap)
                    .padding(bulgeFarEdge, Metrics.detailPadding)
                    .opacity(isOpen ? 1 : 0)
            }
        }
        .frame(width: bulgeSize.width, height: bulgeSize.height,
               alignment: bulgeContentAlignment)
        .clipped()
        .padding(bulgeNearEdge, Metrics.railThickness(edge: edge) - Metrics.panelOverlap)
        .padding(edge.isVertical ? .top : .leading, Metrics.flare)
        .reportHitRect(isOpen)
        .onHover(perform: holdOpen)
    }

    /// The detail has buttons in it now, so reaching it must not close it: the
    /// logo's hover-out would otherwise collapse the panel on the way over.
    private func holdOpen(_ inside: Bool) {
        guard let id = state.displayed else { return }
        if inside {
            if isOpen { state.enter(id) }
        } else {
            state.leave(id)
        }
    }

    /// Depth away from the edge, span along it.
    private var bulgeSize: CGSize {
        let span = Metrics.detailAlong(edge: edge, gauges: specs.count) + bulgeFillet
        return edge.isVertical ? CGSize(width: bulgeDepth, height: span)
                               : CGSize(width: span, height: bulgeDepth)
    }

    /// The side of the bulge that tucks under the rail.
    private var bulgeNearEdge: SwiftUI.Edge.Set {
        switch edge {
        case .left:  return .leading
        case .right: return .trailing
        case .top:   return .top
        }
    }

    private var bulgeFarEdge: SwiftUI.Edge.Set {
        switch edge {
        case .left:  return .trailing
        case .right: return .leading
        case .top:   return .bottom
        }
    }

    private var bulgeContentAlignment: Alignment {
        switch edge {
        case .left:  return .topLeading
        case .right: return .topTrailing
        case .top:   return .topLeading
        }
    }
}

/// Lays its children out along whichever axis the rail runs.
///
/// A horizontal rail top-aligns: a gauge is an icon with a caption under it
/// while a shortcut is just an icon, so centring each one separately would leave
/// the shortcuts sitting lower than the gauges by half a caption.
struct AxisStack<Content: View>: View {
    let axis: Axis
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        if axis == .vertical {
            VStack(spacing: spacing) { content }
        } else {
            HStack(alignment: .top, spacing: spacing) { content }
        }
    }
}

struct RailColumn: View {
    let edge: NotchEdge
    let specs: [WidgetSpec]
    @ObservedObject var state: PanelState
    @ObservedObject var store: UsageStore

    private var shortcuts: [Shortcut] { store.config.shortcuts }
    private var axis: Axis { edge.railAxis }

    var body: some View {
        AxisStack(axis: axis) {
            ForEach(specs) { spec in
                RailItem(
                    spec: spec,
                    state: state,
                    isActive: state.active == spec.id
                )
                .frame(width: axis == .horizontal ? Metrics.rowHeight : nil,
                       height: axis == .vertical ? Metrics.rowHeight : nil)
            }

            if !shortcuts.isEmpty || state.dropTargeting {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: axis == .vertical ? Metrics.iconDiameter : 1,
                           height: axis == .vertical ? 1 : Metrics.iconDiameter)
                    .padding(.top, axis == .vertical ? 0 : 0)
                    .padding(axis == .vertical ? .vertical : .horizontal,
                             (Metrics.dividerBlock - 1) / 2)
                    .transition(.opacity)
            }

            ForEach(shortcuts) { shortcut in
                ShortcutItem(shortcut: shortcut, axis: axis, state: state, store: store)
                    .frame(width: axis == .horizontal ? Metrics.shortcutRow : nil,
                           height: axis == .vertical ? Metrics.shortcutRow : nil)
                    .transition(.gooeyDrop)
            }

            if state.dropTargeting {
                DropSlot()
                    .frame(width: axis == .horizontal ? Metrics.shortcutRow : nil,
                           height: axis == .vertical ? Metrics.shortcutRow : nil)
                    .transition(.gooeyDrop)
            }
        }
        .padding(axis == .vertical ? .vertical : .horizontal, Metrics.railPaddingV)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: DropRectKey.self,
                                       value: geo.frame(in: .named("root")))
            }
        )
        .reportHitRect()
        .animation(Motion.gooey, value: shortcuts)
        .animation(Motion.gooey, value: state.dropTargeting)
    }
}

/// Icons arrive and leave like a drop of liquid: they come in small and blurred,
/// overshoot, then settle — and go out the same way, bigger and softer.
extension AnyTransition {
    static var gooeyDrop: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.25).combined(with: .opacity).combined(with: .blurred(6)),
            removal: .scale(scale: 1.45).combined(with: .opacity).combined(with: .blurred(10))
        )
    }

    static func blurred(_ radius: CGFloat) -> AnyTransition {
        .modifier(active: BlurModifier(radius: radius), identity: BlurModifier(radius: 0))
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// The Meetily record button's face. Red with a white stop square while it
/// records, with a ring that keeps rippling out so it reads as live.
struct RecordGlyph: View {
    let size: CGFloat
    @ObservedObject private var recorder = MeetilyRecorder.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Smaller than an app icon: an app icon's square fills its frame, a
    /// circle of the same width looks heavier.
    private var diameter: CGFloat { size * 0.7 }

    var body: some View {
        ZStack {
            if recorder.status == .recording, !reduceMotion {
                Ripple(diameter: diameter)
            }
            face
                .frame(width: diameter, height: diameter)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: recorder.status)
    }

    @ViewBuilder private var face: some View {
        switch recorder.status {
        case .recording:
            Image(systemName: "stop.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.danger)
        case .paused:
            Image(systemName: "stop.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.warn)
        case .idle:
            Image(systemName: "record.circle")
                .resizable()
                .fontWeight(.light)
                .foregroundStyle(Theme.textPrimary)
        case .notRunning, .noPermission, .busy:
            Image(systemName: "record.circle")
                .resizable()
                .fontWeight(.light)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// A thin ring that leaves the button and fades, once every 1.6 s.
private struct Ripple: View {
    let diameter: CGFloat
    private let period: Double = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            let eased = 1 - (1 - t) * (1 - t)
            Circle()
                .stroke(Theme.danger, lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .scaleEffect(1 + 0.4 * eased)
                .opacity(0.6 * (1 - eased))
        }
        .allowsHitTesting(false)
    }
}

/// The landing spot that opens up while a file is held over the rail.
struct DropSlot: View {
    @State private var breathing = false

    var body: some View {
        Circle()
            .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
            .frame(width: Metrics.iconDiameter, height: Metrics.iconDiameter)
            .scaleEffect(breathing ? 1.06 : 0.94)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

struct ShortcutItem: View {
    let shortcut: Shortcut
    let axis: Axis
    @ObservedObject var state: PanelState
    @ObservedObject var store: UsageStore
    /// Length of one slot along the rail, which is how far a reorder moves it.
    var slot: CGFloat = Metrics.shortcutRow
    var iconSize: CGFloat = Metrics.iconDiameter

    /// Slot the icon was in when the drag began; reordering is measured from it.
    @State private var startIndex: Int?

    private var isPulling: Bool { state.pulling == shortcut.path }
    /// The record button cannot be removed, so it never looks like it is leaving.
    private var leaving: Bool { isPulling && state.pullingOut && !shortcut.isRecorder }

    private var index: Int {
        store.config.shortcuts.firstIndex { $0.path == shortcut.path } ?? 0
    }

    /// The pointer's travel, less the slots the icon has already moved into —
    /// so it stays under the pointer while its neighbours slide past.
    private var dragOffset: CGSize {
        guard isPulling else { return .zero }
        var offset = state.pullOffset
        let moved = CGFloat(state.pullShift) * slot
        if axis == .vertical { offset.height -= moved } else { offset.width -= moved }
        return offset
    }

    @ViewBuilder private var icon: some View {
        if shortcut.isRecorder {
            RecordGlyph(size: iconSize)
        } else {
            Image(nsImage: ShortcutIcon.image(for: shortcut))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .opacity(shortcut.exists ? 1 : 0.35)
        }
    }

    var body: some View {
        icon
            // While it is being pulled out it follows the pointer and thins out,
            // so letting go past the threshold reads as intentional.
            .offset(dragOffset)
            .scaleEffect(leaving ? 0.8 : (isPulling ? 1.08 : 1))
            .opacity(leaving ? 0.45 : 1)
            .blur(radius: leaving ? 3 : 0)
            // The held icon tracks the pointer exactly; only its neighbours animate.
            .transaction { if isPulling { $0.animation = nil } }
            .animation(Motion.gooey, value: isPulling)
            .animation(Motion.gooey, value: leaving)
            .zIndex(isPulling ? 1 : 0)
            .contentShape(Circle())
            .reportHitRect()
            .help(shortcut.isRecorder ? L.recorder(MeetilyRecorder.shared.status) : shortcut.name)
            .onTapGesture {
                if shortcut.isRecorder { MeetilyRecorder.shared.openApp() } else { shortcut.open() }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        if startIndex == nil { startIndex = index }
                        state.beginPull(shortcut.path, axis: axis)
                        state.updatePull(value.translation)
                        reorder(for: value.translation)
                    }
                    .onEnded { value in
                        state.updatePull(value.translation)
                        reorder(for: value.translation)
                        let moved = state.pullShift != 0
                        startIndex = nil
                        if state.endPull(), !shortcut.isRecorder {
                            store.removeShortcut(shortcut)
                        } else if moved {
                            store.saveConfig()
                        }
                    }
            )
    }

    /// Moves the icon one slot at a time as the pointer crosses into the next row.
    private func reorder(for translation: CGSize) {
        guard !state.pullingOut, let start = startIndex else { return }
        let along = axis == .vertical ? translation.height : translation.width
        let count = store.config.shortcuts.count
        let target = min(max(start + Int((along / slot).rounded()), 0), count - 1)
        guard target != index else { return }
        withAnimation(Motion.gooey) { store.moveShortcutLive(shortcut, to: target) }
        state.updateShift(target - start)
    }
}

struct RailItem: View {
    let spec: WidgetSpec
    @ObservedObject var state: PanelState
    let isActive: Bool
    /// In the notch's wing: a smaller ring with its percentage beside it, so
    /// the whole gauge fits in the height of the menu bar.
    var compact = false

    private var diameter: CGFloat { compact ? Metrics.wingRing : Metrics.iconDiameter }

    private var tint: Color {
        guard spec.available else { return Theme.textTertiary }
        return spec.ringColor ?? Theme.tint(remaining: spec.remaining)
    }

    var body: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: 5))
            : AnyLayout(VStackLayout(spacing: Metrics.captionSpacing))
        layout {
            ZStack {
                ArcGauge(remaining: spec.remaining, color: tint)
                if spec.grokFace {
                    GrokFace(color: spec.available ? spec.markColor : Theme.textTertiary, still: true)
                        .frame(width: diameter * 0.50, height: diameter * 0.50)
                } else if let symbol = spec.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: diameter * 0.40, weight: .medium))
                        .foregroundStyle(spec.available ? spec.markColor : Theme.textTertiary)
                } else {
                    SVGShape(data: spec.logo)
                        .fill(spec.available ? spec.markColor : Theme.textTertiary)
                        .frame(width: diameter * 0.46, height: diameter * 0.46)
                }
            }
            .frame(width: diameter, height: diameter)
            // In the wing there is no caption row, so the percentage sits in the
            // open gap at the bottom of the arc.
            .overlay(alignment: .bottom) {
                if compact {
                    Text(spec.caption.replacingOccurrences(of: "%", with: ""))
                        .font(.system(size: 8, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(spec.available ? Theme.textSecondary : Theme.textTertiary)
                        .fixedSize()
                        .offset(y: 4)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(isActive ? 1.08 : 1)
            // Only the logo is the trigger — the shell around it stays inert.
            .contentShape(Circle())
            .reportHitRect()
            .onHover { inside in
                if inside { state.enter(spec.id) } else { state.leave(spec.id) }
            }
            .onTapGesture {
                if let app = spec.app {
                    AppLauncher.open(URL(fileURLWithPath: app))
                } else {
                    state.togglePin(spec.id)
                }
            }
            // 4pt of slack so a click still reads as a click, not a nudge.
            // The gesture only says *that* a drag is happening. Its translation
            // is measured in the view, and the view rides along with the window
            // being dragged, so it reports exactly half the real movement — the
            // controller reads the pointer in screen coordinates instead.
            .gesture(
                // Starting the drag is all the gesture does; the controller polls
                // the pointer from there, so rebuilding this view at a corner
                // cannot interrupt it.
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        // A bare pointer move over the logo can still reach this,
                        // and acting on it drags the notch off to another edge on
                        // its own. A drag has to have a button behind it.
                        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                        state.beginDrag()
                    }
                    // Belt and braces: the timer normally sees the button go up,
                    // but if this view survives the drag the gesture will say so
                    // first, and finishing twice is a no-op.
                    .onEnded { _ in state.endDrag() }
            )
            .animation(Motion.panel(active: isActive), value: isActive)

            if !compact {
            HStack(spacing: 3) {
                // Two Claude logos on one rail are the same drawing, so the
                // number is the only thing telling them apart. It rides with the
                // percentage rather than over the mark, which would crowd it.
                if !spec.badge.isEmpty {
                    Text(spec.badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(spec.markColor)
                }
                Text(spec.caption)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(spec.available ? Theme.textSecondary : Theme.textTertiary)
            }
            // The caption is digits only, so its line box carries descender
            // slack the glyphs never use. Tightening the box to the ink is
            // what keeps the column optically centred in the island.
            .frame(height: Metrics.captionHeight)
            .allowsHitTesting(false)
            }
        }
    }
}
