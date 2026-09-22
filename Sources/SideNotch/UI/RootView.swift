import SwiftUI

struct WidgetSpec: Identifiable {
    let id: String
    let logo: String
    let markColor: Color
    /// Fraction still available, 0...1 — everything is shown battery-style.
    let remaining: Double
    let caption: String
    let available: Bool
}

/// Reports interactive regions up to the hosting view so everything else stays
/// click-through. Coordinates are top-left origin, matching SwiftUI.
struct HitRectsKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
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
        if store.config.showClaude {
            let live = store.claude.windowEnd != nil
            out.append(WidgetSpec(
                id: "claude",
                logo: BrandMark.claude,
                markColor: Theme.claudeMark,
                remaining: live ? store.claude.remaining : 1,
                caption: live ? Fmt.percent(store.claude.remaining) : "–",
                available: live
            ))
        }
        if store.config.showCodex {
            let p = store.codex.primary
            out.append(WidgetSpec(
                id: "codex",
                logo: BrandMark.openai,
                markColor: Theme.openaiMark,
                remaining: store.codex.remaining,
                caption: p.map { Fmt.percent($0.remaining) } ?? "–",
                available: p != nil
            ))
        }
        return out
    }

    private var isOpen: Bool { state.active != nil }
    private var shortcuts: [Shortcut] { store.config.shortcuts }
    private var displayedSpec: WidgetSpec? { specs.first { $0.id == state.displayed } }

    /// Shortcut rows plus the ghost slot shown while a file hovers over the rail.
    private var slotCount: Int { shortcuts.count + (state.dropTargeting ? 1 : 0) }

    /// The rail only carries on below the bulge when there are shortcuts, and
    /// that is the only time the join needs a concave curve.
    private var bulgeFillet: CGFloat { slotCount > 0 ? Metrics.bulgeFillet : 0 }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            island
        }
        .coordinateSpace(name: "root")
        .animation(Motion.panel(active: isOpen), value: state.active)
        .animation(Motion.panel(active: isOpen), value: state.displayed)
        .onPreferenceChange(HitRectsKey.self, perform: onHitRects)
        .onPreferenceChange(DropRectKey.self, perform: onDropRect)
    }

    /// Rail and bulge are two solid-black shapes, the bulge emerging from
    /// *under* the rail. Same colour, overlapping, so they read as one body —
    /// but the bulge is only as tall as the gauge rows, so adding shortcuts
    /// lengthens the rail without lengthening what pops out sideways.
    private var island: some View {
        ZStack(alignment: .topLeading) {
            bulge
            RailColumn(specs: specs, state: state, store: store)
                .frame(height: Metrics.contentHeight(gauges: specs.count,
                                                     shortcuts: slotCount),
                       alignment: .top)
                // The flares are drawn *outside* the content area; without this
                // margin the notch curves eat into the top and bottom rows.
                .padding(.vertical, Metrics.flare)
                .background(LeftNotchShape().fill(Theme.shell))
                .clipShape(LeftNotchShape())
        }
        .frame(width: Metrics.expandedWidth,
               height: Metrics.islandHeight(gauges: specs.count, shortcuts: slotCount),
               alignment: .topLeading)
        .animation(Motion.stretch, value: slotCount)
    }

    private var bulge: some View {
        ZStack(alignment: .topLeading) {
            BulgeShape(inset: Metrics.panelOverlap,
                       corner: Metrics.detailCorner,
                       bottomFillet: bulgeFillet)
                .fill(Theme.shell)

            if let spec = displayedSpec {
                WidgetBody(spec: spec, store: store)
                    .frame(width: Metrics.detailWidth,
                           height: Metrics.gaugeBlockHeight(gauges: specs.count),
                           alignment: .leading)
                    // Clear the slice that sits behind the rail, or the first
                    // characters of every line disappear under it.
                    .padding(.leading, Metrics.panelOverlap)
                    .padding(.trailing, Metrics.detailPadding)
                    .opacity(isOpen ? 1 : 0)
            }
        }
        .frame(width: isOpen ? Metrics.bulgeWidth : 0,
               height: Metrics.gaugeBlockHeight(gauges: specs.count) + bulgeFillet,
               alignment: .topLeading)
        .clipped()
        .padding(.leading, Metrics.railWidth - Metrics.panelOverlap)
        .padding(.top, Metrics.flare)
        .reportHitRect(isOpen)
    }
}

