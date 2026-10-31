import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PendingAttachment: Identifiable {
    var id = UUID()
    var kind: Attachment.Kind
    var filename: String
    var image: CGImage?
    var thumbnail: UIImage?
    var fileURL: URL?
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var conversation = Conversation()
    @Published var draft = ""
    @Published var pending: [PendingAttachment] = []
    @Published private(set) var session: TurnSession?
    @Published private(set) var isGenerating = false
    @Published var errorMessage: String?
    @Published var lastMeta: MessageMeta?
    /// Throttled signal (≈4 Hz) that streamed text changed; drives auto-scroll without re-rendering per token.
    @Published private(set) var streamTick = 0
    private var lastTick = Date.distantPast

    let orchestrator: Orchestrator
    let store: ConversationStore
    let documents: DocumentStore
    let settings: SettingsStore
    private var task: Task<Void, Never>?
    private var sessionObserver: AnyObject?

    /// Streaming hook used by the voice interface (receives visible-text deltas).
    var onStreamDelta: ((String) -> Void)?
    var onTurnFinished: (() -> Void)?

    init(orchestrator: Orchestrator, store: ConversationStore, documents: DocumentStore, settings: SettingsStore) {
        self.orchestrator = orchestrator
        self.store = store
        self.documents = documents
        self.settings = settings
        conversation.mode = settings.mode
    }

    var mode: IntelligenceMode {
        get { conversation.mode }
        set { conversation.mode = newValue; settings.mode = newValue }
    }

    func newConversation(projectID: UUID? = nil) {
        stop()
        conversation = Conversation(mode: settings.mode, projectID: projectID)
        pending = []
        draft = ""
        lastMeta = nil
    }

    func open(_ id: UUID) {
        stop()
        if let c = store.load(id) {
            conversation = c
            settings.mode = c.mode
        }
    }

    // MARK: Attachments

    func addImage(_ image: UIImage, name: String = "Photo") {
        guard let cg = image.normalizedCGImage else { return }
        pending.append(PendingAttachment(kind: .image, filename: name + ".jpg", image: cg, thumbnail: image.preparingThumbnail(of: CGSize(width: 160, height: 160))))
    }

    func addPhotoItem(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
            addImage(img)
        }
    }

    func addDocument(_ url: URL) {
        pending.append(PendingAttachment(kind: .document, filename: url.lastPathComponent, fileURL: url))
    }

    // MARK: Sending

    func send(_ textOverride: String? = nil) {
        let text = (textOverride ?? draft).trimmed
        guard !text.isEmpty || !pending.isEmpty, !isGenerating else { return }
        draft = ""
        let attachments = pending
        pending = []
        task = Task { await run(text: text.isEmpty ? "Please analyze the attachment." : text, attachments: attachments) }
    }

    func regenerate() {
        guard !isGenerating, let lastUser = conversation.messages.lastIndex(where: { $0.role == .user }) else { return }
        let userMessage = conversation.messages[lastUser]
        conversation.messages.removeSubrange(lastUser...)
        let images: [PendingAttachment] = userMessage.attachments.compactMap { a in
            guard a.kind == .image, let cg = VisionAnalyzer.loadImage(at: Paths.attachments.appendingPathComponent(a.relativePath)) else { return nil }
            return PendingAttachment(kind: .image, filename: a.filename, image: cg)
        }
        task = Task { await run(text: userMessage.content, attachments: images, reuse: userMessage) }
    }

    func stop() {
        session?.cancel.cancel()
        task?.cancel()
    }

    private func run(text: String, attachments: [PendingAttachment], reuse: ChatMessage? = nil) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        // Persist attachments locally and index documents.
        var saved: [Attachment] = reuse?.attachments ?? []
        var images: [CGImage] = []
        var docIDs: [UUID] = saved.compactMap(\.documentID)
        for p in attachments {
            if p.kind == .image, let cg = p.image {
                images.append(cg)
                if reuse == nil, let rel = Self.store(image: cg) {
                    saved.append(Attachment(kind: .image, filename: p.filename, relativePath: rel))
                }
            } else if p.kind == .document, let url = p.fileURL {
                do {
                    let doc = try await documents.ingest(url: url, projectID: conversation.projectID)
                    docIDs.append(doc.id)
                    saved.append(Attachment(kind: .document, filename: p.filename, relativePath: doc.fileURL.lastPathComponent, documentID: doc.id))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }

        let history = conversation.messages
        let user = reuse ?? ChatMessage(role: .user, content: text, attachments: saved)
        conversation.messages.append(user)
        if conversation.messages.filter({ $0.role == .user }).count == 1 { conversation.title = Self.title(from: text) }

        let s = TurnSession()
        session = s
        var lastText = ""
        sessionObserver = s.$text.sink { [weak self] new in
            guard let self else { return }
            if new.hasPrefix(lastText) {
                let delta = String(new.dropFirst(lastText.count))
                if !delta.isEmpty { self.onStreamDelta?(delta) }
            }
            lastText = new
            if Date().timeIntervalSince(self.lastTick) > 0.25 {
                self.lastTick = Date()
                self.streamTick &+= 1
            }
        } as AnyObject

        let input = TurnInput(text: text, images: images, attachments: saved, history: history, mode: conversation.mode,
                              projectID: conversation.projectID, documentIDs: docIDs,
                              modelOverride: conversation.modelOverride ?? (settings.modelOverride.isEmpty ? nil : settings.modelOverride))
        var meta: MessageMeta
        do {
            meta = try await orchestrator.run(input, session: s)
        } catch NexusError.cancelled {
            meta = MessageMeta(mode: conversation.mode)
            meta.warnings.append("Stopped by you.")
        } catch {
            meta = MessageMeta(mode: conversation.mode)
            if s.text.isEmpty { errorMessage = error.localizedDescription }
            meta.warnings.append(error.localizedDescription)
        }
        if meta.trace.isEmpty { meta.trace = s.trace }
        if meta.modelName.isEmpty, let r = s.route { meta.modelName = r.name; meta.modelID = r.modelID }
        if meta.thinking == nil, !s.thinking.isEmpty { meta.thinking = s.thinking }
        if meta.ttftMs == nil, let st = s.stats {
            meta.ttftMs = st.timeToFirstTokenMs
            meta.tokensPerSecond = st.tokensPerSecond
            meta.generatedTokens = st.generatedTokens
        }
        let answer = s.text.trimmed
        if !answer.isEmpty || !meta.warnings.isEmpty {
            conversation.messages.append(ChatMessage(role: .assistant, content: answer.isEmpty ? "_No response._" : answer, meta: meta))
        }
        lastMeta = meta
        conversation.updatedAt = Date()
        store.save(conversation)
        session = nil
        sessionObserver = nil
        onTurnFinished?()
    }

    func delete(_ message: ChatMessage) {
        conversation.messages.removeAll { $0.id == message.id }
        store.save(conversation)
    }

    static func title(from text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(7).joined(separator: " ")
        return words.isEmpty ? "New conversation" : words.truncated(to: 48)
    }

    static func store(image: CGImage) -> String? {
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return nil }
        let rel = "images/\(UUID().uuidString).jpg"
        let url = Paths.attachments.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: [.completeFileProtection])
            return rel
        } catch { return nil }
    }
}

extension UIImage {
    /// Applies EXIF orientation so Vision and the model see the image upright.
    var normalizedCGImage: CGImage? {
        if imageOrientation == .up, let cg = cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }.cgImage
    }
}
