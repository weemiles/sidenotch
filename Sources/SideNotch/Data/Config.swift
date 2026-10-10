import Foundation

/// User-editable settings. Lives at ~/.config/sidenotch/config.json and is
/// re-read whenever the file changes, so edits apply without a restart.
struct Config: Codable, Equatable {
    /// What a full 5-hour window costs on this account. `nil` — the default —
    /// works it out from your own history, which is the only way the gauge means
    /// anything on someone else's machine. Set a number to pin it.
    var claudeFiveHourBudgetUSD: Double?

    /// Which Claude config directories to watch, one per account. `nil` — the
    /// default — finds `~/.claude` and any `~/.claude-*` beside it, which is
    /// where a second `CLAUDE_CONFIG_DIR` login keeps its transcripts.
    var claudeConfigDirs: [String]?

    /// Last auto-derived budget per config directory, so the scan runs once a
    /// day at most and the panel can say how much to trust each figure. Keyed
    /// by directory because two accounts on one machine have two limits.
    var claudeBudgetAuto: [String: AutoBudget] = [:]

    /// Seconds between cheap polls (live sessions, Codex tail).
    var fastPollSeconds: Double = 2
    /// Seconds between the expensive poll (Claude token log scan).
    var slowPollSeconds: Double = 20

    var showClaude: Bool = true
    var showCodex: Bool = true
    var showGrok: Bool = true
    var showCursor: Bool = true
    var showMemory: Bool = true

    /// Day of the month each plan renews, for the accounts that do not say:
    /// "codex", and "claude" — or "claude1", "claude2" when there are several.
    /// Grok Bot and Cursor report their own billing cycle.
    var billingDays: [String: Int] = [:]

    /// Display the rail sits on. nil = the primary screen.
    var displayID: UInt32? = nil

    /// Which screen edge the notch is docked to.
    var edge: NotchEdge = .left

    /// Position along that edge. 0 = start (top or left), 1 = end. 0.5 centres it.
    var anchor: Double = 0.5

    /// Hide inside the MacBook's camera notch and grow out of it only while the
    /// pointer is on it. Implies the top edge, centred on the notch.
    var notchMode: Bool = false

    /// Apps dropped onto the rail, in the order they appear.
    var shortcuts: [Shortcut] = []

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sidenotch/config.json")

    /// Kept only so an older config file still decodes.
    private var verticalAnchor: Double?

    struct AutoBudget: Codable, Equatable {
        var usd: Double
        var at: Date
        var basis: ClaudeBudgetBasis
        var samples: Int
    }

    /// Whatever the gauge should divide by for this account right now.
    func effectiveBudgetUSD(for account: ClaudeAccount) -> Double {
        claudeFiveHourBudgetUSD ?? claudeBudgetAuto[account.id]?.usd ?? 100
    }

    /// `nil` means nothing has been worked out yet — a fresh install, or an
    /// account seen for the first time — and the gauge shows no figure rather
    /// than a fictional one.
    func budgetBasis(for account: ClaudeAccount) -> ClaudeBudgetBasis? {
        if claudeFiveHourBudgetUSD != nil { return .manual }
        return claudeBudgetAuto[account.id]?.basis
    }

    func budgetSamples(for account: ClaudeAccount) -> Int {
        claudeFiveHourBudgetUSD != nil ? 0 : (claudeBudgetAuto[account.id]?.samples ?? 0)
    }

