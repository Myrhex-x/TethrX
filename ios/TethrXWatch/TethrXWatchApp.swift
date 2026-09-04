import SwiftUI

/// TethrX on the wrist.
///
/// It does the two things worth doing without taking the phone out: see what Grok
/// is blocked on, and answer it. Everything else stays on the phone.
@main
struct TethrXWatchApp: App {
    @StateObject private var store = WatchStore.shared

    var body: some Scene {
        WindowGroup {
            WatchSessionList()
                .environmentObject(store)
                .tint(.white)
                .task { store.start() }
        }
    }
}
