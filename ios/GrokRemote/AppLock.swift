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

    /// Name of the available biometry, for the Settings label. "Face ID" and
    /// "Touch ID" are brand names and stay English everywhere. With no biometry
    /// this is empty rather than a word: dropping a bare English noun into the
    /// translated "Require %@" sentence read as half-translated, and the noun a
    /// passcode needs differs per language anyway, so the caller picks a whole
    /// sentence instead.
    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return ""
        }
    }

    func lockIfEnabled() { if enabled { locked = true; promptOwed = true } }

    /// One evaluation at a time: a cold launch asked twice at once (the cover's
    /// onAppear and the scene turning active).
    private var authenticating = false
    /// The automatic prompt is owed once per lock. The Face ID sheet itself makes the
    /// scene inactive and active again, so cancelling it used to bring it straight
    /// back, forever; after a cancel the Unlock button is the way in.
    private var promptOwed = true

    /// Prompt for biometrics/passcode; unlock on success. If the device has no
    /// biometrics or passcode set, don't hard-lock the user out.
    func authenticate(automatic: Bool = false) {
        guard enabled, locked, !authenticating else { return }
        if automatic {
            guard promptOwed else { return }
            promptOwed = false
        }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        authenticating = true
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: String(loc: "Unlock TethrX. It can run commands on your computer.")) { ok, _ in
            Task { @MainActor in
                self.authenticating = false
                if ok { self.locked = false }
            }
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
                TethrXMark(size: 44)
                Text("TethrX is locked").font(Grok.sans(18, .semibold)).foregroundStyle(Grok.text)
                Button { lock.authenticate() } label: {
                    Label("Unlock", systemImage: "lock.open").frame(maxWidth: 220)
                }
                .buttonStyle(PillButton(kind: .prominent))
            }
        }
        .onAppear { lock.authenticate(automatic: true) }
    }
}
