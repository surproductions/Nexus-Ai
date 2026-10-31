import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct Composer: View {
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var settings: SettingsStore
    var onVoice: () -> Void
    @StateObject private var dictation = Dictation()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !chat.pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chat.pending) { p in
                            ZStack(alignment: .topTrailing) {
                                if let thumb = p.thumbnail {
                                    Image(uiImage: thumb).resizable().scaledToFill().frame(width: 58, height: 58)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    Label(p.filename, systemImage: "doc.text").font(.caption).lineLimit(1)
                                        .frame(maxWidth: 160).padding(10)
                                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                                }
                                Button { chat.pending.removeAll { $0.id == p.id } } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 6, y: -6)
                                .accessibilityLabel("Remove attachment")
                            }
                        }
                    }
                    .padding(.horizontal).padding(.top, 8)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                    }
                    Button { showFiles = true } label: { Label("Document", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("Add attachment")

                HStack(alignment: .bottom) {
                    TextField(placeholder, text: $chat.draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.vertical, 8)
                        .submitLabel(.send)
                    if chat.draft.isEmpty && !chat.isGenerating {
                        Button {
                            Task { await dictation.toggle(requireOnDevice: settings.offlineOnly) }
                        } label: {
                            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                                .foregroundStyle(dictation.isRecording ? .red : .secondary)
                        }
                        .padding(.bottom, 9)
                        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                    }
                }
                .padding(.horizontal, 12)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20))

                if chat.isGenerating {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Color.primary, in: Circle())
                    }
                    .accessibilityLabel("Stop generating")
                } else if chat.draft.trimmed.isEmpty && chat.pending.isEmpty {
                    Button(action: onVoice) {
                        Image(systemName: "waveform").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Color.accentColor, in: Circle())
                    }
                    .accessibilityLabel("Voice conversation")
                } else {
                    Button { chat.send(); focused = false } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Color.accentColor, in: Circle())
                    }
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 4)
        .background(.bar)
        .onChange(of: dictation.text) { t in if !t.isEmpty { chat.draft = t } }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { items in
            Task {
                for item in items { await chat.addPhotoItem(item) }
                photoItems = []
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: DocumentStore.supportedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach { chat.addDocument($0) } }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in chat.addImage(image, name: "Camera") }.ignoresSafeArea()
        }
    }

    private var placeholder: String {
        switch chat.mode {
        case .instant: return "Ask anything"
        case .thinking: return "Ask something that needs thought"
        case .max: return "Give NEXUS your hardest problem"
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct ModelPickerSheet: View {
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var models: ModelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(id: "", title: "Automatic", subtitle: "NEXUS picks the best model for each request", symbol: "wand.and.stars")
                } footer: {
                    Text("Automatic routing weighs task type, mode, installed models, free memory, thermal state and your on-device evaluation results.")
                }
                Section("On this device") {
                    if AppleIntelligence.isAvailable {
                        row(id: AppleFoundationBackend.modelID, title: "Apple Intelligence", subtitle: "Built-in on-device model · no download", symbol: "apple.logo")
                    }
                    ForEach(ModelRegistry.allEntries.filter { models.isInstalled($0.id) }) { e in
                        row(id: e.id, title: e.name, subtitle: "\(e.quantization) · \(ByteCountFormatter.file(e.file.sizeBytes))\(models.visionInstalled.contains(e.id) ? " · vision" : "")", symbol: "cpu")
                    }
                    if models.installed.isEmpty && !AppleIntelligence.isAvailable {
                        Text("No models installed yet. Open the Models tab to download one.").foregroundStyle(.secondary)
                    }
                }
                if let p = settings.activeProvider, settings.allowCloud && !settings.offlineOnly {
                    Section {
                        row(id: "cloud", title: p.name, subtitle: "\(p.model) · data leaves this device", symbol: "cloud")
                    } header: { Text("Cloud") } footer: {
                        Text("Selecting a cloud model sends your messages, relevant memories and attachments for each request to \(p.name).")
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var current: String { chat.conversation.modelOverride ?? settings.modelOverride }

    private func row(id: String, title: String, subtitle: String, symbol: String) -> some View {
        Button {
            chat.conversation.modelOverride = nil
            settings.modelOverride = id
        } label: {
            HStack {
                Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if current == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }
}

struct ConversationListView: View {
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var store: ConversationStore
    @ObservedObject var memory: MemoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let results = store.search(query)
                if results.isEmpty {
                    EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "No conversations",
                                   message: query.isEmpty ? "Your chats are stored encrypted on this device." : "No matches for “\(query)”.")
                        .listRowBackground(Color.clear)
                }
                ForEach(results) { s in
                    Button {
                        chat.open(s.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(s.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                if let p = memory.project(s.projectID) { Pill(text: p.name, symbol: "folder") }
                            }
                            Text(s.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(s.updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.delete(s.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search conversations")
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button { chat.newConversation(); dismiss() } label: { Label("New chat", systemImage: "square.and.pencil") }
                        ForEach(memory.projects) { p in
                            Button { chat.newConversation(projectID: p.id); dismiss() } label: { Label("New chat in \(p.name)", systemImage: "folder") }
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
        }
    }
}
