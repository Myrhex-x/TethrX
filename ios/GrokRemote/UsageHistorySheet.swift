import SwiftUI

/// Day-by-day token and cost usage. The Settings screen already shows lifetime
/// totals; a lifetime number that only ever grows tells you nothing about whether
/// today was expensive, which is the question people actually ask.
struct UsageHistorySheet: View {
    let client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    @State private var days: [UsageDay] = []
    @State private var range = 14
    @State private var loading = true
    @State private var errorText: String?

    /// Newest first for the list; the chart reads them oldest-first (as fetched).
    private var recent: [UsageDay] { days.reversed() }
    private var active: [UsageDay] { days.filter { $0.turns > 0 } }
    private var totalCost: Double { days.reduce(0) { $0 + $1.costUSD } }
    private var totalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }
    private var totalTurns: Int { days.reduce(0) { $0 + $1.turns } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    rangePicker
                    if loading && days.isEmpty {
                        Text("Loading…").font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                    } else if let errorText {
                        Text(errorText).font(Grok.mono(12)).foregroundStyle(Grok.danger)
                    } else if active.isEmpty {
                        empty
                    } else {
                        summary
                        chart
                        breakdown
                    }
                    footnote
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Grok.text).fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    // MARK: Sections

    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach([7, 14, 30], id: \.self) { n in
                Button {
                    range = n
                    Haptics.tap()
                    Task { await load() }
                } label: {
                    Text(dayCountLabel(n)).chip(on: range == n)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(Fmt.cost(totalCost), "cost")
            stat(Fmt.tokens(totalTokens), "tokens")
            stat("\(totalTurns)", "turns")
            stat("\(active.count)", "active days")
        }
    }

    private func stat(_ value: String, _ caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Grok.mono(17, .semibold)).foregroundStyle(Grok.text)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(caption).font(Grok.mono(9)).foregroundStyle(Grok.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bars scaled to the busiest day. Deliberately plain: a phone-width chart with
    /// axes and gridlines would be less readable than the numbers beside it.
    private var chart: some View {
        let peak = max(days.map(\.totalTokens).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow("TOKENS PER DAY")
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    let height = day.totalTokens > 0
                        ? max(3, CGFloat(day.totalTokens) / CGFloat(peak) * 92)
                        : 2
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.totalTokens > 0 ? Grok.accent.opacity(0.85) : Grok.hairlineStrong)
                            .frame(height: height)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 94)
                    .accessibilityLabel("\(day.date): \(Fmt.tokens(day.totalTokens)) tokens")
                }
            }
            // One label per end keeps it legible at 7 or 30 days; the list below
            // carries the per-day detail anyway.
            if let first = days.first, let last = days.last {
                HStack {
                    Text(first.weekdayLabel).font(Grok.mono(9)).foregroundStyle(Grok.textFaint)
                    Spacer()
                    Text(last.weekdayLabel).font(Grok.mono(9)).foregroundStyle(Grok.textFaint)
                }
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("BY DAY")
            ForEach(recent.filter { $0.turns > 0 }) { day in
                HStack(spacing: 10) {
                    Text(day.date).font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                        .frame(width: 86, alignment: .leading)
                    Text(Fmt.tokens(day.totalTokens)).font(Grok.mono(12, .semibold))
                        .foregroundStyle(Grok.text)
                    Spacer(minLength: 6)
                    Text(turnsLabel(day.turns)).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                    Text(Fmt.cost(day.costUSD)).font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing yet in this range.").font(Grok.mono(13)).foregroundStyle(Grok.text)
            Text("Usage is counted from the day your bridge was updated to record it.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint).lineSpacing(2)
        }
    }

    private var footnote: some View {
        Text("Counted on your computer, from what Grok reports for each turn. Cost is Grok's own estimate, not billing data from your xAI account.")
            .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
    }

    // MARK: Data

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            days = try await client.usageHistory(days: range)
        } catch {
            // An older bridge has no history endpoint at all; say what to do about it
            // rather than showing a bare failure.
            if case .badStatus(404) = (error as? BridgeError) ?? .badURL {
                errorText = String(localized: "Your computer needs bridge 0.1.15 or newer for daily usage. Update it with: npm i -g tethrx-bridge")
            } else {
                errorText = String(localized: "Couldn't load usage from your computer.")
            }
        }
    }

    private func dayCountLabel(_ n: Int) -> String {
        String(format: String(localized: "%lld days"), n)
    }

    private func turnsLabel(_ n: Int) -> String {
        String(format: String(localized: "%lld turns"), n)
    }
}
