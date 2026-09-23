import SwiftUI

/// Contents revealed inside the island. No background of its own — the island's
/// single shape already provides it, which is what keeps the expansion reading
/// as one body growing rather than a second surface appearing.
struct WidgetBody: View {
    let spec: WidgetSpec
    @ObservedObject var store: UsageStore

    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if spec.id == "memory" {
                MemoryBody(usage: store.memory, shown: shown, onQuit: store.refreshMemory)
            } else if let account = store.claude.first(where: { spec.id == "claude:\($0.id)" }) {
                ClaudeBody(usage: account, shown: shown)
            } else {
                CodexBody(usage: store.codex, shown: shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }
}

/// Stagger wrapper: index 0 arrives first, each later row `Motion.stagger` behind.
private struct Row<Content: View>: View {
    let index: Int
    let shown: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 2)
            .offset(x: shown ? 0 : -10)
            .animation(
                shown
                    ? Motion.rowIn.delay(Double(index) * Motion.stagger + Motion.rowLead)
                    : Motion.rowOut,
                value: shown
            )
    }
}

// MARK: - Claude

private struct ClaudeBody: View {
    let usage: ClaudeUsage
    let shown: Bool

    var body: some View {
        Row(index: 0, shown: shown) {
            Header(title: usage.label.isEmpty ? "Claude Code" : "Claude Code \(usage.label)",
                   trailing: usage.quota.map { Fmt.ago($0.fetchedAt) } ?? L.estimate)
        }
        // A number on the rail only helps if something says which login it is.
        if let email = usage.email, !usage.label.isEmpty {
            Row(index: 1, shown: shown) {
                Text(email)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.textTertiary)
            }
        }

