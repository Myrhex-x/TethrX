import SwiftUI

/// Pair an additional computer from Settings — no need to disconnect from the one
/// you're already on. If the new credentials don't connect, AppState puts the
/// previous computer back, so a failed attempt can't strand you.
struct AddComputerSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = BridgeDiscovery()

    @State private var address = ""
    @State private var pairingToken = ""
    @State private var showScanner = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("On the other computer, start the bridge and open its pairing page, then scan the code below.")
                        .font(Grok.sans(15)).foregroundStyle(Grok.textDim).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    codeLine("http://localhost:4180/pair")

                    Button { showScanner = true } label: {
                        Label("Scan to pair", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(PillButton(kind: .prominent))

                    if !discovery.found.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow("NEARBY")
                            ForEach(discovery.found) { bridge in
                                Button {
                                    Haptics.tap()
                                    address = bridge.address
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "desktopcomputer").font(.system(size: 13)).foregroundStyle(Grok.textDim)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(bridge.name).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1)
                                            Text(bridge.address).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                                        }
                                        Spacer(minLength: 0)
                                        if address == bridge.address {
                                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Grok.accent)
                                        }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(Grok.raised)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Found on your network. Tap to fill the address — then enter that computer's token.")
                                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                        }
                    }

                    HStack(spacing: 12) {
                        divider
                        Text("or enter by hand").font(Grok.mono(11)).foregroundStyle(Grok.textFaint).fixedSize()
                        divider
                    }

                    field("BRIDGE ADDRESS", "192.168.1.10:4180", $address, secure: false)
                    field("PAIRING TOKEN", "from the pairing page", $pairingToken, secure: true)

                    if let failure {
                        HStack(alignment: .top, spacing: 8) {
                            Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
                            Text(failure).font(Grok.mono(12)).foregroundStyle(Grok.danger).lineSpacing(2)
                        }
                    }

                    Button { Task { await add() } } label: {
                        HStack(spacing: 10) {
                            if working { ProgressView().controlSize(.small).tint(.white) }
                            Text(working ? "CONNECTING" : "ADD COMPUTER").tracking(1.4)
                        }
                    }
                    .buttonStyle(PillButton(kind: .prominent))
                    .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty
                              || pairingToken.trimmingCharacters(in: .whitespaces).isEmpty)

                    Text("Adding a computer switches to it. Your other computers stay paired — swap between them any time.")
                        .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(3)
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add computer")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Grok.textDim)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScanner) {
            ScanSheet { code in showScanner = false; handleScanned(code) }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var divider: some View { Rectangle().fill(Grok.hairline).frame(height: 1) }

    @State private var scannedPin = ""   // cert fingerprint from the QR, if present

    private func add() async {
        working = true
        failure = nil
        defer { working = false }
        let ok = await app.addComputer(address: address.trimmingCharacters(in: .whitespaces),
                                       pairingToken: pairingToken.trimmingCharacters(in: .whitespaces),
                                       pin: scannedPin)
        if ok {
            Haptics.success()
            dismiss()
        } else {
            failure = app.errorMessage ?? "Couldn't reach that computer. Check the address and that its bridge is running."
        }
    }

    private func handleScanned(_ code: String) {
        guard let c = URLComponents(string: code), c.scheme == "tethrx", c.host == "pair",
              let addr = c.queryItems?.first(where: { $0.name == "addr" })?.value,
              let tok = c.queryItems?.first(where: { $0.name == "token" })?.value,
              !addr.isEmpty, !tok.isEmpty else {
            failure = "That doesn't look like a TethrX pairing code."
            return
        }
        let fp = c.queryItems?.first(where: { $0.name == "fp" })?.value ?? ""
        let tlsPort = c.queryItems?.first(where: { $0.name == "tls" })?.value ?? ""
        if !fp.isEmpty, !tlsPort.isEmpty, let host = addr.split(separator: ":").first {
            address = "https://\(host):\(tlsPort)"
            scannedPin = fp
        } else {
            address = addr
            scannedPin = ""
        }
        pairingToken = tok
        Task { await add() }
    }

    private func codeLine(_ s: String) -> some View {
        Text(s).font(Grok.mono(13)).foregroundStyle(Grok.text)
            .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Grok.raised)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(label)
            FieldBox {
                Group {
                    if secure {
                        SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Grok.textFaint))
                    } else {
                        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Grok.textFaint))
                            .keyboardType(.URL)
                    }
                }
                .font(Grok.mono(15))
                .foregroundStyle(Grok.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
