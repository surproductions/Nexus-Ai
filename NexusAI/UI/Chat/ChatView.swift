import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var models: ModelManager
    @ObservedObject var memory: MemoryStore
    @State private var showHistory = false
    @State private var showVoice = false
    @State private var showModelPicker = false
    @State private var traceMessage: ChatMessage?
    @State private var seek: SeekTarget?

    struct SeekTarget: Identifiable { var id = UUID(); var url: URL; var time: Double }

    private var latestVideoURL: URL? {
        chat.conversation.messages.flatMap(\.attachments).last { $0.kind == .video }?.fileURL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ModeSelector(mode: Binding(get: { chat.mode }, set: { chat.mode = $0 }),
                             connected: settings.cloudForMax && settings.allowCloud && !settings.offlineOnly && settings.activeProvider != nil)
                    .padding(.horizontal)
                    .padding(.top, 6)
                StatusStrip(chat: chat, models: models, settings: settings)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                Divider()
                messages
                if let error = chat.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal).padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !memory.suggestions.isEmpty && settings.suggestMemories {
                    MemorySuggestionBar(memory: memory)
                }
                Composer(chat: chat, settings: settings, onVoice: { showVoice = true })
            }
            .navigationTitle(chat.conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Conversation history")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showModelPicker = true } label: { Image(systemName: "cpu") }
                        .accessibilityLabel("Choose model")
                    Button { chat.newConversation() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New conversation")
                        .disabled(chat.isGenerating)
                }
            }
            .sheet(isPresented: $showHistory) {
                ConversationListView(chat: chat, store: app.conversations, memory: app.memory)
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(chat: chat, settings: settings, models: models)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $traceMessage) { msg in
                TraceSheet(message: msg)
            }
            .sheet(item: $seek) { target in VideoSeekSheet(url: target.url, time: target.time) }
            .fullScreenCover(isPresented: $showVoice) {
                VoiceView(chat: chat, settings: settings)
            }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.conversation.messages.isEmpty && chat.session == nil {
                        WelcomeView(settings: settings, models: models, onPrompt: { chat.draft = $0 })
                            .padding(.top, 30)
                    }
                    ForEach(chat.conversation.messages) { msg in
                        MessageRow(message: msg, showThinking: settings.showThinking,
                                   onTrace: { traceMessage = msg },
                                   onRegenerate: msg.id == chat.conversation.messages.last?.id && msg.role == .assistant ? { chat.regenerate() } : nil,
                                   onDelete: { chat.delete(msg) },
                                   videoURL: latestVideoURL,
                                   onSeek: { url, t in seek = SeekTarget(url: url, time: t) })
                            .id(msg.id)
                    }
                    if let session = chat.session {
                        StreamingRow(session: session, showThinking: settings.showThinking)
                            .id("streaming")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.conversation.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.streamTick) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

struct ModeSelector: View {
    @Binding var mode: IntelligenceMode
    var connected = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(IntelligenceMode.allCases) { m in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { mode = m }
                } label: {
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: m.symbol).imageScale(.small)
                            Text(m == .max && connected ? "Max · Connected" : m.shortTitle).font(.subheadline.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        Text(m.subtitle).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(mode == m ? Color.primary.opacity(0.7) : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if mode == m {
                            RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .systemBackground))
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "mode", in: ns)
                        }
                    }
                    .foregroundStyle(mode == m ? m.tint : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.title): \(m.subtitle)")
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatusStrip: View {
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var models: ModelManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var hardware = HardwareMonitor.shared
    @State private var online = NetworkGate.shared.isOnline

    var body: some View {
        HStack(spacing: 10) {
            Label(modelLabel, systemImage: modelSymbol)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let tps = chat.lastMeta?.tokensPerSecond, tps > 0 {
                Text("\(String(format: "%.1f", tps)) tok/s").monospacedDigit()
            }
            Text(ByteCountFormatter.memory(Int64(hardware.appFootprint))).monospacedDigit()
            Image(systemName: connectivitySymbol)
                .foregroundStyle(settings.offlineOnly ? .orange : (online ? .green : .secondary))
                .accessibilityLabel(settings.offlineOnly ? "Offline-only mode" : (online ? "Online" : "Offline"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .onReceive(NotificationCenter.default.publisher(for: .nexusNetworkChanged)) { _ in online = NetworkGate.shared.isOnline }
        .onAppear { hardware.refresh() }
        .onChange(of: chat.isGenerating) { _ in hardware.refresh() }
    }

    private var modelLabel: String {
        if case .loading(let id, let p) = models.loadState {
            return "Loading \(ModelRegistry.entry(id)?.name ?? id) \(Int(p * 100))%"
        }
        if let r = chat.session?.route { return (r.isOnDevice ? "Local · " : "Remote · ") + r.name }
        if let meta = chat.lastMeta, !meta.modelName.isEmpty { return (meta.usedCloud ? "Remote · " : "Local · ") + meta.modelName }
        if let e = models.loadedEntry { return "Local · " + e.name }
        if !settings.modelOverride.isEmpty { return ModelRegistry.entry(settings.modelOverride)?.name ?? "Manual model" }
        return "Automatic routing"
    }

    private var modelSymbol: String {
        if chat.session?.route?.isOnDevice == false || chat.lastMeta?.usedCloud == true { return "cloud" }
        return "iphone"
    }

    private var connectivitySymbol: String {
        settings.offlineOnly ? "airplane" : (online ? "wifi" : "wifi.slash")
    }
}

struct MemorySuggestionBar: View {
    @ObservedObject var memory: MemoryStore

    var body: some View {
        if let s = memory.suggestions.first {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile").foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Remember this?").font(.caption.weight(.semibold))
                    Text(s.content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Save") { memory.approve(s) }.font(.caption.weight(.semibold))
                Button { memory.delete(s) } label: { Image(systemName: "xmark") }.font(.caption)
                    .accessibilityLabel("Dismiss suggestion")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 6)
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var models: ModelManager
    var onPrompt: (String) -> Void

    private let prompts = [
        ("Explain a concept", "Explain how public-key cryptography works, with an analogy."),
        ("Plan something", "Plan a 3-day trip to Kyoto in spring with a moderate budget."),
        ("Write code", "Write a Swift function that debounces a closure, with a usage example."),
        ("Reason it through", "A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("NEXUS").font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(4)
                Text(statusLine).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(prompts, id: \.0) { item in
                    Button { onPrompt(item.1) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.0).font(.subheadline.weight(.semibold))
                            Text(item.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private var statusLine: String {
        if models.installed.isEmpty && !AppleIntelligence.isAvailable {
            return "Download a model in the Models tab to start chatting privately on this iPhone."
        }
        return settings.offlineOnly ? "Offline-Only mode · everything stays on this device" : "Private by default · runs on this device"
    }
}
