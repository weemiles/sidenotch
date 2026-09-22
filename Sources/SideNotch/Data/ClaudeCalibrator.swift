import Foundation

/// Works out what a full 5-hour window costs *for this machine's account*.
///
/// Claude Code never records how much quota is left, so the gauge needs a
/// denominator. A number baked into the app is meaningless to anyone else who
/// installs it — their plan and their habits are not the author's — so it is
/// derived from their own history instead.
///
/// Two signals, best first:
///  1. Windows that actually got refused. Claude Code writes a `five_hour`
///     rejection with the reset time, and the weighted spend in the window
///     ending there is, near enough, where that account runs out.
///  2. Failing that, the 90th percentile of their own windows: high enough that
///     an ordinary session stays green, low enough that the gauge still moves.
enum ClaudeCalibrator {

    private static let projects = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")
    private static let lookbackDays = 14
    private static let blockLength: TimeInterval = 5 * 3600
    /// Enough that a brand-new install is not pinned at empty on its first day.
    private static let floor: Double = 25

    struct Event { let at: Date; let cost: Double }

    static func derive(now: Date = Date()) -> Double? {
        let horizon = now.addingTimeInterval(-Double(lookbackDays) * 24 * 3600)
        var events: [Event] = []
        var refusals: Set<Int> = []

        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate, mtime > horizon,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.readToEnd() else { continue }

            for line in data.split(separator: 0x0A) {
                scan(line, iso: iso, horizon: horizon, events: &events, refusals: &refusals)
            }
        }

        guard !events.isEmpty else { return nil }
        events.sort { $0.at < $1.at }

        if let fromRefusals = budget(fromRefusals: refusals, events: events) {
            return max(floor, fromRefusals)
        }
        return max(floor, percentile(0.9, of: blocks(from: events).map(\.cost)) ?? floor)
    }

    private static func scan(_ line: Data, iso: ISO8601DateFormatter, horizon: Date,
                             events: inout [Event], refusals: inout Set<Int>) {
        if line.range(of: Data("\"five_hour\"".utf8)) != nil,
           line.range(of: Data("\"rejected\"".utf8)) != nil,
           let text = String(data: line, encoding: .utf8),
           let marker = text.range(of: "\"resetsAt\":") {
            let digits = text[marker.upperBound...].prefix { $0.isNumber }
            if let seconds = Int(digits) { refusals.insert(seconds) }
        }

        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              line.range(of: Data("\"assistant\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String,
              let at = iso.date(from: stamp), at > horizon else { return }

        let weighed = ClaudePricing.weigh(usage: usage, model: message["model"] as? String)
        events.append(Event(at: at, cost: weighed.cost))
    }

    /// Spend in each window that ended in a refusal. The median of those is the
    /// steadiest read on where this account actually stops.
    private static func budget(fromRefusals refusals: Set<Int>, events: [Event]) -> Double? {
        guard !refusals.isEmpty else { return nil }
        let spends = refusals.map { seconds -> Double in
            let reset = Date(timeIntervalSince1970: Double(seconds))
            let start = reset.addingTimeInterval(-blockLength)
            return events.filter { $0.at >= start && $0.at < reset }
                .reduce(0) { $0 + $1.cost }
        }.filter { $0 > 0 }
        guard !spends.isEmpty else { return nil }
        return percentile(0.5, of: spends)
    }

    /// ccusage-style blocks: a new one starts on the hour after a 5-hour gap.
    private static func blocks(from events: [Event]) -> [(start: Date, cost: Double)] {
        var out: [(start: Date, cost: Double)] = []
        var lastAt: Date?
        for e in events {
            let needsNew = out.isEmpty
                || e.at.timeIntervalSince(out[out.count - 1].start) >= blockLength
                || (lastAt.map { e.at.timeIntervalSince($0) >= blockLength } ?? false)
            if needsNew {
                let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: e.at)
                out.append((Calendar.current.date(from: c) ?? e.at, 0))
            }
            out[out.count - 1].cost += e.cost
            lastAt = e.at
        }
        return out
    }

    private static func percentile(_ p: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }
}
