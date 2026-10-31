import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == DownloadManager.sessionID {
            Task { @MainActor in DownloadManager.backgroundCompletion = completionHandler }
        } else {
            completionHandler()
        }
    }
}

@main
struct NexusAIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(settings: app.settings)
                .environmentObject(app)
        }
    }
}
