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
    /// The Meetily record button. It lives in this list so it can be
    /// reordered like any icon, but it is drawn and acts differently.
    static let recorderPath = "sidenotch:meetily-record"
    var isRecorder: Bool { path == Self.recorderPath }
    static var recorder: Shortcut { Shortcut(path: recorderPath, name: "Meetily") }
    var url: URL {
        isWeb ? (URL(string: path) ?? URL(fileURLWithPath: path)) : URL(fileURLWithPath: path)
    }
    var exists: Bool { isRecorder || isWeb || FileManager.default.fileExists(atPath: path) }

    init(url: URL) {
        path = url.path
        name = FileManager.default.displayName(atPath: url.path)
    }

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    func open() {
        if !isWeb, url.pathExtension.lowercased() == "app" {
            AppLauncher.open(url)
            return
        }
        let appURL = app.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? NSWorkspace.shared.urlForApplication(toOpen: url)
        guard isWeb, let appURL,
              let bundleID = Bundle(url: appURL)?.bundleIdentifier,
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        else { return openNew(using: appURL) }

        // A double click must not race two lookups into opening two tabs.
        BrowserShortcutQueue.perform(key: path) {
            let result = Self.focusBrowserTab(matching: self.url, bundleID: bundleID)
            DispatchQueue.main.async {
                switch result {
                case .focused: break
                case .notFound: self.openNew(using: appURL)
                case .unavailable:
                    // If Automation is unavailable, keep the existing browser
                    // visible rather than silently creating a duplicate tab.
                    AppLauncher.open(appURL)
                }
            }
        }
    }

    private func openNew(using appURL: URL?) {
        guard let appURL else { NSWorkspace.shared.open(url); return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }

    private enum TabFocusResult { case focused, notFound, unavailable }

    private static func focusBrowserTab(matching url: URL, bundleID: String) -> TabFocusResult {
        let safari = bundleID == "com.apple.Safari"
        let chromium = ["com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
                        "com.brave.Browser", "org.chromium.Chromium"].contains(bundleID)
        guard safari || chromium, let host = url.host?.lowercased() else { return .unavailable }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        // Image generation moves into /c/<conversation-id>. Treat that tab as
        // the existing web app rather than requiring the /images landing page.
        if bareHost == "chatgpt.com", path == "/images" || path.hasPrefix("/images/") {
            path = ""
        }
        let prefixes = ["https://", "http://"].flatMap { scheme in
            [scheme + bareHost + path, scheme + "www." + bareHost + path]
        }
        let candidates = prefixes.map { "\"" + appleScriptString($0) + "\"" }.joined(separator: ", ")
        let selection = safari ? "set current tab of w to t" : "set active tab index of w to tabNumber"
        let source = """
        on siteMatches(address, prefixes)
          if address is missing value then return false
          repeat with prefix in prefixes
            set p to contents of prefix
            if address starts with p then
              if (length of address) = (length of p) then return true
              set boundary to character ((length of p) + 1) of address
              if boundary is in {"/", "?", "#"} then return true
            end if
          end repeat
          return false
        end siteMatches
        tell application id "\(appleScriptString(bundleID))"
          repeat with w in windows
            set tabNumber to 0
            repeat with t in tabs of w
              set tabNumber to tabNumber + 1
              if my siteMatches(URL of t, {\(candidates)}) then
                \(selection)
                try
                  set miniaturized of w to false
                end try
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
        guard error == nil, let result else { return .unavailable }
        return result.booleanValue ? .focused : .notFound
    }

    private static func appleScriptString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

/// Use activation for a running app; an open/reopen event can create a window.
enum AppLauncher {
    static func open(_ url: URL) {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        let bundleID = Bundle(url: target)?.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.first { app in
            guard !app.isTerminated else { return false }
            return app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
                || (bundleID != nil && app.bundleIdentifier == bundleID)
        }
        if let running {
            running.activate(options: [])
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: target, configuration: config)
    }
}

private enum BrowserShortcutQueue {
    private static let queue = DispatchQueue(label: "sidenotch.browser-shortcut")
    private static var lastRequests: [String: Date] = [:]
    static func perform(key: String, _ action: @escaping () -> Void) {
        queue.async {
            let now = Date()
            if let last = lastRequests[key], now.timeIntervalSince(last) < 1 { return }
            lastRequests[key] = now
            action()
        }
    }
}
