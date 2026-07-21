import Foundation

/// Canned data behind "Try the demo" on the pairing screen: the whole app is
/// browsable with zero hardware — for the curious person who hasn't set up the
/// bridge yet, and for App Review, whose reviewer has no Mac running one.
/// Nothing here touches the network.
enum DemoData {
    static let health = HealthInfo(
        ok: true, name: "TethrX", host: "demo-mac",
        grok: "grok 0.2.106", grokAvailable: true,
        version: AppState.wantedBridgeVersion, latestVersion: nil, tls: nil
    )

    static var sessions: [SessionInfo] {
        var richUsage = SessionUsage()
        richUsage.turns = 6
        richUsage.inputTokens = 231_400
        richUsage.outputTokens = 18_250
        richUsage.reasoningTokens = 9_900
        richUsage.totalTokens = 259_550
        richUsage.contextTokens = 61_000
        richUsage.contextWindow = 500_000
        richUsage.costUsdTicks = 4_100_000_000   // $0.41
        richUsage.lastModelId = "grok-4.5"

        var lightUsage = SessionUsage()
        lightUsage.turns = 2
        lightUsage.totalTokens = 41_200
        lightUsage.contextTokens = 12_000
        lightUsage.contextWindow = 500_000

        return [
            SessionInfo(id: "demo-settings-dark", title: "Dark mode for settings", folder: "Acme app",
                        cwd: "/Users/you/acme-app", model: nil, transport: "acp",
                        planMode: false, effort: "", autoApprove: false,
                        status: "idle", turnCount: 6, createdAt: "2026-07-21T09:12:00Z",
                        lastEventId: 40, usage: richUsage),
            SessionInfo(id: "demo-flaky-test", title: "Hunt the flaky auth test", folder: "Acme app",
                        cwd: "/Users/you/acme-app", model: nil, transport: "acp",
                        planMode: false, effort: "high", autoApprove: true,
                        status: "running", turnCount: 3, createdAt: "2026-07-21T08:03:00Z",
                        lastEventId: 21, usage: lightUsage),
            SessionInfo(id: "demo-landing", title: "New session", folder: nil,
                        cwd: "/Users/you/landing-page", model: nil, transport: "acp",
                        planMode: true, effort: "", autoApprove: false,
                        status: "idle", turnCount: 1, createdAt: "2026-07-20T17:40:00Z",
                        lastEventId: 8, usage: lightUsage),
        ]
    }

    static func freshSession(cwd: String) -> SessionInfo {
        SessionInfo(id: "demo-" + UUID().uuidString, title: "New session", folder: nil,
                    cwd: cwd.isEmpty ? "/Users/you/project" : cwd, model: nil, transport: "acp",
                    planMode: false, effort: "", autoApprove: false,
                    status: "idle", turnCount: 0, createdAt: "2026-07-21T10:00:00Z",
                    lastEventId: 0, usage: nil)
    }

    /// The showcase conversation for the first demo session.
    static var transcript: [ChatItem] {
        var items: [ChatItem] = []
        items.append(ChatItem(role: .user, text: "Add a dark mode toggle to the settings screen, and make sure it persists."))
        items.append(ChatItem(role: .thought, text: "The settings screen is SettingsView.swift. I'll add an @AppStorage-backed toggle and wire the color scheme at the root so it applies everywhere."))

        var read = ChatItem(role: .tool, text: "read_file SettingsView.swift")
        read.toolCallId = "demo-t1"
        read.toolStatus = "completed"
        items.append(read)

        var edit = ChatItem(role: .tool, text: "edit SettingsView.swift")
        edit.toolCallId = "demo-t2"
        edit.toolStatus = "completed"
        edit.diff = FileDiff(
            path: "Sources/SettingsView.swift",
            oldText: "Section(\"Appearance\") {\n}",
            newText: "Section(\"Appearance\") {\n    Toggle(\"Dark mode\", isOn: $darkMode)\n}"
        )
        items.append(edit)

        var permission = ChatItem(role: .permission, text: "swift build")
        permission.requestId = "demo-p1"
        permission.options = [
            PermissionOption(optionId: "allow", name: "Yes, run it", kind: "allow_once"),
            PermissionOption(optionId: "reject", name: "No", kind: "reject_once"),
        ]
        permission.decided = "allow"
        items.append(permission)

        var build = ChatItem(role: .tool, text: "swift build")
        build.toolCallId = "demo-t3"
        build.toolStatus = "completed"
        build.toolOutput = "Building for debugging...\nBuild complete! (2.41s)"
        items.append(build)

        items.append(ChatItem(role: .assistant, text: """
        Done. The settings screen now has a **Dark mode** toggle that persists across launches:

        ```swift
        @AppStorage("darkMode") private var darkMode = false
        ```

        The scheme is applied at the root view, so every screen follows it. The build passes.
        """))
        items.append(ChatItem(role: .status, text: "· end_turn ·"))
        return items
    }

    /// What "grok" says when you send a message inside the demo.
    static let cannedReply = """
    This is the demo, so no real computer is connected — but this is exactly where Grok would \
    work: streaming its thinking, running tools you approve, and editing files on your machine. \
    Pair your own computer from the setup screen to run real tasks.
    """
}
