import SwiftUI
import LocalAuthentication

/// Optional Face ID / passcode gate. TethrX can run shell commands on your
/// computer, so locking the app behind biometrics is a reasonable guard.
@MainActor
final class AppLock: ObservableObject {
    @Published var locked: Bool = false
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "app.faceIDLock")
            if !enabled { locked = false }   // turning it off unlocks; turning on locks on next background
        }
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "app.faceIDLock")
        locked = UserDefaults.standard.bool(forKey: "app.faceIDLock")   // locked on cold launch when enabled
    }

    /// Human-readable name of the available biometry, for the Settings label.
    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "passcode"
        }
    }

    func lockIfEnabled() { if enabled { locked = true } }

    /// Prompt for biometrics/passcode; unlock on success. If the device has no
    /// biometrics or passcode set, don't hard-lock the user out.
    func authenticate() {
        guard enabled, locked else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock TethrX — it can run commands on your computer.") { ok, _ in
            Task { @MainActor in if ok { self.locked = false } }
        }
    }
}

/// Full-screen cover shown while the app is locked.
struct LockView: View {
    @EnvironmentObject var lock: AppLock

    var body: some View {
        ZStack {
            Grok.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                Text(">_")
                    .font(Grok.mono(30, .bold)).foregroundStyle(Grok.accent)
                    .frame(width: 68, height: 68)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Grok.hairlineStrong, lineWidth: 1))
                Text("TethrX is locked").font(Grok.sans(18, .semibold)).foregroundStyle(Grok.text)
                Button { lock.authenticate() } label: {
                    Label("Unlock", systemImage: "lock.open").frame(maxWidth: 220)
                }
                .buttonStyle(PillButton(kind: .prominent))
            }
        }
        .onAppear { lock.authenticate() }
    }
}
