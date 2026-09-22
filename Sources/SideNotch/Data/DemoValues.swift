import Foundation

/// Fixed readings for screen recordings and screenshots.
///
/// `SIDENOTCH_DEMO=89,24` shows 89% left for Claude and 24% for Codex. Nothing
/// is read from disk while it is set, so the numbers hold still for a take.
struct DemoValues {
    let claudeRemaining: Double
    let codexRemaining: Double

    static let current: DemoValues? = {
        guard let raw = ProcessInfo.processInfo.environment["SIDENOTCH_DEMO"] else { return nil }
        let parts = raw.split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return DemoValues(claudeRemaining: parts[0] / 100, codexRemaining: parts[1] / 100)
    }()

    func claude(budget: Double) -> ClaudeUsage {
        var usage = ClaudeUsage()
        usage.budgetUSD = budget
        usage.costUSD = budget * (1 - claudeRemaining)
        let start = Calendar.current.date(
            bySetting: .minute, value: 0, of: Date().addingTimeInterval(-2 * 3600)) ?? Date()
        usage.windowStart = start
        usage.windowEnd = start.addingTimeInterval(5 * 3600)
        usage.totalTokens = Int(usage.costUSD * 120_000)
        return usage
    }

    var codex: CodexUsage {
        var usage = CodexUsage()
        usage.primary = CodexWindow(
            usedPercent: (1 - codexRemaining) * 100,
            windowMinutes: 10080,
            resetsAt: Date().addingTimeInterval(3.5 * 24 * 3600)
        )
        return usage
    }
}
