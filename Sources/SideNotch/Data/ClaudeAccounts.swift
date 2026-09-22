import Foundation

/// One Claude Code login.
///
/// A machine can hold several: `CLAUDE_CONFIG_DIR` points a terminal at its own
/// config directory, and each directory gets its own credential. The transcripts
/// carry no account marker of any kind, so the directory they land in is the
/// only thing that tells two accounts apart — which is why the accounts are
/// identified by directory here rather than by anything read out of the logs.
struct ClaudeAccount: Identifiable, Equatable {
    let configDir: URL
    /// What the rail shows beside the gauge: "1", "2", … in discovery order.
    let label: String
    /// Shown in the panel so the number can be matched to an actual login.
    let email: String?

    var id: String { configDir.path }
    var projects: URL { configDir.appendingPathComponent("projects") }
}

enum ClaudeAccounts {

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static var defaultConfigDir: URL { home.appendingPathComponent(".claude") }

    /// `~/.claude` first, then any `~/.claude-*` beside it, in name order.
    /// One account is the normal case and gets no label at all.
    static func discover(configured: [String]?) -> [ClaudeAccount] {
        let dirs = configured.map { $0.map { expand($0) } } ?? found()
        let multiple = dirs.count > 1
        return dirs.enumerated().map { index, dir in
            ClaudeAccount(configDir: dir,
                          label: multiple ? "\(index + 1)" : "",
                          email: email(in: dir))
        }
    }

    private static func found() -> [URL] {
        var out = [defaultConfigDir]
        let fm = FileManager.default
        let siblings = (try? fm.contentsOfDirectory(at: home,
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [])) ?? []
        out += siblings
            .filter { $0.lastPathComponent.hasPrefix(".claude-") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            // A directory only counts once something has actually logged in
            // there; an empty one would sit on the rail as a permanent dash.
            // `projects` appears on the first session, `.claude.json` at login,
            // so a freshly added account shows up straight away.
            .filter { dir in
                ["projects", ".claude.json"].contains {
                    fm.fileExists(atPath: dir.appendingPathComponent($0).path)
                }
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return out
    }

    /// Claude Code keeps `.claude.json` inside the config directory — except for
    /// the default one, whose copy sits in the home directory instead.
    static func stateFile(for configDir: URL) -> URL {
        configDir.standardizedFileURL == defaultConfigDir.standardizedFileURL
            ? home.appendingPathComponent(".claude.json")
            : configDir.appendingPathComponent(".claude.json")
    }

    private static func email(in configDir: URL) -> String? {
        guard let data = try? Data(contentsOf: stateFile(for: configDir)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
