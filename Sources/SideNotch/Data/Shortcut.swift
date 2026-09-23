import AppKit
import SwiftUI

/// An app (or any file) the user dropped onto the rail.
///
/// Stored as a plain path: the app is unsandboxed, so there is no need for a
/// security-scoped bookmark, and a readable path makes the config file editable
/// by hand like everything else here.
struct Shortcut: Identifiable, Codable, Equatable {
    /// A file path, or an `http(s)` address for a web app with no app bundle.
    var path: String
    var name: String
    /// Image file drawn instead of Finder's icon — a web address has none.
    /// `~` is expanded. Set by hand in the config file.
    var icon: String?
    /// App to open `path` with instead of the default handler — for a web
    /// address, the browser actually in use. `~` is expanded.
    var app: String?

    var id: String { path }
    var isWeb: Bool { path.hasPrefix("https://") || path.hasPrefix("http://") }
    var url: URL {
        isWeb ? (URL(string: path) ?? URL(fileURLWithPath: path)) : URL(fileURLWithPath: path)
    }
    var exists: Bool { isWeb || FileManager.default.fileExists(atPath: path) }

    init(url: URL) {
        path = url.path
        name = FileManager.default.displayName(atPath: url.path)
    }

    func open() {
        guard let app else {
            NSWorkspace.shared.open(url)
            return
        }
        let appURL = URL(fileURLWithPath: (app as NSString).expandingTildeInPath)
        let url = url
        let launch = {
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        guard isWeb, Bundle(url: appURL)?.bundleIdentifier == "com.apple.Safari",
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
        else { return launch() }
        // A web app the user already has open is brought forward, not opened
        // again in a new tab. Apple Events block, so this stays off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            if !Self.focusSafariTab(matching: url) { launch() }
        }
    }

    /// Selects the first Safari tab on the same site (and under the same path,
    /// so chatgpt.com/images does not grab an unrelated chat) and raises its window.
    private static func focusSafariTab(matching url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        let bare = "://\(host)\(path)", www = "://www.\(host)\(path)"
        let source = """
        tell application "Safari"
          repeat with w in windows
            repeat with t in tabs of w
              set u to URL of t
              if u is not missing value and (u contains "\(bare)" or u contains "\(www)") then
                set current tab of w to t
                if miniaturized of w then set miniaturized of w to false
                set index of w to 1
                activate
                return true
              end if
            end repeat
          end repeat
        end tell
        return false
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }
}

/// `NSWorkspace.icon(forFile:)` hits the disk, and a Shape's body runs often —
/// so resolved icons are kept for the life of the process.
enum ShortcutIcon {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(for shortcut: Shortcut) -> NSImage {
        if let icon = shortcut.icon {
            let file = (icon as NSString).expandingTildeInPath
            lock.lock(); defer { lock.unlock() }
            if let hit = cache[file] { return hit }
            if let image = NSImage(contentsOfFile: file) {
                cache[file] = image
                return image
            }
        }
        return image(forPath: shortcut.path)
    }

    static func image(forPath path: String) -> NSImage {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        cache[path] = icon
        return icon
    }
}

extension MemoryHog {
    /// An app is asked to quit, so it can still offer to save. Anything else
    /// gets SIGTERM, which it can likewise catch and clean up after.
    func quit() {
        if let bundlePath {
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.bundleURL?.path == bundlePath }
            if !apps.isEmpty {
                apps.forEach { $0.terminate() }
                return
            }
        }
        pids.forEach { kill($0, SIGTERM) }
    }
}
