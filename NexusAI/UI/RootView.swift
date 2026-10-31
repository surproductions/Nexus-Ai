import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            TabView(selection: $app.selectedTab) {
                ChatView(chat: app.chat, settings: app.settings, models: app.models, memory: app.memory)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(0)
                StudioView(creative: app.creative, library: app.library)
                    .tabItem { Label("Studio", systemImage: "paintpalette") }.tag(1)
                WorkspaceView()
                    .tabItem { Label("Workspace", systemImage: "square.stack.3d.up") }.tag(3)
                ModelsView(models: app.models, downloads: app.downloads)
                    .tabItem { Label("Models", systemImage: "cpu") }
                    .badge(app.downloads.activeCount)
                    .tag(2)
                SettingsView(settings: app.settings)
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
            }
            if app.locked {
                LockView { Task { await app.unlock() } }
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(settings.colorScheme)
        .sheet(isPresented: Binding(get: { !settings.hasOnboarded }, set: { if !$0 { settings.hasOnboarded = true } })) {
            OnboardingView(settings: settings, onDone: {
                settings.hasOnboarded = true
                app.selectedTab = app.models.installed.isEmpty && !AppleIntelligence.isAvailable ? 2 : 0
            })
            .interactiveDismissDisabled()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                if settings.biometricLock { app.locked = true }
            case .active:
                app.hardware.refresh()
                app.importDroppedModels()
                if app.locked { Task { await app.unlock() } }
            default: break
            }
        }
    }
}

struct LockView: View {
    var onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 40, weight: .light))
                Text("NEXUS is locked").font(.headline)
                Button("Unlock with \(Biometrics.biometryName)", action: onUnlock).buttonStyle(.borderedProminent)
            }
        }
        .onAppear(perform: onUnlock)
    }
}

struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    var onDone: () -> Void
    @ObservedObject private var hw = HardwareMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEXUS").font(.system(size: 40, weight: .bold, design: .rounded)).tracking(5)
                    Text("A private AI assistant that runs on your iPhone.").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, 30)
                feature("bolt", .orange, "Three intelligence modes", "Instant for speed, Thinking for balance, Max Intelligence for multi-agent, verified answers. Switch anytime.")
                feature("iphone", .blue, "Local first", "Models run on this \(hw.device.marketingName) with Metal acceleration. Works fully offline once a model is downloaded.")
                feature("brain", .purple, "Memory you control", "NEXUS only remembers what you approve. Everything is encrypted on device and editable.")
                feature("hand.raised", .green, "Nothing leaves without consent", "Web research and cloud models are off by default. A local log shows every network request.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your device").font(.headline)
                    Text("\(hw.device.chip) · \(ByteCountFormatter.memory(Int64(hw.device.physicalMemory))) · \(hw.tier.rawValue) profile").foregroundStyle(.secondary)
                    Text(AppleIntelligence.isAvailable ? "Apple Intelligence is available, so you can start chatting right away. Download a model for stronger reasoning, coding and vision."
                                                       : "Next, download a model (Qwen3.5 2B is about 1.3 GB) to start chatting.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Start in Offline-Only mode", isOn: $settings.offlineOnly).tint(.orange)
                Text("Offline-Only blocks all network access, including model downloads. You can change this anytime in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(action: onDone) {
                    Text("Get started").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
