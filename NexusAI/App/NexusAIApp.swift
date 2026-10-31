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

    var body: some Scene {
        WindowGroup {
            BootstrapView()
        }
    }
}

/// Temporary bootstrap screen used while the full UI is assembled.
struct BootstrapView: View {
    @StateObject private var settings = SettingsStore()
    @ObservedObject private var hardware = HardwareMonitor.shared

    var body: some View {
        List {
            Section("Device") {
                Text(hardware.device.marketingName)
                Text(ByteCountFormatter.memory(Int64(hardware.device.physicalMemory)))
                Text(hardware.tier.rawValue)
                Text(AppleIntelligence.status.reason)
            }
            Section("Models") {
                ForEach(ModelRegistry.catalog) { Text($0.name) }
            }
        }
    }
}
