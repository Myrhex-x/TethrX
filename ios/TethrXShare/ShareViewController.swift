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

/// The app's `Grok` theme, mirrored. Theme.swift lives in the app target and is not
/// compiled here, so the values are copied by hand and have to be kept in step with
/// it: this sheet appears on top of other apps, and any drift from the app reads as
/// a different product rather than as the same one.
enum ShareTheme {
    static let bg = Color.black
    static let raised = Color.white.opacity(0.05)
    static let text = Color.white
    static let textDim = Color.white.opacity(0.60)
    static let textFaint = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.10)
    static let accent = Color.white
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)

    /// Screen edge to the edge of any block, then a block's edge to its contents.
    static let gutter: CGFloat = 16
    static let pad: CGFloat = 14
    static let gap: CGFloat = 10
    static let groupGap: CGFloat = 22
    /// The one radius this surface uses, off the app's scale.
    enum R {
        static let small: CGFloat = 12
    }

    /// Reserved for what IS code: the shared payload, session names, paths.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight, design: .monospaced)
    }
    /// Everything a person reads. Both faces go through UIFontMetrics: `.system(size:)`
    /// on its own ignores the text-size setting, which left Dynamic Type inert across
    /// this whole sheet while the app itself honoured it.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight)
    }
}

/// The app's SectionLabel, mirrored here for the same reason the palette is.
private struct ShareLabel: View {
    let text: String
    /// The catalog already holds these labels in caps for every Latin language, so
    /// the value is rendered as authored: uppercasing it here would only turn the
    /// Japanese and Chinese "Grok" into "GROK".
    init(_ key: LocalizedStringResource) { self.text = String(localized: key) }

    var body: some View {
        Text(text)
            .font(ShareTheme.sans(11, .semibold))
            // Letter-spacing is a Latin device. Between Japanese or Chinese glyphs it
            // only pulls a word apart.
            .tracking(text.isCJK ? 0 : 1.7)
            .foregroundStyle(ShareTheme.textFaint)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension String {
    /// True when the string carries Han, Kana or Hangul, i.e. when Latin
    /// micro-typography should be left alone.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)      // kana
            || (0x3400...0x4DBF).contains(scalar.value)   // CJK ext A
            || (0x4E00...0x9FFF).contains(scalar.value)   // CJK unified
            || (0xF900...0xFAFF).contains(scalar.value)   // compatibility ideographs
            || (0xAC00...0xD7AF).contains(scalar.value)   // hangul
        }
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
    @State private var creating = false
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
        // Matches the app root's cap: past the first accessibility size the session
        // rows stop fitting the sheet.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task { await loadSessions() }
    }

    private var canSend: Bool {
        selected != nil && (!composed.isEmpty || !sharedImages.isEmpty)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShareTheme.groupGap) {
                preview
                noteField
                sessionPicker
                if let errorText {
                    Text(errorText).font(ShareTheme.sans(12)).foregroundStyle(ShareTheme.danger)
                }
            }
            .padding(ShareTheme.gutter)
        }
        .scrollIndicators(.hidden)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: ShareTheme.gap) {
            ShareLabel("SHARING")
            if !sharedText.isEmpty {
                // The one place mono belongs here: this is the payload, usually a URL
                // or a block of source, quoted back verbatim.
                Text(sharedText)
                    .font(ShareTheme.mono(12))
                    .foregroundStyle(ShareTheme.textDim)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ShareTheme.pad)
                    .background(ShareTheme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: ShareTheme.R.small, style: .continuous))
            }
            if !sharedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(sharedImages.enumerated()), id: \.offset) { _, data in
                            if let ui = UIImage(data: data) {
                                Image(uiImage: ui)
                                    .resizable().scaledToFill()
                                    .frame(width: 74, height: 74)
                                    .clipShape(RoundedRectangle(cornerRadius: ShareTheme.R.small, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: ShareTheme.gap) {
            ShareLabel("WHAT SHOULD GROK DO?")
            TextField("", text: $note,
                      prompt: Text("optional — e.g. summarize this, or fix this error")
                          .foregroundColor(ShareTheme.textFaint),
                      axis: .vertical)
                .font(ShareTheme.sans(13))
                .foregroundStyle(ShareTheme.text)
                .lineLimit(1...5)
                .padding(ShareTheme.pad)
                .background(ShareTheme.raised)
                .overlay(RoundedRectangle(cornerRadius: ShareTheme.R.small, style: .continuous)
                    .stroke(ShareTheme.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: ShareTheme.R.small, style: .continuous))
        }
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: ShareTheme.gap) {
            HStack {
                ShareLabel("SESSION")
                Spacer()
                if let bridge {
                    Text(bridge.name).font(ShareTheme.mono(11)).foregroundStyle(ShareTheme.textFaint)
                        .lineLimit(1)
                }
            }
            if loading {
                Text("Looking for your sessions…")
                    .font(ShareTheme.sans(12)).foregroundStyle(ShareTheme.textFaint)
            } else {
                VStack(spacing: 6) {
                    ForEach(sessions.prefix(8)) { s in
                        Button { selected = s } label: { row(s) }.buttonStyle(.plain)
                    }
                    // Without this, someone with no sessions yet (or who wants this
                    // kept separate) is told to go open the app — a dead end from
                    // inside a share sheet.
                    Button { Task { await startNewSession() } } label: { newSessionRow }
                        .buttonStyle(.plain)
                        .disabled(creating)
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
                Text("busy").font(ShareTheme.sans(11)).foregroundStyle(ShareTheme.textFaint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, ShareTheme.pad).padding(.vertical, ShareTheme.gap)
        // A session with no working directory is a single short line, which left the
        // row under the 44pt a finger needs.
        .frame(minHeight: 44)
        .background(selected?.id == s.id ? ShareTheme.raised : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: ShareTheme.R.small, style: .continuous)
            .stroke(selected?.id == s.id ? ShareTheme.hairline : Color.clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: ShareTheme.R.small, style: .continuous))
        // The unselected row draws no background, so without this only the glyph and
        // the words are tappable.
        .contentShape(Rectangle())
    }

    private var newSessionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: creating ? "circle.dotted" : "plus.circle")
                .font(.system(size: 15)).foregroundStyle(ShareTheme.textFaint)
            Text(creating ? "Starting…" : "New session")
                .font(ShareTheme.sans(13, .medium)).foregroundStyle(ShareTheme.textDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ShareTheme.pad).padding(.vertical, ShareTheme.gap)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func startNewSession() async {
        guard let client, !creating else { return }
        creating = true
        errorText = nil
        defer { creating = false }
        do {
            let fresh = try await client.createSession()
            sessions.insert(fresh, at: 0)
            selected = fresh
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var sentState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 38, weight: .light))
                .foregroundStyle(ShareTheme.text)
            Text(selected?.isRunning == true ? "Queued for when Grok finishes" : "Sent to Grok")
                .font(ShareTheme.sans(14, .medium)).foregroundStyle(ShareTheme.text)
            Text(selected?.displayName ?? "")
                .font(ShareTheme.mono(11)).foregroundStyle(ShareTheme.textFaint)
        }
        // Both lines wrap on a narrow phone, and a wrapped line under a centred
        // checkmark has to stay centred.
        .multilineTextAlignment(.center)
        .padding(30)
    }

    private var notPaired: some View {
        VStack(spacing: 12) {
            Text("Not paired yet").font(ShareTheme.sans(15, .semibold)).foregroundStyle(ShareTheme.text)
            Text("Open TethrX and pair with your computer, then share again.")
                .font(ShareTheme.sans(12)).foregroundStyle(ShareTheme.textDim)
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