        if let quota = usage.quota, let p = quota.headline {
            Row(index: 1, shown: shown) {
                Meter(remaining: p.remaining, color: Theme.tint(remaining: p.remaining))
            }
            Row(index: 2, shown: shown) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Fmt.percent(p.remaining))
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    Text(L.left)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                    Text(L.used(Fmt.percent(p.usedPercent / 100)))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Row(index: 3, shown: shown) {
                VStack(alignment: .leading, spacing: 2) {
                    if let at = Fmt.resetStamp(p.resetsAt),
                       let left = Fmt.remaining(until: p.resetsAt) {
                        Text(L.limitWindow(p.label, resetAt: at))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                        Text(L.inTime(left))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            ForEach(Array(quota.others.enumerated()), id: \.element.label) { i, w in
                Row(index: 4 + i, shown: shown) {
                    Text(L.secondaryLeft(w.label, Fmt.percent(w.remaining)))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } else if usage.windowEnd != nil, let basis = usage.budgetBasis {
            Row(index: 1, shown: shown) {
                Meter(remaining: usage.remaining,
                      color: Theme.tint(remaining: usage.remaining))
            }
            Row(index: 2, shown: shown) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Fmt.percent(usage.remaining))
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    Text(L.left)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                    Text(L.spent(Fmt.usd(usage.costUSD), of: Fmt.usd(usage.budgetUSD)))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Row(index: 3, shown: shown) {
                VStack(alignment: .leading, spacing: 2) {
                    if let at = Fmt.resetStamp(usage.windowEnd),
                       let left = Fmt.remaining(until: usage.windowEnd) {
                        Text(L.claudeWindow(resetAt: at))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                        Text(L.inTime(left))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            // The gauge is only as good as its denominator, so say where that
            // came from instead of leaving a bare percentage to be trusted.
            Row(index: 4, shown: shown) {
                Text(basisLine(basis))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            Row(index: 1, shown: shown) {
                Text(usage.windowEnd == nil ? L.noActiveWindow : L.measuringLimit)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }

    }

    private func basisLine(_ basis: ClaudeBudgetBasis) -> String {
        let amount = Fmt.usd(usage.budgetUSD)
        switch basis {
        case .refusals: return L.limitMeasured(amount, cutOffs: usage.budgetSamples)
        case .history:  return L.limitInferred(amount)
        case .manual:   return L.limitManual(amount)
        }
    }
}

// MARK: - Memory

private struct MemoryBody: View {
    let usage: MemoryUsage
    let shown: Bool
    var onQuit: () -> Void

    /// What one press found. A second press quits exactly these — never a
    /// fresh scan the user has not seen.
    @State private var plan: [IdleApp]?
    /// Brief outcome shown where the button was.
    @State private var note: String?

    var body: some View {
        Row(index: 0, shown: shown) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(L.memory)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                optimizeButton
            }
        }
        Row(index: 1, shown: shown) {
            Meter(remaining: usage.usedFraction, color: Theme.tint(memory: usage))
        }
        Row(index: 2, shown: shown) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Fmt.percent(usage.usedFraction))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(L.usedShort)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Text("\(Fmt.gigabytes(usage.used)) / \(Fmt.gigabytes(usage.total))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        Row(index: 3, shown: shown) {
            VStack(alignment: .leading, spacing: 2) {
                // Swap rides on the pressure line: the two tell one story, and
                // the line it would take is worth another app in the list below.
                Text(usage.swapUsed > 0
                     ? "\(L.pressure(usage.pressure)) · \(L.swap(Fmt.gigabytes(usage.swapUsed)))"
                     : L.pressure(usage.pressure))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Text(L.memoryBreakdown(app: Fmt.gigabytes(usage.app),
                                       wired: Fmt.gigabytes(usage.wired),
                                       compressed: Fmt.gigabytes(usage.compressed)))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        if !usage.hogs.isEmpty || plan != nil {
            Row(index: 4, shown: shown) {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    if let plan {
                        PlanList(apps: plan)
                    } else {
                        HogList(hogs: usage.hogs)
                    }
                }
                .padding(.bottom, Metrics.detailPadding)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var optimizeButton: some View {
        Button {
            if let plan {
                MemoryOptimizer.shared.quit(plan)
                note = L.quitCount(plan.count)
                self.plan = nil
                onQuit()
            } else {
                let found = MemoryOptimizer.shared.candidates()
                if found.isEmpty { note = L.nothingToFree } else { plan = found }
            }
        } label: {
            Group {
                if let plan {
                    Text(L.optimizeConfirm(plan.count,
                                           Fmt.gigabytes(plan.reduce(0) { $0 + $1.bytes })))
                        .foregroundStyle(Theme.danger)
                } else if let note {
                    Text(note).foregroundStyle(Theme.textTertiary)
                } else {
                    Text(L.optimize).foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(note != nil && plan == nil)
        .help(L.optimizeHelp)
        // Long enough to read the list; a plan left alone lapses rather than
        // waiting to be triggered by a stray click later.
        .task(id: plan?.map(\.id)) {
            guard plan != nil else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { plan = nil }
        }
        .task(id: note) {
            guard note != nil else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { note = nil }
        }
        .onChange(of: shown) { _, now in
            if !now { plan = nil }
        }
    }
}

/// What the optimiser is about to quit, biggest first, with the reason.
private struct PlanList: View {
    let apps: [IdleApp]

    var body: some View {
        FittingStack(spacing: 3) {
            ForEach(apps) { item in
                HStack(spacing: 6) {
                    Group {
                        if let path = item.bundlePath {
                            Image(nsImage: ShortcutIcon.image(forPath: path))
                                .resizable()
                                .interpolation(.high)
                        } else {
                            Image(systemName: "app")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 13, height: 13)
                    Text(item.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 4)
                    Text(reason(item.reason))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Text(Fmt.gigabytes(item.bytes))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(height: 16)
            }
        }
    }

    private func reason(_ r: IdleApp.Reason) -> String {
        switch r {
        case .noWindows: return L.noWindows
        case .idle(let minutes): return L.idleFor(minutes)
        }
    }
}

/// Biggest apps first, as many as the panel has room for.
private struct HogList: View {
    let hogs: [MemoryHog]
    /// The row whose quit button has been pressed once. A second press within
    /// a few seconds quits; anything else lets it lapse. The panel opens on
    /// hover, so one stray click must not be enough to close someone's work.
    @State private var armed: String?

    var body: some View {
        FittingStack(spacing: 3) {
            ForEach(hogs) { hog in
                HStack(spacing: 6) {
                    Group {
                        if hog.bundlePath != nil {
                            Image(nsImage: ShortcutIcon.image(forPath: hog.iconPath))
                                .resizable()
                                .interpolation(.high)
                        } else {
                            // A bare executable has no icon of its own; Finder's
                            // blank page reads as a missing image.
                            Image(systemName: "terminal")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 13, height: 13)
                    Text(hog.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 4)
                    Text(Fmt.gigabytes(hog.bytes))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                    Text(Fmt.percent(hog.share))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, alignment: .trailing)
                    quitButton(hog)
                }
                .frame(height: 16)
            }
        }
        .task(id: armed) {
            guard armed != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { armed = nil }
        }
    }

    private func quitButton(_ hog: MemoryHog) -> some View {
        let isArmed = armed == hog.id
        return Button {
            if isArmed {
                hog.quit()
                armed = nil
            } else {
                armed = hog.id
            }
        } label: {
            Group {
                if isArmed {
                    Text(L.confirmQuit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 26, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.quitApp(hog.name))
        .accessibilityLabel(L.quitApp(hog.name))
    }
}

/// Stacks rows top-down and leaves out whole rows that would not fit, so a list
/// sized to the panel never ends in a half-cut line.
private struct FittingStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let heights = subviews.map { $0.sizeThatFits(.init(width: proposal.width, height: nil)).height }
        let natural = heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
        return CGSize(width: proposal.width ?? 0, height: min(proposal.height ?? natural, natural))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let h = subview.sizeThatFits(.init(width: bounds.width, height: nil)).height
            if y + h <= bounds.maxY + 0.5 {
                subview.place(at: CGPoint(x: bounds.minX, y: y),
                              proposal: .init(width: bounds.width, height: h))
            } else {
                // Parked far outside the clipped panel, where it can be
                // neither seen nor clicked.
                subview.place(at: CGPoint(x: -10_000, y: -10_000), proposal: .zero)
            }
            y += h + spacing
        }
    }
}

// MARK: - Codex

private struct CodexBody: View {
    let usage: CodexUsage
    let shown: Bool

    var body: some View {
        Row(index: 0, shown: shown) {
            Header(title: "Codex", trailing: usage.updatedAt.map { Fmt.ago($0) })
        }

        if let p = usage.headline {
            Row(index: 1, shown: shown) {
                Meter(remaining: p.remaining, color: Theme.tint(remaining: p.remaining))
            }
            Row(index: 2, shown: shown) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Fmt.percent(p.remaining))
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                    Text(L.left)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                    Text(L.used(Fmt.percent(p.usedPercent / 100)))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Row(index: 3, shown: shown) {
                VStack(alignment: .leading, spacing: 2) {
                    if let at = Fmt.resetStamp(p.resetsAt),
                       let left = Fmt.remaining(until: p.resetsAt) {
                        Text(L.limitWindow(p.label, resetAt: at))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                        Text(L.inTime(left))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            // The other windows still matter — showing only the tightest one
            // hides why the number moved when a different limit takes over.
            ForEach(Array(usage.others.enumerated()), id: \.element.windowMinutes) { i, w in
                Row(index: 4 + i, shown: shown) {
                    Text(L.secondaryLeft(w.label, Fmt.percent(w.remaining)))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } else {
            Row(index: 1, shown: shown) {
                Text(L.noCodexSession)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }

    }
}

// MARK: - Shared

private struct Header: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
