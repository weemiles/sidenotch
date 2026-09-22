import AppKit
import SwiftUI

@MainActor
final class NotchController {
    private let store: UsageStore
    private let state = PanelState()
    private var panel: NotchPanel?
    private var hosting: PassthroughHostingView<NotchRoot>?

    /// Where the window and the pointer were when the current drag started.
    private var dragOriginY: CGFloat = 0
    private var dragStartMouseY: CGFloat = 0

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
        state.dragMoved = { [weak self] in self?.moveDrag() }
        state.dragEnded = { [weak self] in self?.endDrag() }

        reposition()
        panel.orderFrontRegardless()
    }

    func reposition() {
        guard let panel else { return }
        let screen = targetScreen()
        let frame = screen.frame

        let width = Metrics.expandedWidth + Metrics.windowMargin
        // Only as tall as the silhouette plus a little slack for the overshoot.
        // An oversized window would hit the screen edge long before the island does.
        let height = min(Metrics.islandHeight(gauges: visibleRows,
                                              shortcuts: store.config.shortcuts.count + 1)
                            + Metrics.windowMargin,
                         frame.height)

        let anchor = min(max(store.config.verticalAnchor, 0), 1)
        let centerY = frame.maxY - CGFloat(anchor) * frame.height
        let y = min(max(centerY - height / 2, frame.minY), frame.maxY - height)

        panel.setFrame(NSRect(x: frame.minX, y: y, width: width, height: height),
                       display: true)

        if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
            let f = panel.frame
            let line = "panel: x=\(f.minX) y=\(f.minY) \(f.width)x\(f.height)"
                + " screen=\(frame.minX),\(frame.minY) \(frame.width)x\(frame.height)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private var visibleRows: Int {
        (store.config.showClaude ? 1 : 0) + (store.config.showCodex ? 1 : 0)
    }

    // MARK: Dragging

    private func beginDrag() {
        dragOriginY = panel?.frame.minY ?? 0
        dragStartMouseY = NSEvent.mouseLocation.y
    }

    private func moveDrag() {
        guard let panel else { return }
        let screen = targetScreen().frame
        let height = panel.frame.height
        let delta = NSEvent.mouseLocation.y - dragStartMouseY
        let y = min(max(dragOriginY + delta, screen.minY), screen.maxY - height)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: y))
    }

    private func endDrag() {
        guard let panel else { return }
        let screen = targetScreen().frame
        let centreY = panel.frame.minY + panel.frame.height / 2
        var cfg = store.config
        cfg.verticalAnchor = Double((screen.maxY - centreY) / screen.height)
        cfg.save()
        store.reloadConfig()
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
