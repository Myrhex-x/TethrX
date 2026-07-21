import SwiftUI

/// The bridge's recent console output, viewable from the phone — so "it broke"
/// can be debugged without walking anyone through Terminal.
struct BridgeLogSheet: View {
    let client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [String]?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    if let lines {
                        if lines.isEmpty {
                            Text("// nothing logged yet")
                                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(Grok.mono(11))
                                .foregroundStyle(line.localizedCaseInsensitiveContains("error") ? Grok.danger : Grok.textDim)
                        }
                    } else if let errorText {
                        Text(errorText).font(Grok.mono(12)).foregroundStyle(Grok.danger)
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            }
            .background(Grok.bg)
            .navigationTitle("Bridge log")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = (lines ?? []).joined(separator: "\n")
                        Haptics.tap()
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Grok.textDim)
                    .accessibilityLabel("Copy log")
                    .disabled((lines ?? []).isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { Task { await load() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Grok.textDim)
                        .accessibilityLabel("Refresh")
                        Button("Done") { dismiss() }.foregroundStyle(Grok.text).fontWeight(.semibold)
                    }
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private func load() async {
        errorText = nil
        do {
            lines = try await client.logs()
        } catch {
            if case .badStatus(404) = (error as? BridgeError) ?? .badURL {
                errorText = "This needs bridge 0.1.14 or newer — update it with npm i -g tethrx-bridge."
            } else {
                errorText = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
