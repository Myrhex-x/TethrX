import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Share sheet target: send a link, some text, or a screenshot straight into a
/// session without opening the app. The content is queued on the computer, so it
/// runs immediately if Grok is idle and right after the current turn if it isn't.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let root = SharePayloadLoader(
            extensionContext: extensionContext,
            onClose: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })

        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

/// Pulls text / URLs / images out of the extension context, then hands them to the UI.
private struct SharePayloadLoader: View {
    let extensionContext: NSExtensionContext?
    let onClose: () -> Void

    @State private var text = ""
    @State private var images: [Data] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                ShareSheetView(sharedText: text, sharedImages: images, onClose: onClose)
            } else {
                ZStack { ShareTheme.bg.ignoresSafeArea(); ProgressView().tint(.white) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        var collectedText: [String] = []
        var collectedImages: [Data] = []

        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            for provider in item.attachments ?? [] {
                // URL first: a shared web page offers BOTH a URL and its title as
                // plain text, and the URL is the part worth acting on.
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                        collectedText.append(url.absoluteString)
                        continue
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let s = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                        collectedText.append(s)
                        continue
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), collectedImages.count < 3 {
                    if let data = await Self.loadImageData(provider) {
                        collectedImages.append(data)
                    }
                }
            }
        }

        text = collectedText.joined(separator: "\n")
        images = collectedImages
        loaded = true
    }

    /// Images arrive as a URL, a UIImage, or raw Data depending on the source app.
    /// Downscaled and re-encoded so a 12MP screenshot doesn't ship as 8MB of base64.
    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        let raw = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        var image: UIImage?
        if let url = raw as? URL, let data = try? Data(contentsOf: url) { image = UIImage(data: data) }
        else if let ui = raw as? UIImage { image = ui }
        else if let data = raw as? Data { image = UIImage(data: data) }
        guard let image else { return nil }
        return downscale(image, maxDimension: 1600).jpegData(compressionQuality: 0.72)
    }

    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// The extension's own minimal palette. It cannot see the app's `Grok` theme (that
