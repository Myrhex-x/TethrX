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
            } else {
                PairingView()
            }
        }
        .task { await app.handleLaunchArguments() }
    }
}
