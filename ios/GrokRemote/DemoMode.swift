import Foundation

/// Canned data behind "Try the demo" on the pairing screen: the whole app is
/// browsable with zero hardware — for the curious person who hasn't set up the
/// bridge yet, and for App Review, whose reviewer has no Mac running one.
/// Nothing here touches the network.
enum DemoData {
    static let health = HealthInfo(
        ok: true, name: "TethrX", host: "demo-mac",
        grok: "grok 1.0.0", grokAvailable: true,
        version: AppState.wantedBridgeVersion, latestVersion: nil, tls: nil
    )

    /// An ISO timestamp `seconds` ago, so the tour's RUNNING and WAITING rows carry a
    /// believable stopwatch instead of a date from whenever this file was written.
    static func ago(_ seconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-seconds))
    }

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
                        status: "idle", turnCount: 6, createdAt: "2026-07-21T09:12:00Z", updatedAt: ago(2700),
                        lastEventId: 40, usage: richUsage),
            // Deliberately blocked on an approval, not merely running: "waiting for you"
            // is the state the app exists to surface, so the tour has to show it.
            SessionInfo(id: "demo-flaky-test", title: "Hunt the flaky auth test", folder: "Acme app",
                        cwd: "/Users/you/acme-app", model: nil, transport: "acp",
                        planMode: false, effort: "high", autoApprove: false,
                        approvalPolicy: "reads",
                        status: "running",
                        waiting: WaitingState(kind: "permission", label: "rm -rf .build", since: ago(74),
                                             requestId: "demo-p2", allow: "allow", deny: "reject"),
                        turnCount: 3, runningSince: ago(212), createdAt: "2026-07-21T08:03:00Z", updatedAt: ago(74),
                        lastEventId: 21, usage: lightUsage),
            SessionInfo(id: "demo-landing", title: "New session", folder: nil,
                        cwd: "/Users/you/landing-page", model: nil, transport: "acp",
                        planMode: true, effort: "", autoApprove: false,
                        status: "idle", turnCount: 1, createdAt: "2026-07-20T17:40:00Z", updatedAt: ago(93_600),
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
            oldText: """
            struct SettingsView: View {
                @EnvironmentObject var settings: Settings

                var body: some View {
                    Form {
                        Section("Appearance") {
                            Picker("Accent", selection: $settings.accent) {
                                ForEach(Accent.allCases) { Text($0.name).tag($0) }
                            }
                        }
                        Section("About") {
                            LabeledContent("Version", value: Bundle.main.version)
                        }
                    }
                }
            }
            """,
            newText: """
            struct SettingsView: View {
                @EnvironmentObject var settings: Settings
                @AppStorage("darkMode") private var darkMode = false

                var body: some View {
                    Form {
                        Section("Appearance") {
                            Toggle("Dark mode", isOn: $darkMode)
                            Picker("Accent", selection: $settings.accent) {
                                ForEach(Accent.allCases) { Text($0.name).tag($0) }
                            }
                        }
                        Section("About") {
                            LabeledContent("Version", value: Bundle.main.version)
                        }
                    }
                }
            }
            """
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

    /// The flaky-test session: listed as RUNNING, so its transcript ends mid-work —
    /// an empty screen under a "running" badge read as broken.
    static var flakyTranscript: [ChatItem] {
        var items: [ChatItem] = []
        items.append(ChatItem(role: .user, text: "The auth test fails once every ~20 CI runs. Find out why and fix it."))
        items.append(ChatItem(role: .thought, text: "Intermittent auth failures usually mean a time or ordering dependency. I'll re-run the test in isolation, then look for shared state."))

        var run = ChatItem(role: .tool, text: "swift test --filter AuthTests")
        run.toolCallId = "demo-f1"
        run.toolStatus = "completed"
        run.toolOutput = "Test Suite 'AuthTests' passed.\n17 tests, 0 failures (3.02s)"
        items.append(run)

        items.append(ChatItem(role: .assistant, text: "Passes in isolation — so it's interference from another test. Checking what else touches the token store…"))

        var grep = ChatItem(role: .tool, text: "grep -r TokenStore Tests/")
        grep.toolCallId = "demo-f2"
        grep.toolStatus = "completed"
        grep.toolOutput = "Tests/AuthTests.swift:14: TokenStore.shared.reset()\nTests/ProfileTests.swift:9: TokenStore.shared.seed(.expired)"
        items.append(grep)

        // Grok's own checklist, with a step in flight — this is what the app shows
        // live while a long task runs.
        var tasks = ChatItem(role: .tasks, text: "")
        tasks.planEntries = [
            PlanEntry(id: 0, content: "Re-run AuthTests in isolation", status: "completed"),
            PlanEntry(id: 1, content: "Find everything that touches TokenStore", status: "completed"),
            PlanEntry(id: 2, content: "Reproduce the ordering failure locally", status: "in_progress"),
            PlanEntry(id: 3, content: "Reset the shared store between tests", status: "pending"),
            PlanEntry(id: 4, content: "Run the suite 50 times to confirm", status: "pending"),
        ]
        items.append(tasks)

        items.append(ChatItem(role: .assistant, text: "ProfileTests seeds an expired token into the shared store and never clears it. I'll reproduce it from a clean build."))

        // Undecided, and destructive: the approval card is the whole product, and the
        // tour used to show only one that had already been answered.
        var ask = ChatItem(role: .permission, text: "rm -rf .build")
        ask.requestId = "demo-p2"
        ask.options = [
            PermissionOption(optionId: "allow", name: "Yes, run it", kind: "allow_once"),
            PermissionOption(optionId: "reject", name: "No, and tell Grok why", kind: "reject_once"),
        ]
        items.append(ask)
        return items
    }

    /// The plan-mode session: one turn in, waiting on a plan review.
    static var landingTranscript: [ChatItem] {
        var items: [ChatItem] = []
        items.append(ChatItem(role: .user, text: "Rework the landing page hero: bolder headline, one clear call to action."))
        var plan = ChatItem(role: .plan, text: """
        1. Replace the two stacked CTAs with a single primary button
        2. Raise the headline to 56px, tighten line height
        3. Move the screenshot below the fold on mobile
        4. Re-run Lighthouse and compare
        """)
        plan.requestId = "demo-plan1"
        items.append(plan)
        return items
    }

    /// Transcript for a demo session id (nil = starts empty).
    static func transcript(for id: String) -> [ChatItem]? {
        switch id {
        case "demo-settings-dark": return transcript
        case "demo-flaky-test":    return flakyTranscript
        case "demo-landing":       return landingTranscript
        default:                   return nil
        }
    }

    /// What "grok" says when you send a message inside the tour.
    static let cannedReply = """
    You're in the tour, so no real computer is connected — but this is exactly where Grok would \
    work: streaming its thinking, running tools you approve, and editing files on your machine. \
    Connect your own computer to run real tasks.
    """
}
