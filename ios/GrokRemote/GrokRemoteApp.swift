import SwiftUI

@main
struct TethrXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()
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
            .animation(.easeInOut(duration: 0.2), value: lock.locked)
            .task {
                push.onToken = { token in Task { await app.registerDevice(token) } }
                push.refreshIfEnabled()            // re-register if the user enabled push before
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: lock.lockIfEnabled()   // also hides content in the app switcher
                case .active: lock.authenticate()
                default: break
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            Grok.bg.ignoresSafeArea()
            if app.connected {
                SessionListView()
            } else if app.bootstrapping {
                ReconnectSplash()
            } else {
                PairingView()
            }
        }
        .task {
            await app.handleLaunchArguments()
            await app.bootstrap()          // reconnect from saved credentials
        }
    }
}

/// Shown briefly on launch while we reconnect from saved credentials.
struct ReconnectSplash: View {
    var body: some View {
        VStack(spacing: 18) {
            TethrXMark(size: 40)
                .frame(width: 68, height: 68)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Grok.hairlineStrong, lineWidth: 1))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Reconnecting…").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            }
        }
    }
}
