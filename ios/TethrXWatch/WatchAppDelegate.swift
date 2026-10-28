import WatchKit

/// The two things a SwiftUI watch app cannot do from a scene: start the connectivity
/// session for a launch that has no scene, and answer the background task the system
/// hands over when application context arrives while the app is closed.
///
/// Without this, the face complication only moved while the app was on screen, and
/// a watch left on a desk kept saying "working" an hour after Grok had stopped to
/// ask something.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        MainActor.assumeIsolated {
            WatchStore.shared.start()
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        MainActor.assumeIsolated {
            for task in backgroundTasks {
                switch task {
                case let connectivity as WKWatchConnectivityRefreshBackgroundTask:
                    // The store reads the new application context, rewrites the face
                    // complication's state in the app group and reloads its timelines,
                    // then completes this once WatchConnectivity has nothing pending.
                    WatchStore.shared.hold(connectivity)
                case let snapshot as WKSnapshotRefreshBackgroundTask:
                    snapshot.setTaskCompleted(restoredDefaultState: true,
                                              estimatedSnapshotExpiration: .distantFuture,
                                              userInfo: nil)
                default:
                    task.setTaskCompletedWithSnapshot(false)
                }
            }
        }
    }
}
