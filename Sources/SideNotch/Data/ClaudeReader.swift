import Foundation

/// Reads Claude Code's own local logs.
///
/// Two very different sources:
///  - `~/.claude/sessions/*.json`   tiny, authoritative, live session status
///  - `~/.claude/projects/**/*.jsonl`  append-only transcripts carrying per-message token usage
///
/// The transcripts are hundreds of megabytes, so the scan is incremental: each file
/// is remembered by byte offset and only the freshly appended bytes are parsed.
final class ClaudeLogScanner {

    private struct Event { let at: Date; let cost: Double; let tokens: Int }

    /// Which account's transcripts this scanner watches. One per account: the
    /// byte cursors are per file, so two accounts cannot share an instance.
    private let projects: URL

    /// How far back events are kept. Needs to exceed the 5h block plus one idle gap
    /// so block boundaries can be found without rescanning history.
    private let lookback: TimeInterval = 12 * 3600
    private let blockLength: TimeInterval = 5 * 3600

    private var cursors: [String: UInt64] = [:]
    private var events: [Event] = []
    private let iso = ISO8601DateFormatter()
    /// Set when a five-hour refusal turns up in freshly appended bytes.
    private var refusalSeen = false

    init(projects: URL) {
        self.projects = projects
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Reads and clears the refusal flag. A refusal is the account telling you
    /// exactly where its ceiling is, so it is worth re-deriving the budget on
    /// the spot rather than waiting for the next daily pass.
    func takeRefusal() -> Bool {
        defer { refusalSeen = false }
        return refusalSeen
    }

    // MARK: Token window

    /// Parses whatever has been appended since the last call and returns the
    /// current 5-hour block, or nil when the last block has already expired.
    func refreshWindow(now: Date = Date()) -> (start: Date, end: Date, cost: Double, tokens: Int)? {
        ingestNewBytes(now: now)
        events.removeAll { $0.at < now.addingTimeInterval(-lookback) }
        events.sort { $0.at < $1.at }

        var blocks: [(start: Date, cost: Double, tokens: Int)] = []
        var lastAt: Date?
        for e in events {
            let needsNewBlock = blocks.isEmpty
                || e.at.timeIntervalSince(blocks[blocks.count - 1].start) >= blockLength
                || (lastAt.map { e.at.timeIntervalSince($0) >= blockLength } ?? false)
            if needsNewBlock { blocks.append((floorToHour(e.at), 0, 0)) }
            blocks[blocks.count - 1].cost += e.cost
            blocks[blocks.count - 1].tokens += e.tokens
            lastAt = e.at
        }

        guard let last = blocks.last else { return nil }
        let end = last.start.addingTimeInterval(blockLength)
        guard now < end else { return nil }
        return (last.start, end, last.cost, last.tokens)
    }

    private func floorToHour(_ d: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d)
        return Calendar.current.date(from: c) ?? d
    }

    private func ingestNewBytes(now: Date) {
        let fm = FileManager.default
        let horizon = now.addingTimeInterval(-lookback)
        guard let walker = fm.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }

        var seen = Set<String>()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate, mtime > horizon else { continue }
            seen.insert(url.path)
            ingest(url)
        }
        // Forget files that dropped out of the window so the map cannot grow forever.
        cursors = cursors.filter { seen.contains($0.key) }
    }

    private func ingest(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let start = cursors[url.path] ?? 0
        guard let end = try? handle.seekToEnd() else { return }
        if end <= start {
            // File was truncated or replaced; start over.
            if end < start { cursors[url.path] = 0 }
            return
        }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        var consumed = start
        var lineStart = data.startIndex
        while let nl = data[lineStart...].firstIndex(of: 0x0A) {
            let line = data[lineStart..<nl]
            consumed += UInt64(line.count + 1)
            lineStart = data.index(after: nl)
            parse(line)
        }
        cursors[url.path] = consumed
    }

    private func parse(_ line: Data) {
        guard line.count > 60 else { return }
        // Cheap pre-filter before paying for JSON parsing.
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              line.range(of: Data("\"assistant\"".utf8)) != nil else { return }
        // A refusal record is itself an assistant turn, so it clears the filter
        // above and is picked up below.
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if ClaudeCalibrator.isRefusal(obj) { refusalSeen = true }

        guard obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let at = iso.date(from: ts) else { return }

        let weighed = ClaudePricing.weigh(usage: usage, model: msg["model"] as? String)
        events.append(Event(at: at, cost: weighed.cost, tokens: weighed.tokens))
    }
}
