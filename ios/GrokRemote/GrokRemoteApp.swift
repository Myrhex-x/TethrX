import SwiftUI
import ActivityKit

@main
struct TethrXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState.shared
    @StateObject private var lock = AppLock()
    @StateObject private var snippets = SnippetStore()
    @StateObject private var push = PushManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(app)
                    .environmentObject(lock)
                    .environmentObject(snippets)
                if lock.enabled && lock.locked {
                    LockView().environmentObject(lock).transition(.opacity)
                }
            }
            .tint(.white)                          // outline-pill language: white, not a color accent
            .preferredColorScheme(.dark)
            // Fonts scale with Dynamic Type (see Grok.mono/sans); cap the growth
            // so the densest layouts survive the largest accessibility sizes.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .animation(.easeInOut(duration: 0.2), value: lock.locked)
            .task {
                // The notification-action handlers are wired in the app delegate, which
                // runs even for a background launch with no scene. Only scene-scoped
                // work belongs here.
                push.refreshIfEnabled()            // re-register if the user enabled push before
                observeLiveActivities()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: lock.lockIfEnabled()   // also hides content in the app switcher
                case .active: lock.authenticate()
                default: break
                }
            }
            // The widgets deep-link in here. Tapping "waiting for your approval" on the
            // lock screen has to land on THAT session, not just on whatever the app was
            // last showing — a widget you can only look at is a widget nobody keeps.
            .onOpenURL { url in open(url) }
        }
    }

    /// `tethrx://` links from the widgets (and from anywhere else that can open a URL).
    ///   tethrx://session/<uuid>  open that conversation, switching computers if needed
    ///   tethrx://new             start a session
    /// Anything else is ignored rather than guessed at.
    private func open(_ url: URL) {
        guard url.scheme?.lowercased() == "tethrx" else { return }
        switch url.host?.lowercased() {
        case "session":
            let id = url.pathComponents.first(where: { $0 != "/" }) ?? ""
            guard !id.isEmpty else { return }
            // `pendingOpenSessionId` is the same door the push notifications use, so
            // this inherits the "look on the other paired computers" behaviour.
            app.pendingOpenSessionId = id
        case "new":
            Task { if let fresh = await app.newSession() { app.pendingOpenSessionId = fresh.id } }
        default:
            break
        }
    }

    /// Live Activity plumbing for bridge-driven lock-screen status:
    /// - the push-to-start token lets the bridge START an activity with the app
    ///   closed (iOS 17.2+);
    /// - each activity (however started) yields an update token, registered per
    ///   session so the bridge can move it through working → waiting → done.
    /// iOS launches the app briefly in the background for a push-started activity,
    /// which is what makes the update-token handoff possible at all.
    private func observeLiveActivities() {
        if #available(iOS 17.2, *) {
            Task {
                for await tokenData in Activity<TethrXActivityAttributes>.pushToStartTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await app.registerLiveActivityStart(hex)
                }
            }
        }
        Task {
            for await activity in Activity<TethrXActivityAttributes>.activityUpdates {
                let sessionId = activity.attributes.sessionId
                Task {
                    for await tokenData in activity.pushTokenUpdates {
                        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                        await app.registerLiveActivityUpdate(sessionId: sessionId, token: hex)
                    }
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ZStack {
            Grok.bg.ignoresSafeArea()
            // `switching` keeps the normal UI mounted while changing computers —
            // tearing it down mid-probe flashed the first-run wizard for seconds.
            if app.connected || app.demoMode || app.switching {
                // iPad (and big landscape phones) get a real sidebar + chat split;
                // iPhone keeps the stack.
                if hSize == .regular {
                    SplitRootView()
                } else {
                    SessionListView()
                }
            } else if app.bootstrapping {
                ReconnectSplash()
            } else {
                // Not a setup checklist: the welcome screen is usable on its own,
                // and pairing a computer is one route out of it among several.
                WelcomeView()
            }
        }
        .task {
            await app.handleLaunchArguments()
            await app.bootstrap()          // reconnect from saved credentials
        }
    }
}

/// iPad layout: the session list as a sidebar, the conversation as the detail.
struct SplitRootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var lock: AppLock
    @EnvironmentObject var snippets: SnippetStore
    @State private var selected: SessionInfo?

    var body: some View {
        NavigationSplitView {
            SessionListView(onSelect: { session in selected = session })
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            if let selected, app.demoMode {
                NavigationStack {
                    ChatView(vm: ChatViewModel(demoSession: selected))
                }
                .id(selected.id)
            } else if let selected, let client = app.client {
                NavigationStack {
                    ChatView(vm: ChatViewModel(client: client, session: selected))
                }
                .id(selected.id)   // a fresh view model per session
            } else {
                ZStack {
                    Grok.bg.ignoresSafeArea()
                    VStack(spacing: 14) {
                        TethrXMark(size: 34, color: .white.opacity(0.25))
                        Text("Pick a session").font(Grok.mono(12)).foregroundStyle(Grok.textFaint)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: app.pendingOpenSessionId) { _, _ in openPending() }
        .onChange(of: app.sessions) { _, _ in openPending() }
        .task { openPending() }
    }

    private func openPending() {
        guard let id = app.pendingOpenSessionId else { return }
        guard let session = app.sessions.first(where: { $0.id == id }) else {
            Task { await app.locateAndOpen(id) }
            return
        }
        app.pendingOpenSessionId = nil
        selected = session
    }
}

/// Shown briefly on launch while we reconnect from saved credentials.
struct ReconnectSplash: View {
    @EnvironmentObject var app: AppState
    /// After a few seconds the wait needs an exit — a fallback probe can take ~20s,
    /// and a spinner with no way out reads as a hang.
    @State private var takingLong = false

    var body: some View {
        VStack(spacing: 18) {
            TethrXMark(size: 40)
                .frame(width: 68, height: 68)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Grok.hairlineStrong, lineWidth: 1))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Reconnecting…").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            }
            .accessibilityElement(children: .combine)
            if takingLong {
                VStack(spacing: 10) {
                    Text("Still trying to reach your computer.")
                        .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                    Button {
                        app.disconnect()          // stop waiting; land on pairing with saved details intact
                        app.bootstrapping = false
                    } label: {
                        Text("Stop and set up manually").font(Grok.mono(12))
                    }
                    .buttonStyle(PillButton(kind: .subtle))
                }
                .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            withAnimation(.easeInOut(duration: 0.25)) { takingLong = true }
        }
    }
}
