import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats above other apps without ever
/// taking focus — clicking it must not pull you out of the terminal you are in.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The window covers a large rectangle so the panel has room to slide out, but
/// only the drawn regions should swallow the mouse. Everything else returns nil
/// from `hitTest`, so clicks land on whatever app is underneath.
///
/// `hitRects` are in SwiftUI's coordinate space (top-left origin).
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var hitRects: [CGRect] = []

    /// Where a dropped file is accepted, in SwiftUI coordinates.
    var dropRect: CGRect = .zero
    var onDropTargeting: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard hitRects.contains(where: { $0.contains(flip(local)) }) else { return nil }
        return super.hitTest(point)
    }

    /// SwiftUI measures from the top left; AppKit hands us bottom-left points
    /// unless the view is flipped.
    private func flip(_ p: NSPoint) -> CGPoint {
        isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
    }

    // MARK: Dropping

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    private func isOverRail(_ sender: NSDraggingInfo) -> Bool {
        let local = convert(sender.draggingLocation, from: nil)
        let point = flip(local)
        let hit = dropRect.contains(point)
        if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
            let line = "drop: pt=\(Int(point.x)),\(Int(point.y))"
                + " rect=\(Int(dropRect.minX)),\(Int(dropRect.minY))"
                + " \(Int(dropRect.width))x\(Int(dropRect.height)) hit=\(hit)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return hit
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
            let line = "drop: entered urls=\(urls(from: sender).count)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        guard !urls(from: sender).isEmpty, isOverRail(sender) else { return [] }
        onDropTargeting?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let inside = !urls(from: sender).isEmpty && isOverRail(sender)
        onDropTargeting?(inside)
        return inside ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeting?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargeting?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(from: sender)
        onDropTargeting?(false)
        guard !dropped.isEmpty, isOverRail(sender) else { return false }
        onDrop?(dropped)
        return true
    }
}

/// Which widget is open, and why.
///
/// `displayed` lags `active` so the panel keeps its contents while it animates
/// closed, and the short grace period on `leave()` lets the pointer cross the
/// seam between a logo and its panel without the panel snapping shut.
@MainActor
final class PanelState: ObservableObject {
    @Published var active: String?
    @Published var displayed: String?
    @Published var pinned: String?
    @Published var dragging = false
    /// A file is hovering over the rail and would be accepted.
    @Published var dropTargeting = false
    /// Shortcut currently being pulled out of the rail, and how far.
    @Published var pulling: String?
    @Published var pullOffset: CGSize = .zero

    /// Notch mode: whether the rail has grown out of the camera notch.
    @Published var revealed = false
    /// The camera housing, measured by the controller from the screen. Collapsed,
    /// the shape is exactly this, so it disappears into the hardware notch.
    @Published var notchSize = CGSize(width: 200, height: 32)
    private var conceal: Task<Void, Never>?
    /// Whether the pointer is over the rail right now, asked of the window.
    /// SwiftUI reports a hover-out whenever the shape resizes under a still
    /// pointer, so that signal alone cannot be trusted to fold it away.
    var pointerInside: (() -> Bool)?
    /// Whether the pointer is well inside the camera housing, asked of the screen.
    var pointerInNotch: (() -> Bool)?
    private var pendingReveal: Task<Void, Never>?

    /// Wired up by the controller; SwiftUI has no way to move an NSWindow.
    var dragBegan: (() -> Void)?
    var dragEnded: (() -> Void)?

    private var collapse: Task<Void, Never>?

