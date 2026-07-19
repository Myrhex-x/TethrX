import SwiftUI
import UIKit

/// First-run setup as a 3-step wizard: run the bridge → open the pairing page →
/// scan (or type) to connect. Each step is confirmed before advancing, so it's
/// clear where the bridge, the QR, and the token come from.
struct PairingView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var focus: Field?
    @State private var showScanner = false
    @State private var step = 0

    private enum Field { case address, token }
    private let stepCount = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                card
                if let err = app.errorMessage { errorRow(err) }
                footer
            }
            .padding(24)
            .padding(.top, 24)
            .animation(.easeInOut(duration: 0.22), value: step)
        }
        .background(Grok.bg)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showScanner) {
            ScanSheet { code in showScanner = false; handleScanned(code) }
        }
        .onAppear {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-startStep"), i + 1 < args.count, let n = Int(args[i + 1]) {
                step = max(0, min(n, stepCount - 1)); return   // UI screenshots only
            }
            #endif
            // Returning / disconnected user with saved details → jump to the pair step.
            if step == 0 && !app.token.isEmpty && !app.normalizedBase.isEmpty { step = 2 }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Text(">_")
                    .font(Grok.mono(22, .bold)).foregroundStyle(Grok.accent)
                    .frame(width: 52, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Grok.hairlineStrong, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("TETHRX")
                    Text("Set up your phone").font(Grok.sans(20, .semibold)).foregroundStyle(Grok.text)
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule().fill(i <= step ? Grok.accent : Grok.hairlineStrong)
                        .frame(height: 3).frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Steps

    @ViewBuilder private var card: some View {
        switch step {
        case 0: stepBridge
        case 1: stepPage
        default: stepPair
        }
    }

    private var stepBridge: some View {
        cardShell(1, "Start the bridge on your computer") {
            para("TethrX drives Grok Build running on your computer. Install the small bridge program there and start it — it can run as an always-on service, so it's ready whenever your computer is on.")
            codeLine("node bridge/src/server.mjs")
            note("Get it, and the full setup, from the TethrX project's README on your computer.")
            nextButton("The bridge is running")
        }
    }

    private var stepPage: some View {
        cardShell(2, "Open the pairing page") {
            para("On that same computer, open this address in any browser:")
            codeLine("http://localhost:4180/pair")
            note("It shows a QR code — one for home Wi-Fi, one for Tailscale — plus your pairing token. That page only opens on the computer running the bridge, so the token stays on your machine.")
            nextButton("I see the QR code")
            backButton
        }
    }

    private var stepPair: some View {
        cardShell(3, "Pair your phone") {
            para("Point your camera at the QR code on your computer screen.")
            Button { focus = nil; showScanner = true } label: {
                Label("Scan to pair", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(PillButton(kind: .prominent))

            HStack(spacing: 12) {
                divider
                Text("or enter by hand").font(Grok.mono(11)).foregroundStyle(Grok.textFaint).fixedSize()
                divider
            }
            .padding(.vertical, 2)

            field(label: "BRIDGE ADDRESS", placeholder: "192.168.1.10:4180  or  100.x", text: $app.baseURLString, secure: false)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .address).submitLabel(.next).onSubmit { focus = .token }
            field(label: "PAIRING TOKEN", placeholder: "from the pairing page", text: $app.token, secure: true)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .token).submitLabel(.go).onSubmit { focus = nil; Task { await app.connect() } }

            Button { focus = nil; Task { await app.connect() } } label: {
                HStack(spacing: 10) {
                    if app.connecting { ProgressView().controlSize(.small).tint(.white) }
                    Text(app.connecting ? "CONNECTING" : "CONNECT").tracking(1.5)
                }
            }
            .buttonStyle(PillButton(kind: .prominent)).disabled(app.connecting)

            backButton
        }
    }

    // MARK: Card shell + pieces

    private func cardShell<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("STEP \(n) / \(stepCount)")
            Text(title).font(Grok.sans(23, .semibold)).tracking(-0.4)
                .foregroundStyle(Grok.text).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func para(_ s: String) -> some View {
        Text(s).font(Grok.sans(15)).foregroundStyle(Grok.textDim).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func note(_ s: String) -> some View {
        Text(s).font(Grok.mono(11)).foregroundStyle(Grok.textFaint).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func codeLine(_ s: String) -> some View {
        HStack(spacing: 8) {
            Text(s).font(Grok.mono(13)).foregroundStyle(Grok.text)
                .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { UIPasteboard.general.string = s } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .medium))
            }.foregroundStyle(Grok.textDim)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Grok.bg)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var divider: some View { Rectangle().fill(Grok.hairline).frame(height: 1) }

    private func nextButton(_ label: String) -> some View {
        Button { focus = nil; step = min(step + 1, stepCount - 1) } label: {
            HStack(spacing: 8) { Text(label); Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
        }
        .buttonStyle(PillButton(kind: .prominent))
    }
    private var backButton: some View {
        Button { step = max(step - 1, 0) } label: {
            Label("back", systemImage: "chevron.left").font(Grok.mono(12))
        }
        .buttonStyle(.plain).foregroundStyle(Grok.textFaint)
        .frame(maxWidth: .infinity)
    }

    private func errorRow(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
            Text(err).font(Grok.mono(12)).foregroundStyle(Grok.danger).lineSpacing(2)
        }
    }
    private var footer: some View {
        Text("A client for Grok Build · independent, not affiliated with xAI")
            .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func field(label: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(label)
            FieldBox {
                Group {
                    if secure {
                        SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Grok.textFaint))
                    } else {
                        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Grok.textFaint))
                    }
                }
                .font(Grok.mono(15))
                .foregroundStyle(Grok.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Parse a scanned `tethrx://pair?addr=…&token=…` code, fill the fields, and connect.
    private func handleScanned(_ s: String) {
        guard let c = URLComponents(string: s), c.scheme == "tethrx", c.host == "pair",
              let addr = c.queryItems?.first(where: { $0.name == "addr" })?.value,
              let tok = c.queryItems?.first(where: { $0.name == "token" })?.value,
              !addr.isEmpty, !tok.isEmpty else {
            app.errorMessage = "That doesn't look like a TethrX pairing code."
            return
        }
        app.baseURLString = addr
        app.token = tok
        Task { await app.connect() }
    }
}
