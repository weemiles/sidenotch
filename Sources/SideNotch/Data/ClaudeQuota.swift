import CryptoKit
import Foundation

/// One limit as the account itself reports it — the numbers `/usage` shows.
struct ClaudeLimit: Equatable {
    /// "session", "weekly_all", "weekly_scoped", …
    var kind: String
    /// Set for a limit that only applies to one model ("Fable").
    var model: String?
    var usedPercent: Double
    var resetsAt: Date?

    var remaining: Double { max(0, min(1, 1 - usedPercent / 100)) }

    var label: String {
        switch kind {
        case "session": return L.hours(5)
        case "weekly_all": return L.weekly
        default: return model.map { "\($0) \(L.weekly)" } ?? L.weekly
        }
    }
}

struct ClaudeQuota: Equatable {
    var limits: [ClaudeLimit]
    var fetchedAt: Date

    /// False once any window in the reading has rolled over: the numbers
    /// described a window that no longer exists.
    var isCurrent: Bool {
        limits.compactMap(\.resetsAt).allSatisfy { $0 > Date() }
    }

    /// The weekly allowance across all models: the gauge is there to answer how
    /// much of this week is left. The five-hour window refills within the day and
    /// a model-scoped limit only stops that one model, so both go in the panel.
    /// Should an account report no weekly limit, the tightest one stands in.
    var headline: ClaudeLimit? {
        limits.first { $0.kind == "weekly_all" }
            ?? limits.min { $0.remaining < $1.remaining }
    }

    var others: [ClaudeLimit] {
        guard let headline else { return [] }
        return limits.filter { $0 != headline }
    }
}

/// Asks Anthropic for the account's real limits, using the login Claude Code
/// already holds in the keychain.
///
/// The credential is only ever read: never stored, never logged, never
/// refreshed. Refreshing would rotate the refresh token out from under Claude
/// Code, so an expired one just means no reading until Claude Code renews it,
/// and the gauge falls back to the transcript estimate in the meantime.
enum ClaudeQuotaReader {

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// What Claude Code itself last read from this same endpoint, kept in its
    /// state file. Free, and beyond the reach of the rate limit: every session
    /// on the account refreshes it, so it stands in whenever the endpoint turns
    /// us away.
    static func cached(_ account: ClaudeAccount) -> ClaudeQuota? {
        guard let data = try? Data(contentsOf: ClaudeAccounts.stateFile(for: account.configDir)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = obj["cachedUsageUtilization"] as? [String: Any],
              let fetched = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let windows = cache["utilization"] as? [String: Any] else { return nil }

        let iso = isoFormatter()
        let limits = windowKinds.compactMap { window -> ClaudeLimit? in
            guard let row = windows[window.key] as? [String: Any],
                  let percent = (row["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return ClaudeLimit(kind: window.kind, model: window.model, usedPercent: percent,
                               resetsAt: (row["resets_at"] as? String).flatMap(iso.date(from:)))
        }
        guard !limits.isEmpty else { return nil }
        return ClaudeQuota(limits: limits, fetchedAt: Date(timeIntervalSince1970: fetched / 1000))
    }

    /// The state file names its windows differently from the endpoint; these are
    /// the ones that mean the same thing. Anything else there is a limit this
    /// gauge has no vocabulary for, so it is left out.
    private static let windowKinds: [(key: String, kind: String, model: String?)] = [
        ("five_hour", "session", nil),
        ("seven_day", "weekly_all", nil),
        ("seven_day_opus", "weekly_scoped", "Opus"),
        ("seven_day_sonnet", "weekly_scoped", "Sonnet"),
    ]

    private static func isoFormatter() -> ISO8601DateFormatter {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso
    }

    static func read(_ account: ClaudeAccount) -> ClaudeQuota? {
        guard let token = accessToken(for: account),
              let data = get(token: token),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["limits"] as? [[String: Any]] else { return nil }

        let iso = isoFormatter()
        let limits = rows.compactMap { row -> ClaudeLimit? in
            guard let kind = row["kind"] as? String,
                  let percent = (row["percent"] as? NSNumber)?.doubleValue else { return nil }
            let scope = row["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            return ClaudeLimit(kind: kind, model: model, usedPercent: percent,
                               resetsAt: (row["resets_at"] as? String).flatMap(iso.date(from:)))
        }
        guard !limits.isEmpty else { return nil }
        return ClaudeQuota(limits: limits, fetchedAt: Date())
    }

    // MARK: Keychain

    /// Claude Code names the item after the config directory it was pointed at:
    /// the default directory gets the bare name, any other gets the first eight
    /// hex digits of the SHA-256 of its path appended.
    private static func service(for account: ClaudeAccount) -> String {
        let base = "Claude Code-credentials"
        let dir = account.configDir.path
        guard dir != ClaudeAccounts.defaultConfigDir.path else { return base }
        return "\(base)-\(String(sha256Hex(dir).prefix(8)))"
    }

    /// Through `/usr/bin/security` rather than the Security framework: Claude
    /// Code writes the item with that tool, so the tool is already on the item's
    /// access list and reading it raises no keychain prompt.
    private static func accessToken(for account: ClaudeAccount) -> String? {
        guard let out = run("/usr/bin/security",
                            ["find-generic-password", "-s", service(for: account), "-w"]),
              let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expires / 1000) < Date() { return nil }
        return token
    }

    // MARK: Plumbing

    /// Synchronous on purpose: this only ever runs on the store's scan queue.
    private static func get(token: String) -> Data? {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
