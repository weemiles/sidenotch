import Foundation
import Combine

/// Owns polling and publishes the two usage snapshots the UI renders.
///
/// Two cadences, because the two sources cost very different amounts to read:
/// live sessions and the Codex tail are kilobytes, the Claude transcript scan is not.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var claude = ClaudeUsage()
    @Published private(set) var codex = CodexUsage()
    @Published private(set) var config = Config.load()

    /// Only ever touched from `queue`; never from the main actor.
    nonisolated(unsafe) private let scanner = ClaudeLogScanner()
    private let queue = DispatchQueue(label: "sidenotch.scan", qos: .utility)
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var scanning = false

    func start() {
        applyBudget()
        if let demo = DemoValues.current {
            // Hold the numbers still for a recording: no timers, no disk reads.
            claude = demo.claude(budget: config.effectiveBudgetUSD)
            claude.budgetBasis = .manual
            codex = demo.codex
            return
        }
        scheduleTimers()
        pollFast()
        pollSlow()
        calibrate()
    }

    /// Derives the budget from this account's own history, off the main thread.
    /// Without it the gauge divides by a number that meant something only on the
    /// machine it was written on.
    ///
    /// `force` is for the moment a refusal appears: the account has just shown
    /// where its ceiling is, and waiting a day to notice would leave the gauge
    /// reading full right after it ran out.
    private func calibrate(force: Bool = false) {
        guard force || config.needsCalibration else { return }
        queue.async {
            guard let derived = ClaudeCalibrator.derive() else { return }
            Task { @MainActor in
                var cfg = self.config
                cfg.claudeBudgetAutoUSD = derived.budgetUSD
                cfg.claudeBudgetAutoBasis = derived.basis
                cfg.claudeBudgetAutoSamples = derived.samples
                cfg.claudeBudgetAutoAt = Date()
                cfg.save()
                self.config = cfg
                self.applyBudget()
                if ProcessInfo.processInfo.environment["SIDENOTCH_DEBUG"] != nil {
                    let line = "calibrate: $\(Int(derived.budgetUSD)) per 5h window"
                        + " from \(derived.samples) \(derived.basis.rawValue)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
        }
    }

    /// Keeps the denominator and the story behind it in step; they are read
    /// together and a stale pair reads as a confident wrong number.
    private func applyBudget() {
        claude.budgetUSD = config.effectiveBudgetUSD
        claude.budgetBasis = config.budgetBasis
        claude.budgetSamples = config.budgetSamples
    }

    func reloadConfig() {
        config = Config.load()
        applyBudget()
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
        pollFast()
        pollSlow()
    }

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

    /// Expensive on first run, incremental afterwards.
    private func pollSlow() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let window = self.scanner.refreshWindow()
            let refused = self.scanner.takeRefusal()
            Task { @MainActor in
                self.claude.windowStart = window?.start
                self.claude.windowEnd = window?.end
                self.claude.costUSD = window?.cost ?? 0
                self.claude.totalTokens = window?.tokens ?? 0
                self.applyBudget()
                self.scanning = false
                if refused { self.calibrate(force: true) }
            }
        }
    }
}
