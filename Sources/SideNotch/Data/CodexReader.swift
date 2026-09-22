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

    /// A session is filed under the day it *started*, so one opened last night and
    /// still running today sits in yesterday's folder while today's folder holds
    /// nothing but a stale short session. Ranking by folder date reads the wrong
    /// file; candidates are compared by the timestamp of their newest record.
    private static let dayLookback = 7
    private static let candidateLimit = 8

    static func read() -> CodexUsage {
        var newest: CodexUsage?
        for url in recentRollouts() {
            guard let usage = lastRecord(in: url), let stamp = usage.updatedAt else { continue }
            if let best = newest, let bestStamp = best.updatedAt, stamp <= bestStamp { continue }
            newest = usage
        }
        return newest ?? CodexUsage()
    }

    private static func lastRecord(in url: URL) -> CodexUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: 0x0A).reversed() {
            guard line.range(of: marker) != nil else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            var usage = CodexUsage()
            usage.primary = window(limits["primary"])
            usage.secondary = window(limits["secondary"])
            usage.planType = limits["plan_type"] as? String
            if let ts = obj["timestamp"] as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                usage.updatedAt = iso.date(from: ts) ?? {
                    let plain = ISO8601DateFormatter()
                    plain.formatOptions = [.withInternetDateTime]
                    return plain.date(from: ts)
                }()
            }
            // A record with no primary window tells us nothing useful.
            return usage.primary == nil ? nil : usage
        }
        return nil
    }

    private static func window(_ raw: Any?) -> CodexWindow? {
        guard let d = raw as? [String: Any],
              let used = d["used_percent"] as? Double else { return nil }
        let resets = (d["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return CodexWindow(
            usedPercent: used,
            windowMinutes: d["window_minutes"] as? Int ?? 0,
            resetsAt: resets
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
