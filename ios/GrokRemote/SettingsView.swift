import SwiftUI

/// App settings: connection info, defaults for new sessions, and about.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var revealToken = false
    @State private var report: UsageReport?
    @State private var loadingUsage = false
    @AppStorage("usage.budgetUSD") private var budgetUSD: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    connection
                    usage
                    defaults
                    about
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .task { await loadUsage() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Grok.text).fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("CONNECTION")
            row("Bridge", app.normalizedBase.isEmpty ? "—" : app.normalizedBase)
            HStack {
                Text("Token").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                Spacer()
                Text(revealToken ? app.token : String(repeating: "•", count: min(max(app.token.count, 1), 18)))
                    .font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
                Button { revealToken.toggle() } label: {
                    Image(systemName: revealToken ? "eye.slash" : "eye").font(.caption)
                }.foregroundStyle(Grok.textDim)
            }
            Button { dismiss(); app.disconnect() } label: { Text("Disconnect").frame(maxWidth: .infinity) }
                .buttonStyle(PillButton(kind: .subtle))
                .padding(.top, 4)
        }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("USAGE")
                Spacer()
                Button { Task { await loadUsage() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }.foregroundStyle(Grok.textDim)
            }

            if let r = report {
                if budgetUSD > 0 {
                    let frac = min(1, r.costUSD / budgetUSD)
                    UsageBar(fraction: frac)
                    HStack {
                        Text("\(Fmt.cost(r.costUSD)) / \(Fmt.cost(budgetUSD))")
                            .font(Grok.mono(13, .semibold)).foregroundStyle(Grok.text)
                        Spacer()
                        Text("\(Fmt.cost(max(0, budgetUSD - r.costUSD))) left")
                            .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                    }
                }
                row("Total tokens", Fmt.tokens(r.totals.totalTokens))
                row("Input", Fmt.tokens(r.totals.inputTokens))
                row("Output", Fmt.tokens(r.totals.outputTokens))
                row("Thinking", Fmt.tokens(r.totals.reasoningTokens))
                row("Cached read", Fmt.tokens(r.totals.cachedReadTokens))
                Rectangle().fill(Grok.hairline).frame(height: 1).padding(.vertical, 2)
                row("Turns", "\(r.totals.turns)")
                row("Sessions", "\(r.sessionCount)")
                row("Est. cost", Fmt.cost(r.costUSD))
            } else if loadingUsage {
                Text("Loading…").font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
            } else {
                Text("Connect to the bridge to see usage.").font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
            }

            HStack {
                Text("Budget (USD)").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                Spacer()
                TextField("none", value: $budgetUSD, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(Grok.mono(12)).foregroundStyle(Grok.text)
                    .frame(width: 90)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Grok.raised)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Grok.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("Grok doesn't report an account quota over the bridge, so “left” means your per-session context window plus any spend budget you set here.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
        }
    }

    private var defaults: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("NEW SESSION DEFAULTS")
            VStack(alignment: .leading, spacing: 8) {
                Text("Reasoning effort").font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                HStack(spacing: 8) {
                    ForEach(efforts, id: \.1) { label, value in
                        Button { app.defaultEffort = value } label: { Text(label).font(Grok.mono(12, .medium)) }
                            .buttonStyle(SegPill(selected: app.defaultEffort == value))
                    }
                    Spacer(minLength: 0)
                }
            }
            toggleRow("Plan mode", "Grok drafts a plan to approve first", $app.defaultPlanMode)
            toggleRow("Auto-approve tools", "Skip the approve/reject prompt", $app.defaultAutoApprove)
            Text("Each session can override these from its own controls.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("ABOUT")
            row("App", "TethrX \(appVersion)")
            row("Grok", app.health?.grok?.replacingOccurrences(of: "grok ", with: "") ?? "—")
            Text("A client for Grok Build · independent, not affiliated with xAI.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            Spacer()
            Text(value).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Grok.mono(12)).foregroundStyle(Grok.text)
                Text(subtitle).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(.white)
        }
    }

    private func loadUsage() async {
        guard let client = app.client else { return }
        loadingUsage = true
        defer { loadingUsage = false }
        report = try? await client.usage()
    }

    private var efforts: [(String, String)] { [("Auto", ""), ("High", "high"), ("Med", "medium"), ("Low", "low")] }
    private var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }
}
