import Foundation

/// Which AI apps are on this Mac. A gauge for one that is not would only ever
/// show a dash, so the rail leaves it out until the app turns up.
struct Installed: Equatable {
    var codex = false
    var grok = false
    var cursor = false

    static func scan() -> Installed {
        Installed(codex: exists(".codex"),
                  grok: app("Grok Bot") || exists("Library/Application Support/Grok Bot"),
                  cursor: app("Cursor") || exists("Library/Application Support/Cursor"))
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
    }

    private static func app(_ name: String) -> Bool {
        ["/Applications", home.appendingPathComponent("Applications").path].contains {
            FileManager.default.fileExists(atPath: "\($0)/\(name).app")
        }
    }
}
