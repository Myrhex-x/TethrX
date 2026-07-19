import SwiftUI

/// App settings: connection info, defaults for new sessions, and about.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var revealToken = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    connection
                    defaults
                    about
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
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

    private var efforts: [(String, String)] { [("Auto", ""), ("High", "high"), ("Med", "medium"), ("Low", "low")] }
    private var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }
}
