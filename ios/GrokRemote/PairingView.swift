import SwiftUI
import UIKit

/// First-run setup as a precise, branching wizard. Prerequisites (Grok Build,
/// Node, the bridge) → start the bridge → choose Wi-Fi or Tailscale (which adds
/// its own steps) → open the pairing page → scan the matching QR (or type it).
struct PairingView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var discovery = BridgeDiscovery()
    @FocusState private var focus: Field?
    @State private var showScanner = false
    @State private var idx = 0
    @State private var path: NetPath = .undecided

    private enum Field { case address, token }
    private enum NetPath { case undecided, wifi, tailscale }
    private enum WStep { case grok, node, run, choose, tsMac, tsPhone, page, scan }

    /// The ordered steps — the tail depends on the chosen network path.
    private var steps: [WStep] {
        let base: [WStep] = [.grok, .node, .run, .choose]
        let tail: [WStep] = path == .tailscale ? [.tsMac, .tsPhone, .page, .scan] : [.page, .scan]
        return base + tail
    }
    private var current: WStep { steps[max(0, min(idx, steps.count - 1))] }
    private var firstTailIndex: Int { 4 }   // index right after `choose`

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if idx == 0, !app.token.isEmpty, !app.normalizedBase.isEmpty { reconnectShortcut }
                card
                if let err = app.errorMessage { errorRow(err) }
                footer
            }
            .padding(24)
            .padding(.top, 24)
            .animation(.easeInOut(duration: 0.22), value: idx)
            .animation(.easeInOut(duration: 0.22), value: path)
        }
        .background(Grok.bg)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showScanner) {
            ScanSheet { code in showScanner = false; handleScanned(code) }
        }
        .onAppear {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-tsPath") { path = .tailscale }
            if let i = args.firstIndex(of: "-startStep"), i + 1 < args.count, let n = Int(args[i + 1]) {
                idx = max(0, min(n, steps.count - 1))
            }
            #endif
            // Always start at step 1. Returning users get the Reconnect shortcut below.
        }
        .onChange(of: current) { _, step in
            // Browse only on the scan step, where an address is actually wanted.
            if step == .scan { discovery.start() } else { discovery.stop() }
        }
        .onDisappear { discovery.stop() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                TethrXMark(size: 30)
                    .frame(width: 52, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Grok.hairlineStrong, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("TETHRX")
                    Text("Set up your phone").font(Grok.sans(20, .semibold)).foregroundStyle(Grok.text)
                }
            }
            HStack(spacing: 5) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule().fill(i <= idx ? Grok.accent : Grok.hairlineStrong)
                        .frame(height: 3).frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Steps

    @ViewBuilder private var card: some View {
        switch current {
        case .grok:
            cardShell("Install Grok Build") {
                para("TethrX drives Grok Build — xAI's terminal coding agent. Install it on your computer and run it once to sign in.")
                codeLine("grok --version")
                note("That should print a version once it's installed and you're signed in.")
                nav("Grok Build is installed")
            }
        case .node:
            cardShell("Install Node.js") {
                para("The bridge runs on Node.js 20 or newer. Install it from nodejs.org if you don't already have it.")
                codeLine("node --version")
                note("Should print v20 or higher.")
                nav("Node is installed")
            }
        case .run:
            cardShell("Start the bridge") {
                para("One command downloads and starts the bridge on your computer. It prints a pairing token and keeps running — leave it going.")
                codeLine("npx tethrx-bridge")
                note("Want it always-on? Install once with  npm i -g tethrx-bridge  then run  tethrx-bridge.")
                nav("The bridge is running")
            }
        case .choose:
            cardShell("How will your phone reach it?") {
                para("Pick how this phone connects to the bridge:")
                choice("Same Wi-Fi", "phone + computer on one network — simplest") { path = .wifi; idx = firstTailIndex }
                choice("From anywhere", "works on cellular too, via Tailscale") { path = .tailscale; idx = firstTailIndex }
                if idx > 0 { backButton }
            }
        case .tsMac:
            cardShell("Install Tailscale on your computer") {
                para("Tailscale is a free private network that links this phone to your computer from anywhere. Install it on your computer, then sign in to create a free account — you can use Google, Apple, GitHub, or email.")
                note("Get it from the Mac App Store or tailscale.com/download. Once you're signed in, a menu-bar icon shows it's connected.")
                nav("Installed and signed in")
            }
        case .tsPhone:
            cardShell("Install Tailscale on this phone") {
                para("Now install Tailscale from the App Store on this phone and sign in with the same account you just used on your computer. Using the same account on both is what links the two devices.")
                note("Open the Tailscale app and check that both your computer and this phone show up in the list and appear connected.")
                nav("Signed in with the same account")
            }
        case .page:
            cardShell("Open the pairing page") {
                para("On your computer, open this address in any browser:")
                codeLine("http://localhost:4180/pair")
                note("It shows two QR codes — one for Wi-Fi, one for Tailscale — plus your token. It only opens on the computer running the bridge.")
                nav("I see the QR codes")
            }
        case .scan:
            cardShell(path == .tailscale ? "Scan the Tailscale code" : "Scan the Wi-Fi code") {
                para(path == .tailscale
                     ? "On the pairing page, tap Scan to pair and aim at the code labelled TAILSCALE."
                     : "On the pairing page, tap Scan to pair and aim at the code labelled WI-FI / LAN.")
                Button { focus = nil; showScanner = true } label: {
                    Label("Scan to pair", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PillButton(kind: .prominent))

                // Bridges advertising themselves on this network — tap to fill the
                // address, then only the token is left to enter.
                if path == .wifi, !discovery.found.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("FOUND NEARBY")
                        ForEach(discovery.found) { bridge in
                            Button {
                                Haptics.tap()
                                app.baseURLString = bridge.address
                                focus = .token
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "desktopcomputer").font(.system(size: 13)).foregroundStyle(Grok.textDim)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bridge.name).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1)
                                        Text(bridge.address).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                                    }
                                    Spacer(minLength: 0)
                                    if app.baseURLString == bridge.address {
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Grok.accent)
                                    }
                                }
                                .padding(12)
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Grok.hairlineStrong, lineWidth: 1))
                                .contentShape(RoundedRectangle(cornerRadius: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack(spacing: 12) {
                    divider
                    Text("or enter by hand").font(Grok.mono(11)).foregroundStyle(Grok.textFaint).fixedSize()
                    divider
                }
                .padding(.vertical, 2)

                field(label: "BRIDGE ADDRESS", placeholder: path == .tailscale ? "100.x.y.z:4180" : "192.168.1.10:4180", text: $app.baseURLString, secure: false)
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
    }

    // MARK: Card shell + pieces

    private func cardShell<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("STEP \(idx + 1) / \(steps.count)")
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
    private func codeLine(_ s: String) -> some View { CopyableCode(text: s) }
    private var divider: some View { Rectangle().fill(Grok.hairline).frame(height: 1) }

    private func choice(_ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Grok.sans(16, .semibold)).foregroundStyle(Grok.text)
                    Text(sub).font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Grok.textFaint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Grok.hairlineStrong, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

    /// Advance control: a "completed" pill, plus a back link when not on step 1.
    @ViewBuilder private func nav(_ label: String) -> some View {
        Button { focus = nil; Haptics.tap(.medium); idx = min(idx + 1, steps.count - 1) } label: {
            HStack(spacing: 8) { Text(label); Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
        }
        .buttonStyle(PillButton(kind: .prominent))
        if idx > 0 { backButton }
    }
    private var backButton: some View {
        Button { path = idx == firstTailIndex ? .undecided : path; idx = max(idx - 1, 0) } label: {
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

    /// Shown on step 1 when credentials are already saved — a tidy "welcome back"
    /// card so returning users reconnect in one tap instead of walking the wizard.
    private var reconnectShortcut: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14)).foregroundStyle(Grok.textDim)
                Text("Welcome back").font(Grok.sans(16, .semibold)).foregroundStyle(Grok.text)
            }
            Text("This phone is already paired. Reconnect to the same computer — or set it up again below.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                focus = nil
                Haptics.tap()
                Task { await app.connect() }
            } label: {
                HStack(spacing: 9) {
                    if app.connecting {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .bold))
                    }
                    Text(app.connecting ? "Reconnecting…" : "Reconnect").tracking(0.3)
                }
            }
            .buttonStyle(PillButton(kind: .prominent))
            .disabled(app.connecting)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

/// A monospaced command row with a copy button that flips to a checkmark on tap.
private struct CopyableCode: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(Grok.mono(13)).foregroundStyle(Grok.text)
                .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = text
                Haptics.tap()
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    withAnimation(.easeIn(duration: 0.2)) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? Grok.accent : Grok.textDim)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Grok.bg)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
