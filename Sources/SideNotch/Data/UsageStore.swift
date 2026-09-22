import Foundation
import Combine

/// Owns polling and publishes the usage snapshots the UI renders.
///
/// Two cadences, because the two sources cost very different amounts to read:
/// the Codex tail is kilobytes, the Claude transcript scan is not.
@MainActor
final class UsageStore: ObservableObject {
    /// One entry per Claude account found on the machine.
    @Published private(set) var claude: [ClaudeUsage] = []
    @Published private(set) var codex = CodexUsage()
    @Published private(set) var config = Config.load()

    private var accounts: [ClaudeAccount] = []
    /// Only ever touched from `queue`; never from the main actor.
    nonisolated(unsafe) private let hub = ScanHub()
    private let queue = DispatchQueue(label: "sidenotch.scan", qos: .utility)
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var scanning = false

    /// Holds one scanner per account. Each keeps byte cursors into that
    /// account's transcripts, so they cannot be shared.
    private final class ScanHub {
        private var scanners: [String: ClaudeLogScanner] = [:]

        func scanner(for account: ClaudeAccount) -> ClaudeLogScanner {
            if let known = scanners[account.id] { return known }
            let made = ClaudeLogScanner(projects: account.projects)
            scanners[account.id] = made
            return made
        }

        func forget(everythingBut ids: Set<String>) {
            scanners = scanners.filter { ids.contains($0.key) }
        }
    }

    func start() {
        refreshAccounts()
        if let demo = DemoValues.current {
            // Hold the numbers still for a recording: no timers, no disk reads.
            claude = claude.enumerated().map { index, usage in
                var shown = demo.claude(budget: usage.budgetUSD)
                shown.id = usage.id
                shown.label = usage.label
                shown.email = usage.email
                shown.budgetBasis = .manual
                _ = index
                return shown
            }
            codex = demo.codex
            return
        }
        scheduleTimers()
        pollFast()
        pollSlow()
        calibrate()
    }

    // MARK: Accounts

    /// Rebuilds the account list, keeping whatever has already been read for the
    /// accounts that are still there.
    private func refreshAccounts() {
        accounts = ClaudeAccounts.discover(configured: config.claudeConfigDirs)
        let previous = Dictionary(uniqueKeysWithValues: claude.map { ($0.id, $0) })
        claude = accounts.map { account in
            var usage = previous[account.id] ?? ClaudeUsage()
            usage.id = account.id
            usage.label = account.label
            usage.email = account.email
            applyBudget(to: &usage, account)
            return usage
        }
    }

    /// Keeps the denominator and the story behind it in step; they are read
    /// together and a stale pair reads as a confident wrong number.
    private func applyBudget(to usage: inout ClaudeUsage, _ account: ClaudeAccount) {
        usage.budgetUSD = config.effectiveBudgetUSD(for: account)
        usage.budgetBasis = config.budgetBasis(for: account)
        usage.budgetSamples = config.budgetSamples(for: account)
    }

    private func applyBudgets() {
        for (index, account) in accounts.enumerated() where index < claude.count {
            applyBudget(to: &claude[index], account)
        }
    }

    // MARK: Calibration

    /// Derives each account's budget from its own history, off the main thread.
    /// Without it the gauge divides by a number that meant something only on the
    /// machine — and the account — it was written on.
    ///
    /// `forced` carries the accounts whose refusal just turned up: one has shown
    /// where its ceiling is, and waiting a day to notice would leave the gauge
    /// reading full right after it ran out.
    private func calibrate(forced: Set<String> = []) {
        let due = accounts.filter { forced.contains($0.id) || config.needsCalibration($0) }
        guard !due.isEmpty else { return }
        queue.async { [weak self] in
            let derived = due.compactMap { account in
                ClaudeCalibrator.derive(projects: account.projects).map { (account, $0) }
            }
            guard !derived.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                var cfg = self.config
                for (account, result) in derived {
                    cfg.claudeBudgetAuto[account.id] = Config.AutoBudget(
                        usd: result.budgetUSD, at: Date(),
                        basis: result.basis, samples: result.samples)
                    if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
                        let line = "calibrate \(account.configDir.lastPathComponent):"
                            + " $\(Int(result.budgetUSD)) per 5h window"
                            + " from \(result.samples) \(result.basis.rawValue)\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                }
                cfg.save()
                self.config = cfg
                self.applyBudgets()
            }
        }
    }

    // MARK: Config

    func reloadConfig() {
        config = Config.load()
        refreshAccounts()
        guard DemoValues.current == nil else { return }
        scheduleTimers()
    }

    func addShortcut(_ url: URL) {
        var cfg = config
        guard !cfg.shortcuts.contains(where: { $0.path == url.path }) else { return }
        cfg.shortcuts.append(Shortcut(url: url))
        cfg.save()
        config = cfg
    }

    func removeShortcut(_ shortcut: Shortcut) {
        var cfg = config
        cfg.shortcuts.removeAll { $0.path == shortcut.path }
        cfg.save()
        config = cfg
    }

    /// Update the in-memory config without writing to disk — a drag changes it
    /// 120 times a second and only the final position is worth persisting.
    func applyLive(_ cfg: Config) {
        config = cfg
    }

    func refreshNow() {
        guard DemoValues.current == nil else { return }
        refreshAccounts()
        pollFast()
        pollSlow()
    }

    // MARK: Polling

    private func scheduleTimers() {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
        fastTimer = Timer.scheduledTimer(withTimeInterval: max(1, config.fastPollSeconds),
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFast() }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: max(5, config.slowPollSeconds),
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSlow() }
        }
    }

    /// Cheap: just the tail of the newest Codex rollout.
    private func pollFast() {
        queue.async {
            let codexUsage = CodexReader.read()
            Task { @MainActor in self.codex = codexUsage }
        }
    }

    private struct Scan {
        let id: String
        let window: (start: Date, end: Date, cost: Double, tokens: Int)?
        let refused: Bool
    }

    /// Expensive on first run, incremental afterwards.
    private func pollSlow() {
        guard !scanning else { return }
        scanning = true
        let watched = accounts
        queue.async { [weak self] in
            guard let self else { return }
            let scans = watched.map { account -> Scan in
                let scanner = self.hub.scanner(for: account)
                return Scan(id: account.id,
                            window: scanner.refreshWindow(),
                            refused: scanner.takeRefusal())
            }
            self.hub.forget(everythingBut: Set(watched.map(\.id)))
            Task { @MainActor in self.apply(scans) }
        }
    }

    private func apply(_ scans: [Scan]) {
        for scan in scans {
            guard let index = claude.firstIndex(where: { $0.id == scan.id }) else { continue }
            claude[index].windowStart = scan.window?.start
            claude[index].windowEnd = scan.window?.end
            claude[index].costUSD = scan.window?.cost ?? 0
            claude[index].totalTokens = scan.window?.tokens ?? 0
        }
        applyBudgets()
        scanning = false
        let refused = Set(scans.filter(\.refused).map(\.id))
        if !refused.isEmpty { calibrate(forced: refused) }
    }
}