/// lives in the app target), and an extension this small doesn't warrant sharing it.
enum ShareTheme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let raised = Color(red: 0.09, green: 0.09, blue: 0.09)
    static let text = Color.white
    static let textDim = Color.white.opacity(0.62)
    static let textFaint = Color.white.opacity(0.34)
    static let hairline = Color.white.opacity(0.12)
    static let accent = Color.white
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.38)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct ShareSheetView: View {
    let sharedText: String
    let sharedImages: [Data]
    let onClose: () -> Void

    @State private var note = ""
    @State private var sessions: [ShareClient.Session] = []
    @State private var selected: ShareClient.Session?
    @State private var loading = true
    @State private var sending = false
    @State private var sent = false
    @State private var errorText: String?

    private var bridge: SharedConfig.Bridge? { SharedConfig.activeBridge() }
    private var client: ShareClient? {
        guard let bridge, let token = SharedConfig.token(for: bridge) else { return nil }
        return ShareClient(bridge: bridge, token: token)
    }

    /// What actually gets sent: the note, then the shared content under it.
    private var composed: String {
        let parts = [note.trimmingCharacters(in: .whitespacesAndNewlines), sharedText]
            .filter { !$0.isEmpty }
        if parts.isEmpty { return sharedImages.isEmpty ? "" : String(localized: "See the attached image.") }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ShareTheme.bg.ignoresSafeArea()
                if sent {
                    sentState
                } else if client == nil {
                    notPaired
                } else {
                    content
                }
            }
            .navigationTitle(sent ? "" : "Send to Grok")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onClose() }.foregroundStyle(ShareTheme.textDim)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !sent, client != nil {
                        Button {
                            Task { await send() }
                        } label: {
                            if sending { ProgressView().tint(.white) } else { Text("Send").fontWeight(.semibold) }
                        }
                        .foregroundStyle(canSend ? ShareTheme.text : ShareTheme.textFaint)
                        .disabled(!canSend || sending)
                    }
                }
            }
            .toolbarBackground(ShareTheme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await loadSessions() }
    }

    private var canSend: Bool {
        selected != nil && (!composed.isEmpty || !sharedImages.isEmpty)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                preview
                noteField
                sessionPicker
                if let errorText {
                    Text(errorText).font(ShareTheme.mono(12)).foregroundStyle(ShareTheme.danger)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SHARING").font(ShareTheme.mono(10, .semibold)).tracking(1.4)
                .foregroundStyle(ShareTheme.textFaint)
            if !sharedText.isEmpty {
                Text(sharedText)
                    .font(ShareTheme.mono(12))
                    .foregroundStyle(ShareTheme.textDim)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(ShareTheme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !sharedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(sharedImages.enumerated()), id: \.offset) { _, data in
                            if let ui = UIImage(data: data) {
                                Image(uiImage: ui)
                                    .resizable().scaledToFill()
                                    .frame(width: 74, height: 74)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT SHOULD GROK DO?").font(ShareTheme.mono(10, .semibold)).tracking(1.4)
                .foregroundStyle(ShareTheme.textFaint)
            TextField("", text: $note,
                      prompt: Text("optional — e.g. summarize this, or fix this error")
                          .foregroundColor(ShareTheme.textFaint),
                      axis: .vertical)
                .font(ShareTheme.mono(13))
                .foregroundStyle(ShareTheme.text)
                .lineLimit(1...5)
                .padding(12)
                .background(ShareTheme.raised)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ShareTheme.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SESSION").font(ShareTheme.mono(10, .semibold)).tracking(1.4)
                    .foregroundStyle(ShareTheme.textFaint)
                Spacer()
                if let bridge {
                    Text(bridge.name).font(ShareTheme.mono(10)).foregroundStyle(ShareTheme.textFaint)
                }
            }
            if loading {
                Text("Looking for your sessions…")
                    .font(ShareTheme.mono(12)).foregroundStyle(ShareTheme.textFaint)
            } else if sessions.isEmpty {
                Text("No sessions on this computer yet. Open TethrX and start one.")
                    .font(ShareTheme.mono(12)).foregroundStyle(ShareTheme.textFaint)
            } else {
                VStack(spacing: 6) {
                    ForEach(sessions.prefix(8)) { s in
                        Button { selected = s } label: { row(s) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func row(_ s: ShareClient.Session) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected?.id == s.id ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(selected?.id == s.id ? ShareTheme.accent : ShareTheme.textFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayName).font(ShareTheme.mono(13, .medium)).foregroundStyle(ShareTheme.text)
                    .lineLimit(1)
                if let cwd = s.cwd, !cwd.isEmpty {
                    Text((cwd as NSString).lastPathComponent)
                        .font(ShareTheme.mono(10)).foregroundStyle(ShareTheme.textFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // A running session takes the share as a follow-up rather than losing it,
            // so say that instead of hiding the option.
            if s.isRunning {
                Text("busy").font(ShareTheme.mono(9)).foregroundStyle(ShareTheme.textFaint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected?.id == s.id ? ShareTheme.raised : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected?.id == s.id ? ShareTheme.hairline : Color.clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var sentState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 38, weight: .light))
                .foregroundStyle(ShareTheme.text)
            Text(selected?.isRunning == true ? "Queued for when Grok finishes" : "Sent to Grok")
                .font(ShareTheme.mono(14, .medium)).foregroundStyle(ShareTheme.text)
            Text(selected?.displayName ?? "")
                .font(ShareTheme.mono(11)).foregroundStyle(ShareTheme.textFaint)
        }
        .padding(30)
    }

    private var notPaired: some View {
        VStack(spacing: 12) {
            Text("Not paired yet").font(ShareTheme.mono(15, .semibold)).foregroundStyle(ShareTheme.text)
            Text("Open TethrX and pair with your computer, then share again.")
                .font(ShareTheme.mono(12)).foregroundStyle(ShareTheme.textDim)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }

    // MARK: Actions

    private func loadSessions() async {
        guard let client else { loading = false; return }
        defer { loading = false }
        do {
            let list = try await client.sessions()
            sessions = list
            selected = list.first
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func send() async {
        guard let client, let target = selected else { return }
        sending = true
        errorText = nil
        defer { sending = false }
        do {
            try await client.share(sessionId: target.id, text: composed, images: sharedImages)
            sent = true
            // Leave the confirmation up briefly so it registers as "it worked".
            try? await Task.sleep(nanoseconds: 900_000_000)
            onClose()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
