import SwiftUI

/// TethrX on the wrist.
///
/// It does the two things worth doing without taking the phone out: see what Grok
/// is blocked on, and answer it. Everything else stays on the phone.
@main
struct TethrXWatchApp: App {
    /// Starts the connectivity session for every launch, including a background one
    /// with no scene, and receives the wake-ups WatchConnectivity delivers when a
    /// snapshot lands while the app is closed, so the face complication moves then too.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @StateObject private var store = WatchStore.shared

    var body: some Scene {
        WindowGroup {
            WatchSessionList()
                .environmentObject(store)
                // The delegate already started the store at launch; this is the
                // harmless second call for the one path that has no delegate, SwiftUI
                // previews.
                .task { store.start() }
        }
    }
}
