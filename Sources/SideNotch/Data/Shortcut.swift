import AppKit
import SwiftUI

/// An app (or any file) the user dropped onto the rail.
///
/// Stored as a plain path: the app is unsandboxed, so there is no need for a
/// security-scoped bookmark, and a readable path makes the config file editable
/// by hand like everything else here.
struct Shortcut: Identifiable, Codable, Equatable {
    var path: String
    var name: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    init(url: URL) {
        path = url.path
        name = FileManager.default.displayName(atPath: url.path)
    }

    func open() {
        NSWorkspace.shared.open(url)
    }
}

/// `NSWorkspace.icon(forFile:)` hits the disk, and a Shape's body runs often —
/// so resolved icons are kept for the life of the process.
enum ShortcutIcon {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(for shortcut: Shortcut) -> NSImage {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[shortcut.path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: shortcut.path)
        icon.size = NSSize(width: 64, height: 64)
        cache[shortcut.path] = icon
        return icon
    }
}
