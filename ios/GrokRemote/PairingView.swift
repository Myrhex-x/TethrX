import SwiftUI

/// First-run: point the app at your bridge and pair with the token the daemon prints.
struct PairingView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var focus: Field?
    @State private var showScanner = false

    private enum Field { case address, token }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                hero

                VStack(alignment: .leading, spacing: 20) {
                    field(label: "BRIDGE ADDRESS", placeholder: "192.168.1.10:4180",
                          text: $app.baseURLString, mono: true, secure: false)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .token }

                    field(label: "PAIRING TOKEN", placeholder: "shown in the daemon output",
                          text: $app.token, mono: true, secure: true)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .token)
                        .submitLabel(.go)
                        .onSubmit { focus = nil; Task { await app.connect() } }
                }

                if let err = app.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
                        Text(err).font(Grok.mono(12)).foregroundStyle(Grok.danger).lineSpacing(2)
                    }
                }

                Button {
                    focus = nil
                    Task { await app.connect() }
                } label: {
                    HStack(spacing: 10) {
                        if app.connecting {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(app.connecting ? "CONNECTING" : "CONNECT")
                            .tracking(1.5)
                    }
                }
                .buttonStyle(PillButton(kind: .prominent))
                .disabled(app.connecting)

                Button {
                    focus = nil
                    showScanner = true
                } label: {
                    Label("Scan to pair", systemImage: "qrcode.viewfinder").tracking(0.5)
                }
                .buttonStyle(PillButton(kind: .subtle))

                tips
            }
            .padding(24)
            .padding(.top, 20)
        }
        .background(Grok.bg)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showScanner) {
            ScanSheet { code in
                showScanner = false
                handleScanned(code)
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

    // MARK: Pieces

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Terminal mark — the one place the warm dusk accent appears.
            Text(">_")
                .font(Grok.mono(26, .bold))
                .foregroundStyle(Grok.accent)
                .frame(width: 60, height: 60)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairlineStrong, lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("TETHRX")
                Text("Drive Grok Build\nfrom your phone")
                    .font(Grok.sans(32, .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(Grok.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Connect to the bridge daemon on your computer to run and watch Grok sessions here.")
                    .font(Grok.sans(15))
                    .foregroundStyle(Grok.textDim)
                    .lineSpacing(3)
                Text("A client for Grok Build · independent, not affiliated with xAI")
                    .font(Grok.mono(10))
                    .foregroundStyle(Grok.textFaint)
                    .padding(.top, 2)
            }
        }
    }

    private func field(label: String, placeholder: String, text: Binding<String>,
                       mono: Bool, secure: Bool) -> some View {
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
                .font(mono ? Grok.mono(15) : Grok.sans(16))
                .foregroundStyle(Grok.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Grok.hairline).frame(height: 1).padding(.bottom, 6)
            Eyebrow("TO CONNECT")
            tip("on your computer open  localhost:4180/pair  — then tap Scan to pair above")
            tip("no camera? type the address + token the bridge prints, then tap connect")
            tip("away from home? the pair page has a Tailscale code that works anywhere")
        }
        .padding(.top, 4)
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("›").font(Grok.mono(12, .bold)).foregroundStyle(Grok.textFaint)
            Text(text).font(Grok.mono(12)).foregroundStyle(Grok.textDim).lineSpacing(3)
        }
    }
}
