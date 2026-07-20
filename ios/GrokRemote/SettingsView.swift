import SwiftUI

/// App settings: connection info, defaults for new sessions, and about.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var lock: AppLock
    @EnvironmentObject var snippets: SnippetStore
    @ObservedObject private var push = PushManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var revealToken = false
    @State private var addingComputer = false
    @State private var report: UsageReport?
    @State private var loadingUsage = false
    @State private var newSnippet = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    connection
                    computers
                    usage
                    defaults
                    SchedulesSection()
                    notifications
                    security
                    snippetsSection
                    about
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .task { await loadUsage() }
            // Switching computers happens inside this very sheet — without this the
            // usage panel kept showing the PREVIOUS computer's totals.
            .onChange(of: app.activeBridgeId) { _, _ in
                report = nil
                Task { await loadUsage() }
            }
            .sheet(isPresented: $addingComputer) {
                AddComputerSheet().environmentObject(app)
            }
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

            Text("Totals across every session on this computer. Cost is grok's own estimate, not billing data from your account.")
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

    private var security: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("SECURITY")
            toggleRow("Require \(lock.biometryName)", "Lock the app on open — it can run commands on your computer", $lock.enabled)
        }
    }

    private var computers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("COMPUTERS")
            if app.savedBridges.isEmpty {
                Text("Computers you pair show up here.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            } else {
                ForEach(app.savedBridges) { bridge in
                    Button {
                        Haptics.tap()
                        Task { await app.switchTo(bridge) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: bridge.id == app.activeBridgeId ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14))
                                .foregroundStyle(bridge.id == app.activeBridgeId ? Grok.accent : Grok.textFaint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bridge.name).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1)
                                Text(bridge.address).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { app.forget(bridge) } label: {
                            Label("Forget", systemImage: "trash")
                        }
                    }
                }
                Text("Tap to switch computers. Long-press to forget one.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            }
            Button { Haptics.tap(); addingComputer = true } label: {
                Label("Add another computer", systemImage: "plus.circle")
            }
            .buttonStyle(PillButton(kind: .subtle))
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("NOTIFICATIONS")
            toggleRow("Push notifications",
                      "Get alerted when Grok finishes a turn or needs approval — even with the app closed",
                      Binding(get: { push.enabled }, set: { $0 ? push.enable() : push.disable() }))
            Text("Requires an APNs key configured on your bridge. Delivered to this phone when it isn't actively watching a session.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
        }
    }

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("PROMPT SNIPPETS")
            Text("Reusable prompts you can tap to send from a session.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            ForEach(Array(snippets.items.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    Text(s).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(2)
                    Spacer(minLength: 8)
                    Button { snippets.remove(at: IndexSet(integer: i)) } label: {
                        Image(systemName: "minus.circle").font(.caption)
                    }.foregroundStyle(Grok.textDim)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Grok.raised)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                FieldBox {
                    TextField("", text: $newSnippet, prompt: Text("add a snippet…").foregroundColor(Grok.textFaint), axis: .vertical)
                        .font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1...3)
                }
                Button { snippets.add(newSnippet); newSnippet = "" } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(newSnippet.trimmingCharacters(in: .whitespaces).isEmpty ? Grok.textFaint : Grok.text)
                .disabled(newSnippet.trimmingCharacters(in: .whitespaces).isEmpty)
            }
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
