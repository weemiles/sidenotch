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

    // Approximate list prices, USD per 1M tokens. Only their *ratios* matter here,
    // since the result is compared against a user-set budget rather than a real quota.
    private struct Price {
        let input: Double, output: Double, write5m: Double, write1h: Double, read: Double
    }
    private static let opus   = Price(input: 15, output: 75, write5m: 18.75, write1h: 30, read: 1.50)
    private static let sonnet = Price(input: 3,  output: 15, write5m: 3.75,  write1h: 6,  read: 0.30)
    private static let haiku  = Price(input: 1,  output: 5,  write5m: 1.25,  write1h: 2,  read: 0.10)

    private static func price(for model: String?) -> Price {
        guard let m = model?.lowercased() else { return sonnet }
        if m.contains("opus") { return opus }
        if m.contains("haiku") { return haiku }
        return sonnet
    }

    private struct Event { let at: Date; let cost: Double; let tokens: Int }

    private let projects = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// How far back events are kept. Needs to exceed the 5h block plus one idle gap
    /// so block boundaries can be found without rescanning history.
    private let lookback: TimeInterval = 12 * 3600
    private let blockLength: TimeInterval = 5 * 3600

    private var cursors: [String: UInt64] = [:]
    private var events: [Event] = []
    private let iso = ISO8601DateFormatter()

    init() {
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let at = iso.date(from: ts) else { return }

        let p = Self.price(for: msg["model"] as? String)
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let read = usage["cache_read_input_tokens"] as? Int ?? 0

        var write5m = 0, write1h = 0
        if let detail = usage["cache_creation"] as? [String: Any] {
            write5m = detail["ephemeral_5m_input_tokens"] as? Int ?? 0
            write1h = detail["ephemeral_1h_input_tokens"] as? Int ?? 0
        }
        if write5m == 0 && write1h == 0 {
            write5m = usage["cache_creation_input_tokens"] as? Int ?? 0
        }

        let cost = (Double(input) * p.input + Double(output) * p.output
                    + Double(write5m) * p.write5m + Double(write1h) * p.write1h
                    + Double(read) * p.read) / 1_000_000
        events.append(Event(at: at, cost: cost, tokens: input + output + read + write5m + write1h))
    }
}