    private func trace(_ msg: String) {
        guard ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("state: \(msg)\n".utf8))
    }

    func enter(_ id: String) {
        guard !dragging else { return }
        trace("enter \(id)")
        collapse?.cancel()
        collapse = nil
        displayed = id
        active = id
    }

    /// SwiftUI does not guarantee that the old view's hover-out arrives before
    /// the new view's hover-in. Scoping the close to the id that is leaving means
    /// a neighbour that already took over is never closed out from under itself.
    func leave(_ id: String) {
        trace("leave \(id)")
        guard pinned == nil else { return }
        collapse?.cancel()
        collapse = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.active == id else { return }
            self.active = nil
        }
    }

    /// Collapse first: watching the panel trail behind the island while you
    /// reposition it is noise, and the drag is about placement, not content.
    func beginDrag() {
        guard !dragging else { return }
        trace("drag begin")
        dragging = true
        collapse?.cancel()
        active = nil
        dragBegan?()
    }

    func endDrag() {
        guard dragging else { return }
        trace("drag end")
        dragging = false
        dragEnded?()
    }

    /// Past this much horizontal travel the icon is treated as pulled out —
    /// the same "drag it off the Dock" gesture, so it needs no explanation.
    static let pullOutThreshold: CGFloat = 46

    /// Which way the rail runs while an icon is held. Travel across it pulls the
    /// icon out; travel along it reorders, the way icons move in the Dock.
    private(set) var pullAxis: Axis = .vertical
    /// Slots the held icon has moved along the rail since the drag began.
    @Published private(set) var pullShift = 0

    var pullingOut: Bool {
        abs(pullAxis == .vertical ? pullOffset.width : pullOffset.height) > Self.pullOutThreshold
    }

    func beginPull(_ id: String, axis: Axis) {
        guard pulling != id else { return }
        collapse?.cancel()
        active = nil
        pulling = id
        pullAxis = axis
        pullOffset = .zero
        pullShift = 0
    }

    func updatePull(_ offset: CGSize) { pullOffset = offset }

    func updateShift(_ shift: Int) { pullShift = shift }

    /// Returns true when the icon travelled far enough to be dropped.
    func endPull() -> Bool {
        let removed = pullingOut
        pulling = nil
        pullOffset = .zero
        pullShift = 0
        return removed
    }

    /// Grows out of the notch only for a pointer that has settled inside it —
    /// one passing on its way to the menu bar either side must not open a panel
    /// that then sits on top of what it was heading for.
    func reveal() {
        conceal?.cancel()
        conceal = nil
        guard !revealed else { return }
        pendingReveal?.cancel()
        // Watched for as long as the pointer is over the shape (a hover-out
        // cancels this), so one that comes in over the flare and then moves
        // onto the housing itself still opens it.
        pendingReveal = Task { [weak self] in
            while !Task.isCancelled, let self {
                if self.pointerInNotch?() ?? true {
                    self.trace("reveal")
                    self.revealed = true
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Folds back into the notch once the pointer has really gone — a short
    /// grace period so skimming the edge of the rail does not make it flicker —
    /// and never while something inside it is still in use.
    func concealSoon() {
        guard conceal == nil else { return }   // one countdown at a time
        trace("conceal soon")
        pendingReveal?.cancel()
        conceal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            // Still on it: keep checking until the pointer has really left.
            while !Task.isCancelled, self?.pointerInside?() == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // A cancelled countdown was already cleared by whoever cancelled it.
            guard !Task.isCancelled, let self else { return }
            self.conceal = nil
            guard self.pulling == nil, !self.dragging, !self.dropTargeting else { return }
            // Once the window passes the mouse through, SwiftUI never hears the
            // hover-out, so an open panel (or a pin) would hold the rail open
            // forever. The pointer has really left: close it here.
            self.collapse?.cancel()
            self.collapse = nil
            self.pinned = nil
            self.active = nil
            self.trace("concealed")
            self.revealed = false
        }
    }

    func togglePin(_ id: String) {
        if pinned == id {
            pinned = nil
            leave(id)
        } else {
            pinned = id
            enter(id)
        }
    }
}

struct NotchRoot: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: PanelState
    var onHitRects: ([CGRect]) -> Void
    var onDropRect: (CGRect) -> Void

    var body: some View {
        RootView(store: store, state: state,
                 onHitRects: onHitRects, onDropRect: onDropRect)
    }
}
