import Foundation

/// Reads Codex CLI rollout logs.
///
/// Unlike Claude Code, Codex records the server's own verdict on every turn:
/// `payload.rate_limits.primary = { used_percent, window_minutes, resets_at }`.
/// So this number is exact — no estimation involved.
enum CodexReader {

    private static let sessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    /// Only the tail is read; rate limit records appear on every turn, so the most
    /// recent one is always within a few kilobytes of the end.
    private static let tailBytes: UInt64 = 256 * 1024
    /// Cap on records parsed per file, so a 2-second poll stays cheap.
    private static let recordsPerFile = 25

    /// A session is filed under the day it *started*, so one opened last night and
    /// still running today sits in yesterday's folder while today's folder holds
    /// nothing but a stale short session. Ranking by folder date reads the wrong
    /// file; candidates are compared by the timestamp of their newest record.
    private static let dayLookback = 7
    private static let candidateLimit = 8

    /// Which window lands in `primary` is not stable — the same account produces
    /// records whose primary is the five-hour window, the weekly one or the
    /// monthly one. Reading only `primary` therefore shows whichever window the
    /// last request happened to report, which is how a full weekly quota can
    /// display as nearly empty. Every window is collected instead, keeping the
    /// newest reading of each.
    static func read() -> CodexUsage {
        var newest: [Int: CodexWindow] = [:]
        var planType: String?
        var latest: Date?

        for url in recentRollouts() {
            for record in records(in: url) {
                for window in record.windows {
                    let known = newest[window.windowMinutes]
                    if known == nil || (window.updatedAt ?? .distantPast)
                        > (known?.updatedAt ?? .distantPast) {
                        newest[window.windowMinutes] = window
                    }
                }
                if let stamp = record.stamp, stamp > (latest ?? .distantPast) {
                    latest = stamp
                    planType = record.planType
                }
            }
        }

        var usage = CodexUsage()
        usage.windows = newest.values.sorted { $0.windowMinutes < $1.windowMinutes }
        usage.planType = planType
        usage.updatedAt = latest

        if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
            let detail = usage.windows
                .map { "\($0.windowMinutes)m=\(Int($0.usedPercent))%used" }
                .joined(separator: " ")
            // Same rounding as the UI, or the log contradicts the screen by a point.
            let shown = Fmt.percent(usage.headline?.remaining ?? 0)
            let line = "codex: \(detail) -> showing \(shown) left\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return usage
    }

    private struct Record {
        var windows: [CodexWindow]
        var planType: String?
        var stamp: Date?
    }

    /// Walks a file's tail backwards. Records are written every turn, so the last
    /// handful covers every window; the cap keeps a 2-second poll cheap.
    private static func records(in url: URL) -> [Record] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return [] }

        let marker = Data("\"rate_limits\"".utf8)
        var out: [Record] = []
        var seenWindows = Set<Int>()

        for line in data.split(separator: 0x0A).reversed() {
            guard out.count < recordsPerFile else { break }
            guard line.range(of: marker) != nil else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            let stamp = (obj["timestamp"] as? String).flatMap(date(from:))
            let windows = [limits["primary"], limits["secondary"]]
                .compactMap { window($0, stamp: stamp) }
            guard !windows.isEmpty else { continue }

            out.append(Record(windows: windows,
                              planType: limits["plan_type"] as? String,
                              stamp: stamp))
            windows.forEach { seenWindows.insert($0.windowMinutes) }
            // Nothing new is coming once every window has been seen a few times.
            if seenWindows.count >= 3 && out.count >= 4 { break }
        }
        return out
    }

    private static func date(from iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    private static func window(_ raw: Any?, stamp: Date?) -> CodexWindow? {
        guard let d = raw as? [String: Any],
              let used = d["used_percent"] as? Double,
              let minutes = d["window_minutes"] as? Int, minutes > 0 else { return nil }
        return CodexWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: (d["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
            updatedAt: stamp
        )
    }

    /// The most recently written rollouts across the last few day folders.
    private static func recentRollouts() -> [URL] {
        let fm = FileManager.default
        let cal = Calendar.current
        var found: [(url: URL, modified: Date)] = []

        for dayOffset in 0..<dayLookback {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let dir = sessions
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                found.append((file, modified))
            }
        }

        return found.sorted { $0.modified > $1.modified }
            .prefix(candidateLimit)
            .map(\.url)
    }
}
