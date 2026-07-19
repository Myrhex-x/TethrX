import SwiftUI

@main
struct TethrXApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .tint(.white)                      // outline-pill language: white, not a color accent
                .preferredColorScheme(.dark)
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
            Text(">_")
                .font(Grok.mono(30, .bold))
                .foregroundStyle(Grok.accent)
                .frame(width: 68, height: 68)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Grok.hairlineStrong, lineWidth: 1))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Reconnecting…").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            }
        }
    }
}
