import SwiftUI
import ActivityKit

@main
struct TethrXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState.shared
    @StateObject private var lock = AppLock()
    @StateObject private var snippets = SnippetStore()
    @StateObject private var push = PushManager.shared
    @StateObject private var language = AppLanguage.shared
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
            .environmentObject(language)
            // The language is chosen in this app's own settings, not only in iOS's.
            // The locale carries dates, numbers and plural agreement; the id forces a
            // rebuild so every string already on screen is resolved again out of the
            // newly chosen .lproj instead of waiting for the next relaunch.
            .environment(\.locale, language.locale)
            .id(language.code)
            .grokScheme()
            // Fonts scale with Dynamic Type (see Grok.mono/sans); cap the growth
            // so the densest layouts survive the largest accessibility sizes.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .animation(.easeInOut(duration: 0.2), value: lock.locked)
            .task {
                // The notification-action handlers are wired in the app delegate, which
                // runs even for a background launch with no scene. Only scene-scoped
                // work belongs here.
                push.refreshIfEnabled()            // re-register if the user enabled push before
                // Live Activity tokens are observed from the app delegate, which also runs
                // for the background launch that delivers a push-started card's token.
                // Activating early matters: a watch that asks for a snapshot wakes the
                // phone in the background, and the session must already be listening.
                WatchLink.shared.start()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: lock.lockIfEnabled()   // also hides content in the app switcher
                case .active: lock.authenticate(automatic: true)
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
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            Grok.bg.ignoresSafeArea()
            // `switching` keeps the normal UI mounted while changing computers —
            // tearing it down mid-probe flashed the first-run wizard for seconds.
            if app.connected || app.demoMode || app.switching {
                // iPad gets a real sidebar + chat split; iPhone keeps the stack. Decided
                // by the device, not the size class: a Max-size iPhone turns .regular
                // in landscape, and swapping the whole layout on rotation threw away
                // the open conversation and whatever was typed into it.
                if UIDevice.current.userInterfaceIdiom == .pad {
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
                        TethrXMark(size: 34, color: Grok.ink.opacity(0.25))
                        Text("Pick a session").font(Grok.sans(15)).foregroundStyle(Grok.textFaint)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selected) { _, now in
            guard let id = app.unusedSessionId, now?.id != id else { return }
            Task { await app.discardUnusedSession() }
        }
        .onChange(of: app.pendingOpenSessionId) { _, _ in openPending() }
        .onChange(of: app.sessions) { _, list in
            openPending()
            // Deleted (here or on another device) while open in the detail column: its
            // stream ended in a 404, and the composer kept taking messages that could
            // only fail. A switch is handled below; this is the session going away.
            if let open = selected, !app.switching, !list.contains(where: { $0.id == open.id }) {
                selected = nil
            }
        }
        // The detail column belongs to the computer it was opened on. Left in place
        // across a switch it kept streaming from the old one through the old client.
        .onChange(of: app.activeBridgeId) { _, _ in selected = nil }
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
            TethrXMark(size: 44)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Grok.ink)
                Text("Reconnecting…").font(Grok.sans(15)).foregroundStyle(Grok.textDim)
            }
            .accessibilityElement(children: .combine)
            if takingLong {
                VStack(spacing: 10) {
                    Text("Still trying to reach your computer.")
                        .font(Grok.sans(14)).foregroundStyle(Grok.textFaint)
                    Button {
                        app.disconnect()          // stop waiting; land on pairing with saved details intact
                        app.bootstrapping = false
                    } label: {
                        Text("Stop and set up manually").font(Grok.sans(15))
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
