import AppKit
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

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        let root = NotchRoot(store: store, state: state, onHitRects: { [weak self] rects in
            self?.hosting?.hitRects = rects.map { $0.insetBy(dx: -4, dy: -4) }
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

        state.dragBegan = { [weak self] in self?.beginDrag() }
        state.dragEnded = { [weak self] in self?.finishDrag() }

        reposition()
        panel.orderFrontRegardless()
    }

    func reposition(animated: Bool = false) {
        guard let panel else { return }
        let screen = targetScreen().frame
        let size = windowSize(for: store.config.edge, screen: screen)
        let origin = originFor(edge: store.config.edge,
                               anchor: store.config.anchor,
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
        let island = Metrics.islandSize(edge: edge, gauges: visibleRows,
                                        shortcuts: store.config.shortcuts.count + 1)
        return CGSize(
            width: min(island.width + Metrics.windowMargin, screen.width),
            height: min(island.height + Metrics.windowMargin, screen.height)
        )
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

    /// Pin the rail to whichever display the cursor is on, and remember it.
    private var visibleRows: Int {
        (store.config.showClaude ? 1 : 0) + (store.config.showCodex ? 1 : 0)
            + (store.config.showMemory ? 1 : 0)
    }

    // MARK: Dragging


    // MARK: Dragging

    private func beginDrag() {
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