struct RailColumn: View {
    let specs: [WidgetSpec]
    @ObservedObject var state: PanelState
    @ObservedObject var store: UsageStore

    private var shortcuts: [Shortcut] { store.config.shortcuts }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(specs) { spec in
                RailItem(
                    spec: spec,
                    state: state,
                    isActive: state.active == spec.id,
                    isPinned: state.pinned == spec.id
                )
                .frame(height: Metrics.rowHeight)
            }

            if !shortcuts.isEmpty || state.dropTargeting {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: Metrics.iconDiameter, height: 1)
                    .padding(.vertical, (Metrics.dividerBlock - 1) / 2)
                    .transition(.opacity)
            }

            ForEach(shortcuts) { shortcut in
                ShortcutItem(shortcut: shortcut, state: state, store: store)
                    .frame(height: Metrics.shortcutRow)
                    .transition(.gooeyDrop)
            }

            if state.dropTargeting {
                DropSlot()
                    .frame(height: Metrics.shortcutRow)
                    .transition(.gooeyDrop)
            }
        }
        .padding(.vertical, Metrics.railPaddingV)
        .frame(width: Metrics.railWidth)
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
    @ObservedObject var state: PanelState
    @ObservedObject var store: UsageStore

    private var isPulling: Bool { state.pulling == shortcut.path }
    private var leaving: Bool { isPulling && state.pullingOut }

    var body: some View {
        Image(nsImage: ShortcutIcon.image(for: shortcut))
            .resizable()
            .interpolation(.high)
            .frame(width: Metrics.iconDiameter, height: Metrics.iconDiameter)
            .opacity(shortcut.exists ? 1 : 0.35)
            // While it is being pulled out it follows the pointer and thins out,
            // so letting go past the threshold reads as intentional.
            .offset(isPulling ? state.pullOffset : .zero)
            .scaleEffect(leaving ? 0.8 : (isPulling ? 1.08 : 1))
            .opacity(leaving ? 0.45 : 1)
            .blur(radius: leaving ? 3 : 0)
            .animation(Motion.gooey, value: isPulling)
            .animation(Motion.gooey, value: leaving)
            .contentShape(Circle())
            .reportHitRect()
            .help(shortcut.name)
            .onTapGesture { shortcut.open() }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        state.beginPull(shortcut.path)
                        state.updatePull(value.translation)
                    }
                    .onEnded { value in
                        state.updatePull(value.translation)
                        if state.endPull() { store.removeShortcut(shortcut) }
                    }
            )
    }
}

struct RailItem: View {
    let spec: WidgetSpec
    @ObservedObject var state: PanelState
    let isActive: Bool
    let isPinned: Bool

    private var tint: Color {
        spec.available ? Theme.tint(remaining: spec.remaining) : Theme.textTertiary
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                ArcGauge(remaining: spec.remaining, color: tint)
                SVGShape(data: spec.logo)
                    .fill(spec.available ? spec.markColor : Theme.textTertiary)
                    .frame(width: Metrics.iconDiameter * 0.46,
                           height: Metrics.iconDiameter * 0.46)
            }
            .frame(width: Metrics.iconDiameter, height: Metrics.iconDiameter)
            .scaleEffect(isActive ? 1.08 : 1)
            .overlay(alignment: .bottom) {
                if isPinned {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 10, height: 2)
                        .offset(y: 3)
                }
            }
            // Only the logo is the trigger — the shell around it stays inert.
            .contentShape(Circle())
            .reportHitRect()
            .onHover { inside in
                if inside { state.enter(spec.id) } else { state.leave(spec.id) }
            }
            .onTapGesture { state.togglePin(spec.id) }
            // 4pt of slack so a click still reads as a click, not a nudge.
            // The gesture only says *that* a drag is happening. Its translation
            // is measured in the view, and the view rides along with the window
            // being dragged, so it reports exactly half the real movement — the
            // controller reads the pointer in screen coordinates instead.
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        state.beginDrag()
                        state.moveDrag()
                    }
                    .onEnded { _ in
                        state.moveDrag()
                        state.endDrag()
                    }
            )
            .animation(Motion.panel(active: isActive), value: isActive)

            Text(spec.caption)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                // The caption is digits only, so its line box carries descender
                // slack the glyphs never use. Tightening the box to the ink is
                // what keeps the column optically centred in the island.
                .frame(height: 10)
                .foregroundStyle(spec.available ? Theme.textSecondary : Theme.textTertiary)
                .allowsHitTesting(false)
        }
    }
}
