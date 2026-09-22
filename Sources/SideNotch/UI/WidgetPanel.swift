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
            if let account = store.claude.first(where: { spec.id == "claude:\($0.id)" }) {
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

// MARK: - Codex

private struct CodexBody: View {
    let usage: CodexUsage
    let shown: Bool

    var body: some View {
        Row(index: 0, shown: shown) {
            Header(title: "Codex", trailing: usage.planType)
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