    /// The next renewal of the plan billed on `billingDays[key]`, today included.
    func nextBilling(_ key: String, from now: Date = Date()) -> Date? {
        guard let day = billingDays[key], (1...31).contains(day) else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: today)) else { return nil }
        for offset in 0...1 {
            guard let month = cal.date(byAdding: .month, value: offset, to: thisMonth),
                  let length = cal.range(of: .day, in: .month, for: month)?.count else { continue }
            // A plan started on the 31st renews on a short month's last day.
            if let date = cal.date(byAdding: .day, value: min(day, length) - 1, to: month), date >= today {
                return date
            }
        }
        return nil
    }

    func needsCalibration(_ account: ClaudeAccount) -> Bool {
        guard claudeFiveHourBudgetUSD == nil else { return false }
        guard let known = claudeBudgetAuto[account.id] else { return true }
        return Date().timeIntervalSince(known.at) > 24 * 3600
    }

    private enum CodingKeys: String, CodingKey {
        case claudeFiveHourBudgetUSD, claudeConfigDirs, claudeBudgetAuto
        case fastPollSeconds, slowPollSeconds, showClaude, showCodex, showGrok, showCursor, showMemory, billingDays
        case displayID, edge, anchor, notchMode, shortcuts, verticalAnchor
    }

    /// Fields that existed before a machine could hold two accounts. Read only
    /// on the way in, so an older config file keeps its calibration.
    private enum LegacyKeys: String, CodingKey {
        case claudeBudgetAutoUSD, claudeBudgetAutoAt, claudeBudgetAutoBasis, claudeBudgetAutoSamples
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        claudeFiveHourBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .claudeFiveHourBudgetUSD)
        claudeConfigDirs = try c.decodeIfPresent([String].self, forKey: .claudeConfigDirs)
        claudeBudgetAuto = try c.decodeIfPresent([String: AutoBudget].self, forKey: .claudeBudgetAuto) ?? [:]
        // Before there could be a second account the budget was one flat set of
        // fields; fold it into the map under the account it was derived from.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if claudeBudgetAuto.isEmpty,
           let usd = try legacy.decodeIfPresent(Double.self, forKey: .claudeBudgetAutoUSD),
           let at = try legacy.decodeIfPresent(Date.self, forKey: .claudeBudgetAutoAt) {
            claudeBudgetAuto[ClaudeAccounts.defaultConfigDir.path] = AutoBudget(
                usd: usd, at: at,
                basis: try legacy.decodeIfPresent(ClaudeBudgetBasis.self, forKey: .claudeBudgetAutoBasis) ?? .history,
                samples: try legacy.decodeIfPresent(Int.self, forKey: .claudeBudgetAutoSamples) ?? 0)
        }
        fastPollSeconds = try c.decodeIfPresent(Double.self, forKey: .fastPollSeconds) ?? d.fastPollSeconds
        slowPollSeconds = try c.decodeIfPresent(Double.self, forKey: .slowPollSeconds) ?? d.slowPollSeconds
        showClaude = try c.decodeIfPresent(Bool.self, forKey: .showClaude) ?? d.showClaude
        showCodex = try c.decodeIfPresent(Bool.self, forKey: .showCodex) ?? d.showCodex
        showGrok = try c.decodeIfPresent(Bool.self, forKey: .showGrok) ?? d.showGrok
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? d.showCursor
        showMemory = try c.decodeIfPresent(Bool.self, forKey: .showMemory) ?? d.showMemory
        billingDays = try c.decodeIfPresent([String: Int].self, forKey: .billingDays) ?? d.billingDays
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID)
        edge = try c.decodeIfPresent(NotchEdge.self, forKey: .edge) ?? d.edge
        // `verticalAnchor` is what this was called when left was the only edge.
        anchor = try c.decodeIfPresent(Double.self, forKey: .anchor)
            ?? c.decodeIfPresent(Double.self, forKey: .verticalAnchor)
            ?? d.anchor
        notchMode = try c.decodeIfPresent(Bool.self, forKey: .notchMode) ?? d.notchMode
        shortcuts = try c.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? d.shortcuts
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            var fresh = Config()
            fresh.addRecorderIfNeeded()
            fresh.save()
            return fresh
        }
        cfg.addRecorderIfNeeded()
        return cfg
    }

    /// The record button can be moved but not removed, so it is put back at
    /// the end whenever it is missing.
    private mutating func addRecorderIfNeeded() {
        guard MeetilyRecorder.isInstalled, !shortcuts.contains(where: \.isRecorder) else { return }
        shortcuts.append(.recorder)
    }

    func save() {
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.url, options: .atomic)
    }
}
