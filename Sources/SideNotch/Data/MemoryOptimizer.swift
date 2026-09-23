import AppKit

/// An app the optimiser would quit, and why.
struct IdleApp: Identifiable {
    enum Reason { case noWindows, idle(minutes: Int) }

    var id: pid_t { app.processIdentifier }
    let app: NSRunningApplication
    let name: String
    let bundlePath: String?
    let bytes: UInt64
    let reason: Reason
}

/// Frees memory the only way an unprivileged app can: by quitting apps that are
/// not being used. `purge` needs root and only drops file cache, which the
/// "used" figure never counted in the first place.
///
/// "Not being used" means no windows at all, or not brought forward for a while.
/// macOS keeps no record of when an app was last active, so this watches
/// activations from launch; an app not seen since then counts from launch.
@MainActor
final class MemoryOptimizer {
    static let shared = MemoryOptimizer()

    /// How long an app can sit in the background before it counts as unused.
    static let idleAfter: TimeInterval = 30 * 60

    private let launchedAt = Date()
    private var lastActive: [pid_t: Date] = [:]
    private var observer: NSObjectProtocol?

    /// Quitting these costs more than it frees: the Finder relaunches itself,
    /// and a terminal takes every running session — Claude Code included — down
    /// with it.
    private static let keep: Set<String> = [
        "com.apple.finder",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "org.alacritty",
        "net.kovidgoyal.kitty",
    ]

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in MemoryOptimizer.shared.lastActive[pid] = Date() }
        }
    }

    func candidates() -> [IdleApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windowed = pidsWithWindows()
        let footprints = Dictionary(
            MemoryReader.hogs(limit: .max).compactMap { hog in hog.bundlePath.map { ($0, hog.bytes) } },
            uniquingKeysWith: +)
        let now = Date()

        return NSWorkspace.shared.runningApplications.compactMap { app -> IdleApp? in
            let pid = app.processIdentifier
            guard app.activationPolicy == .regular, !app.isTerminated,
                  pid != me, pid != front,
                  !Self.keep.contains(app.bundleIdentifier ?? "") else { return nil }

            let reason: IdleApp.Reason
            if !windowed.contains(pid) {
                reason = .noWindows
            } else {
                let since = now.timeIntervalSince(lastActive[pid] ?? launchedAt)
                guard since >= Self.idleAfter else { return nil }
                reason = .idle(minutes: Int(since / 60))
            }
            let bundle = app.bundleURL?.path
            return IdleApp(app: app,
                           name: app.localizedName ?? bundle.map { ($0 as NSString).lastPathComponent } ?? "?",
                           bundlePath: bundle,
                           bytes: bundle.flatMap { footprints[$0] } ?? 0,
                           reason: reason)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Asked, not forced: an app with unsaved work still gets to say so.
    func quit(_ apps: [IdleApp]) {
        apps.forEach { $0.app.terminate() }
    }

    /// Windows on every Space and minimised ones included — an app whose only
    /// window is on another desktop is still in use. Tiny and off-layer windows
    /// are the invisible helpers many apps keep and do not count.
    private func pidsWithWindows() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: Set<pid_t> = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 100, (bounds["Height"] ?? 0) >= 100 else { continue }
            out.insert(pid)
        }
        return out
    }
}
