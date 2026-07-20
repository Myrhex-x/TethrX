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
        return BridgeClient(config: .init(baseURL: url, token: token))
    }
}

/// "Hey Siri, send a task to TethrX" → kicks off a Grok turn without opening the app.
/// Push notifications then tell you when it finishes or needs approval.
struct SendToGrokIntent: AppIntent {
    static var title: LocalizedStringResource = "Send a task to Grok"
    static var description = IntentDescription("Sends a prompt to your most recent Grok Build session, and leaves it running on your computer.")
    static var openAppWhenRun = false

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
            guard let target = sessions.first(where: { !$0.isRunning }) ?? sessions.first else {
                return .result(dialog: "You don't have any Grok sessions yet. Start one in TethrX first.")
            }
            try await client.send(sessionId: target.id, text: text)
            let name = target.cwd.map { ($0 as NSString).lastPathComponent } ?? "your session"
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
            if running.isEmpty {
                return .result(dialog: "Grok is idle. You have \(sessions.count) session\(sessions.count == 1 ? "" : "s").")
            }
            let names = running.compactMap { $0.cwd.map { ($0 as NSString).lastPathComponent } }
            return .result(dialog: "Grok is working on \(names.first ?? "a session")\(running.count > 1 ? " and \(running.count - 1) more" : "").")
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
