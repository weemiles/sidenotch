import Foundation

// MARK: - Claude

/// Where the denominator behind the Claude gauge came from. The spend is always
/// an estimate; what varies is whether the limit it is measured against was
/// observed or guessed, and the panel says which.
enum ClaudeBudgetBasis: String, Codable, Equatable {
    /// Windows this account was actually refused in.
    case refusals
    /// Its own busiest window — nothing has been refused yet, so this is a
    /// lower bound on the real limit, not the limit.
    case history
    /// Pinned in config by the user.
    case manual
}

struct ClaudeUsage: Equatable, Identifiable {
    /// The account's config directory path — the only thing that distinguishes
    /// two logins on one machine, since the transcripts never say.
    var id: String = ""
    /// "1", "2", … or empty when there is only one account to show.
    var label: String = ""
    var email: String?

    /// Start of the current 5-hour block, floored to the hour (ccusage convention).
    var windowStart: Date?
    var windowEnd: Date?
    /// Price-weighted spend in the current window. An estimate, not the real quota.
    var costUSD: Double = 0
    var totalTokens: Int = 0
    var budgetUSD: Double = 150
    /// `nil` until the first calibration lands, which is the one state where a
    /// percentage would be a number made up out of nothing.
    var budgetBasis: ClaudeBudgetBasis?
    var budgetSamples: Int = 0

    var usedFraction: Double {
        guard budgetUSD > 0 else { return 0 }
        return min(1, costUSD / budgetUSD)
    }

    /// Everything on screen is expressed as what is left, battery-style.
    var remaining: Double { 1 - usedFraction }
    var remainingUSD: Double { max(0, budgetUSD - costUSD) }

}

// MARK: - Codex

struct CodexWindow: Equatable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
    var updatedAt: Date?

    var remaining: Double { max(0, min(1, 1 - usedPercent / 100)) }

    var label: String {
        if windowMinutes >= 43200 { return L.monthly }
        if windowMinutes >= 10080 { return L.weekly }
        if windowMinutes >= 1440 { return L.days(windowMinutes / 1440, 0) }
        if windowMinutes >= 60 { return L.hours(windowMinutes / 60) }
        return L.minutes(windowMinutes)
    }
}

struct CodexUsage: Equatable {
    /// The newest reading for each window Codex reports — five-hour, weekly,
    /// monthly. Which one lands in `primary` varies between records, so they are
    /// all kept and compared rather than trusting whichever came first.
    var windows: [CodexWindow] = []
    var planType: String?
    var updatedAt: Date?

    /// The binding constraint: whichever window has the least left is the one
    /// about to stop you, so that is the number worth showing.
    var headline: CodexWindow? {
        windows.min { $0.remaining < $1.remaining }
    }

    var others: [CodexWindow] {
        guard let headline else { return [] }
        return windows
            .filter { $0.windowMinutes != headline.windowMinutes }
            .sorted { $0.remaining < $1.remaining }
    }

    var remaining: Double { headline?.remaining ?? 1 }
}

// MARK: - Formatting helpers

enum Fmt {
    static func percent(_ f: Double) -> String {
        "\(Int((f * 100).rounded()))%"
    }

    static func usd(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.1f", v)
    }

    /// "2시간 14분" / "38분" / "곧"
    static func remaining(until date: Date?, from now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = Int(date.timeIntervalSince(now))
        guard s > 0 else { return L.soon }
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return L.days(h / 24, h % 24) }
        if h > 0 { return L.hoursMinutes(h, m) }
        return L.minutes(m)
    }

    /// "9/27(일) 14:33" — the weekday is what makes a reset five days out legible.
    static func resetStamp(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: L.localeIdentifier)
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : L.dateFormat
        return f.string(from: date)
    }

    static func ago(_ date: Date, from now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 10 { return L.justNow }
        if s < 60 { return L.secondsAgo(s) }
        if s < 3600 { return L.minutesAgo(s / 60) }
        return L.hoursAgo(s / 3600)
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
