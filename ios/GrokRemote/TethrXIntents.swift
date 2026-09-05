import AppIntents
import Foundation

/// Build a client straight from the stored pairing details, so an intent can reach
/// the bridge without the app's UI ever coming up.
enum IntentBridge {
    static func client() -> BridgeClient? {
        let d = UserDefaults.standard
        var base = (d.string(forKey: "bridge.baseURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.contains("://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base) else { return nil }
        let token = d.string(forKey: "bridge.token") ?? Keychain.load() ?? ""
        guard !token.isEmpty else { return nil }
        // The pin is not optional in practice. Once the app upgrades to pinned HTTPS it
        // rewrites bridge.baseURL to https://host:port+1, and a client built without the
        // fingerprint hands that self-signed certificate to URLSession.shared, which
        // rejects it. Both shortcuts answered "couldn't reach your computer" for every
        // pinned user, which is every user.
        let pin = d.string(forKey: "bridge.pin") ?? ""
        return BridgeClient(config: .init(baseURL: url, token: token, pin: pin.isEmpty ? nil : pin))
    }
}

/// "Hey Siri, send a task to TethrX" → kicks off a Grok turn without opening the app.
/// Push notifications then tell you when it finishes or needs approval.
struct SendToGrokIntent: AppIntent {
    static var title: LocalizedStringResource = "Send a task to Grok"
    static var description = IntentDescription("Sends a prompt to your most recent Grok Build session, and leaves it running on your computer.")
    static var openAppWhenRun = false
    // This runs a command on the user's Mac. Without it, "Allow Siri When Locked" let a
    // locked phone dictate work straight past the app's own Face ID lock.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Task", requestValueDialog: "What should Grok do?")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Grok to \(\.$prompt)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = IntentBridge.client() else {
            return .result(dialog: "TethrX isn't paired with a computer yet.")
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(dialog: "There was no task to send.") }
        do {
            let sessions = try await client.listSessions()
            // Falling back to a running session guaranteed a 409 from the bridge, which
            // then surfaced as a misleading "couldn't reach your computer".
            guard let target = sessions.first(where: { !$0.isRunning }) else {
                return .result(dialog: sessions.isEmpty
                    ? "You don't have any Grok sessions yet. Start one in TethrX first."
                    : "Grok is already working on something. Try again once it's finished.")
            }
            try await client.send(sessionId: target.id, text: text)
            // The fallback used to be a bare Swift string spliced into a localized
            // frame, so it stayed English in all seven languages.
            let name = target.cwd.map { ($0 as NSString).lastPathComponent } ?? String(loc: "your session")
            return .result(dialog: "Sent to \(name). I'll notify you when Grok is done.")
        } catch {
            return .result(dialog: "Couldn't reach your computer. Check that the bridge is running.")
        }
    }
}

/// Ask what Grok is up to without unlocking into the app.
struct GrokStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Grok status"
    static var description = IntentDescription("Reports whether Grok is currently working on anything.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = IntentBridge.client() else {
            return .result(dialog: "TethrX isn't paired with a computer yet.")
        }
        do {
            let sessions = try await client.listSessions()
            let running = sessions.filter { $0.isRunning }
            // Whole sentences per case. Appending an English "s", and splicing an English
            // " and N more" into a translated frame, cannot be expressed in most of the
            // languages this app ships in.
            if running.isEmpty {
                let dialog: IntentDialog = sessions.count == 1
                    ? "Grok is idle. You have 1 session."
                    : "Grok is idle. You have \(sessions.count) sessions."
                return .result(dialog: dialog)
            }
            let names = running.compactMap { $0.cwd.map { ($0 as NSString).lastPathComponent } }
            let first = names.first ?? String(loc: "a session")
            let dialog: IntentDialog = running.count > 1
                ? "Grok is working on \(first) and \(running.count - 1) more."
                : "Grok is working on \(first)."
            return .result(dialog: dialog)
        } catch {
            return .result(dialog: "Couldn't reach your computer.")
        }
    }
}

/// Siri phrases. Free-form text can't be matched inside a phrase template, so the
/// phrase starts the intent and Siri then asks for the task itself.
struct TethrXShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToGrokIntent(),
            phrases: [
                "Send a task to \(.applicationName)",
                "New \(.applicationName) task",
            ],
            shortTitle: "Send a task",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: GrokStatusIntent(),
            phrases: [
                "What is \(.applicationName) doing",
                "Check \(.applicationName) status",
            ],
            shortTitle: "Check status",
            systemImageName: "waveform.path.ecg"
        )
    }
}
