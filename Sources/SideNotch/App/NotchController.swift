import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchController {
    private let store: UsageStore
    private let state = PanelState()
    private var panel: NotchPanel?
    private var hosting: PassthroughHostingView<NotchRoot>?

    /// Drives the drag from a timer rather than the SwiftUI gesture: crossing a
    /// corner rebuilds the rail's layout, which would tear the gesture down
    /// mid-drag. Polling the pointer survives that.
    private var dragTimer: Timer?
    /// Only trust a "button is up" reading once we have actually seen it down;
    /// otherwise a stale reading on the first tick ends the drag instantly.
    private var sawButtonDown = false
    /// Eased position along the current edge, so the notch trails the pointer
    /// instead of snapping to it frame by frame.
    private var smoothedAnchor: Double = 0.5
    /// Claude accounts are found after launch; each is a gauge, so the window
    /// is re-sized when the count changes.
    private var accountWatch: AnyCancellable?
    /// An AI app installed or removed adds or drops a gauge the same way.
    private var installWatch: AnyCancellable?
    private var mouseMonitors: [Any] = []

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        let root = NotchRoot(store: store, state: state, onHitRects: { [weak self] rects in
            guard let self else { return }
            // Folded into the notch it catches exactly the camera housing and not
            // a point more, so the menu bar right beside it stays clickable.
            let folded = self.store.config.notchMode && !self.state.revealed
            self.hosting?.hitRects = folded ? rects : rects.map { $0.insetBy(dx: -4, dy: -4) }
            if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
                let desc = rects.map {
                    "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))"
                }.joined(separator: " ")
                FileHandle.standardError.write(Data("hitRects[\(rects.count)] \(desc)\n".utf8))
            }
        }, onDropRect: { [weak self] rect in
            self?.hosting?.dropRect = rect.insetBy(dx: -8, dy: -8)
        })
        let view = PassthroughHostingView(rootView: root)
        // Without this the hosting view inherits a safe-area inset and the shape
        // stops a few points short of the screen edge, which kills the whole
        // "growing out of the bezel" read.
        view.safeAreaRegions = []
        // Accept apps dragged from Finder or the Dock onto the rail.
        view.registerForDraggedTypes([.fileURL])
        view.onDropTargeting = { [weak self] targeting in
            guard let self else { return }
            // Folded into the notch there is no slot to aim at, so an app
            // carried over it opens the island to show where it will land.
            if targeting && self.store.config.notchMode && !self.state.revealed {
                self.state.reveal()
            }
            withAnimation(Motion.gooey) { self.state.dropTargeting = targeting }
        }
        view.onDrop = { [weak self] urls in
            guard let self else { return }
            withAnimation(Motion.gooey) { urls.forEach(self.store.addShortcut) }
            self.reposition()
        }
        hosting = view

        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                 // the shape draws its own
        panel.level = .statusBar
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        self.panel = panel

        state.pointerInNotch = { [weak self] in
            guard let self else { return false }
            return Self.notchRect(of: self.targetScreen()).contains(NSEvent.mouseLocation)
        }
        state.pointerInside = { [weak self] in
            guard let self, let panel = self.panel, let view = self.hosting else { return false }
            let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
            let local = view.convert(inWindow, from: nil)
            let point = view.isFlipped ? local : CGPoint(x: local.x, y: view.bounds.height - local.y)
            return view.hitRects.contains { $0.contains(point) }
        }
        state.dragBegan = { [weak self] in self?.beginDrag() }
        state.dragEnded = { [weak self] in self?.finishDrag() }

        reposition()
        panel.orderFrontRegardless()

        // The window is a large transparent box around the island. Letting it
        // ignore the mouse everywhere the pointer is not over the island is the
        // only way the apps underneath get their clicks: returning nil from
        // hitTest still keeps the event inside this window.
        let track: (NSEvent) -> Void = { [weak self] _ in self?.updateMousePassThrough() }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged], handler: track) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged], handler: { event in track(event); return event }) {
            mouseMonitors.append(local)
        }
        updateMousePassThrough()

        accountWatch = store.$claude
            .map(\.count)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
        installWatch = store.$installed
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
    }

    func reposition(animated: Bool = false) {
        guard let panel else { return }
        let display = targetScreen()
        let screen = display.frame
        var anchor = store.config.anchor
        if store.config.notchMode {
            let notch = Self.notchRect(of: display)
            state.notchSize = notch.size
            anchor = Double((notch.midX - screen.minX) / screen.width)
        }
        let size = windowSize(for: store.config.edge, screen: screen)
        let origin = originFor(edge: store.config.edge,
                               anchor: anchor,
                               size: size, screen: screen)
        let target = NSRect(origin: origin, size: size)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.snapDuration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }

        if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
            let line = "panel: edge=\(store.config.edge.rawValue)"
                + " x=\(target.minX) y=\(target.minY) \(target.width)x\(target.height)"
                + " screen=\(screen.width)x\(screen.height)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    /// The window has to hold the island at its widest, whichever way it faces.
    private func windowSize(for edge: NotchEdge, screen: CGRect) -> CGSize {
        let island = store.config.notchMode
            ? Metrics.notchIslandSize(gauges: visibleRows,
                                      shortcuts: store.config.shortcuts.count + 1,
                                      notch: state.notchSize)
            : Metrics.islandSize(edge: edge, gauges: visibleRows,
                                 shortcuts: store.config.shortcuts.count + 1)
        return CGSize(
            width: min(island.width + Metrics.windowMargin, screen.width),
            height: min(island.height + Metrics.windowMargin, screen.height)
        )
    }

    /// The camera housing, in screen coordinates: the strip between the two
    /// usable corners of the menu bar. A display without one gets a notch-sized
    /// spot in the middle of the menu bar, so the mode still works there.
    static func notchRect(of screen: NSScreen) -> CGRect {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let height = screen.safeAreaInsets.top
            return CGRect(x: left.maxX, y: frame.maxY - height,
                          width: right.minX - left.maxX, height: height)
        }
        let height = NSStatusBar.system.thickness
        return CGRect(x: frame.midX - 100, y: frame.maxY - height, width: 200, height: height)
    }

    /// `anchor` runs 0…1 along the docked edge: top to bottom, or left to right.
    private func originFor(edge: NotchEdge, anchor: Double,
                           size: CGSize, screen: CGRect) -> CGPoint {
        let a = CGFloat(min(max(anchor, 0), 1))
        switch edge {
        case .left, .right:
            let centreY = screen.maxY - a * screen.height
            let y = min(max(centreY - size.height / 2, screen.minY),
                        screen.maxY - size.height)
            let x = edge == .left ? screen.minX : screen.maxX - size.width
            return CGPoint(x: x, y: y)
        case .top:
            let centreX = screen.minX + a * screen.width
            let x = min(max(centreX - size.width / 2, screen.minX),
                        screen.maxX - size.width)
            return CGPoint(x: x, y: screen.maxY - size.height)
        }
    }

    /// Gauges on the rail — one per Claude account, as the view draws them.
    /// Undercounting leaves the window narrower than the island, which then
    /// spills out of it off-centre.
    private var visibleRows: Int {
        let c = store.config
        return (c.showClaude ? store.claude.count : 0) + (store.showsCodex ? 1 : 0)
            + (c.showMemory ? 1 : 0) + (store.showsGrok ? 1 : 0) + (store.showsCursor ? 1 : 0)
    }

    // MARK: Dragging

    private func beginDrag() {
        // Tucked into the notch the rail has exactly one place to be.
        guard !store.config.notchMode else { state.endDrag(); return }
        guard dragTimer == nil else { return }
        smoothedAnchor = store.config.anchor
        sawButtonDown = false
        // A drag puts the run loop in .eventTracking, where a default-mode
        // timer never fires — it has to be added in .common explicitly.
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // No gesture callback tells us the button went up once the view
                // has been rebuilt, so read the button state directly.
                let held = NSEvent.pressedMouseButtons & 1 != 0
                if held { self.sawButtonDown = true }
                if self.sawButtonDown && !held {
                    self.finishDrag()
                } else {
                    self.followCursorAlongEdges()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    /// The notch never leaves the screen edge: the pointer only chooses which
    /// edge it is on and how far along, and it eases towards that.
    private func followCursorAlongEdges() {
        guard let panel else { return }
        let screen = targetScreen().frame
        let mouse = NSEvent.mouseLocation
        let edge = NotchEdge.nearest(to: mouse, in: screen)

        let target: Double = edge.isVertical
            ? Double((screen.maxY - mouse.y) / screen.height)
            : Double((mouse.x - screen.minX) / screen.width)

        // Exponential ease. Rotating to a new edge is instant — that is the
        // notch turning the corner — but sliding along one is smoothed.
        if edge != store.config.edge {
            var cfg = store.config
            cfg.edge = edge
            store.applyLive(cfg)
            smoothedAnchor = target
        }
        smoothedAnchor += (target - smoothedAnchor) * 0.18

        var cfg = store.config
        cfg.anchor = smoothedAnchor
        store.applyLive(cfg)

        let size = windowSize(for: edge, screen: screen)
        let origin = originFor(edge: edge, anchor: smoothedAnchor, size: size, screen: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Takes the mouse only while the pointer is over the island itself, or
    /// while something started on it is still in progress.
    private func updateMousePassThrough() {
        guard let panel else { return }
        let busy = state.dragging || state.pulling != nil || state.dropTargeting
        let over = state.pointerInside?() ?? true
        let ignore = !(over || busy)
        // Notch mode opens and folds from the pointer's real position, not from
        // SwiftUI hover, which misses the entry when the window only starts
        // taking the mouse on that very move.
        if store.config.notchMode {
            if !state.revealed {
                if state.pointerInNotch?() == true { state.reveal() }
            } else if !over && !busy {
                state.concealSoon()
            }
        }
        guard panel.ignoresMouseEvents != ignore else { return }
        panel.ignoresMouseEvents = ignore
        if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
            FileHandle.standardError.write(Data("mouse: \(ignore ? "pass-through" : "captured")\n".utf8))
        }
    }

    /// Turns notch mode on or off. On, the rail moves to the top edge over the
    /// notch; off, it stays on the top edge where it can be dragged anywhere.
    func setNotchMode(_ on: Bool) {
        var cfg = store.config
        cfg.notchMode = on
        if on { cfg.edge = .top }
        cfg.save()
        store.applyLive(cfg)
        state.revealed = false
        reposition()
    }

    func finishDrag() {
        guard dragTimer != nil else { return }
        dragTimer?.invalidate()
        dragTimer = nil
        state.endDrag()
        store.config.save()
        reposition(animated: true)
    }

    /// Pin the rail to whichever display the cursor is on, and remember it.
    func moveToScreenUnderCursor() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        var cfg = store.config
        cfg.displayID = displayID(of: screen)
        cfg.save()
        store.reloadConfig()
        reposition()
    }

    private func targetScreen() -> NSScreen {
        if let wanted = store.config.displayID,
           let match = NSScreen.screens.first(where: { displayID(of: $0) == wanted }) {
            return match
        }
        return NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
