import Foundation

/// User-editable settings. Lives at ~/.config/sidenotch/config.json and is
/// re-read whenever the file changes, so edits apply without a restart.
struct Config: Codable, Equatable {
    /// What a full 5-hour window costs on this account. `nil` — the default —
    /// works it out from your own history, which is the only way the gauge means
    /// anything on someone else's machine. Set a number to pin it.
    var claudeFiveHourBudgetUSD: Double?

    /// Last auto-derived value, when, and what it rests on, so the scan runs
    /// once a day at most and the panel can say how much to trust it.
    var claudeBudgetAutoUSD: Double?
    var claudeBudgetAutoAt: Date?
    var claudeBudgetAutoBasis: ClaudeBudgetBasis?
    var claudeBudgetAutoSamples: Int = 0

    /// Seconds between cheap polls (live sessions, Codex tail).
    var fastPollSeconds: Double = 2
    /// Seconds between the expensive poll (Claude token log scan).
    var slowPollSeconds: Double = 20

    var showClaude: Bool = true
    var showCodex: Bool = true

    /// Display the rail sits on. nil = the primary screen.
    var displayID: UInt32? = nil

    /// Which screen edge the notch is docked to.
    var edge: NotchEdge = .left

    /// Position along that edge. 0 = start (top or left), 1 = end. 0.5 centres it.
    var anchor: Double = 0.5

    /// Apps dropped onto the rail, in the order they appear.
    var shortcuts: [Shortcut] = []

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sidenotch/config.json")

    /// Kept only so an older config file still decodes.
    private var verticalAnchor: Double?

    /// Whatever the gauge should divide by right now.
    var effectiveBudgetUSD: Double { claudeFiveHourBudgetUSD ?? claudeBudgetAutoUSD ?? 100 }

    /// `nil` means nothing has been worked out yet — a fresh install on the
    /// first run — and the gauge shows no figure rather than a fictional one.
    var budgetBasis: ClaudeBudgetBasis? {
        if claudeFiveHourBudgetUSD != nil { return .manual }
        guard claudeBudgetAutoUSD != nil else { return nil }
        return claudeBudgetAutoBasis ?? .history
    }

    var budgetSamples: Int { claudeFiveHourBudgetUSD != nil ? 0 : claudeBudgetAutoSamples }

    var needsCalibration: Bool {
        guard claudeFiveHourBudgetUSD == nil else { return false }
        guard let at = claudeBudgetAutoAt, claudeBudgetAutoUSD != nil else { return true }
        return Date().timeIntervalSince(at) > 24 * 3600
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        claudeFiveHourBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .claudeFiveHourBudgetUSD)
        claudeBudgetAutoUSD = try c.decodeIfPresent(Double.self, forKey: .claudeBudgetAutoUSD)
        claudeBudgetAutoAt = try c.decodeIfPresent(Date.self, forKey: .claudeBudgetAutoAt)
        claudeBudgetAutoBasis = try c.decodeIfPresent(ClaudeBudgetBasis.self, forKey: .claudeBudgetAutoBasis)
        claudeBudgetAutoSamples = try c.decodeIfPresent(Int.self, forKey: .claudeBudgetAutoSamples) ?? 0
        fastPollSeconds = try c.decodeIfPresent(Double.self, forKey: .fastPollSeconds) ?? d.fastPollSeconds
        slowPollSeconds = try c.decodeIfPresent(Double.self, forKey: .slowPollSeconds) ?? d.slowPollSeconds
        showClaude = try c.decodeIfPresent(Bool.self, forKey: .showClaude) ?? d.showClaude
        showCodex = try c.decodeIfPresent(Bool.self, forKey: .showCodex) ?? d.showCodex
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID)
        edge = try c.decodeIfPresent(NotchEdge.self, forKey: .edge) ?? d.edge
        // `verticalAnchor` is what this was called when left was the only edge.
        anchor = try c.decodeIfPresent(Double.self, forKey: .anchor)
            ?? c.decodeIfPresent(Double.self, forKey: .verticalAnchor)
            ?? d.anchor
        shortcuts = try c.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? d.shortcuts
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let fresh = Config()
            fresh.save()
            return fresh
        }
        return cfg
    }

    func save() {
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.url, options: .atomic)
    }
}
