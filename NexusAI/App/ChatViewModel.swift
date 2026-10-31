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
    weak var library: MediaLibrary?
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
        var pendingVideos: [(Int, URL)] = []
        for p in attachments {
            if p.kind == .image, let cg = p.image {
                images.append(cg)
                if reuse == nil, let rel = Self.store(image: cg) {
                    let analysis = await VisionAnalyzer.analyze(cg)
                    saved.append(Attachment(kind: .image, filename: p.filename, relativePath: rel, extractedText: analysis.summary))
                }
            } else if p.kind == .video, let url = p.fileURL {
                if let rel = Self.store(video: url) {
                    saved.append(Attachment(kind: .video, filename: p.filename, relativePath: rel))
                    pendingVideos.append((saved.count - 1, Paths.attachments.appendingPathComponent(rel)))
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
        let s = TurnSession()
        session = s

        // Analyze uploaded videos on device before answering (dossier is stored with the message for follow-ups).
        for (index, url) in pendingVideos {
            let t0 = Date()
            let step = s.begin("Video analysis", "Analyzing \(saved[index].filename)")
            do {
                let captioner = await orchestrator.frameCaptioner(mode: conversation.mode)
                let dossier = try await VideoAnalyzer.analyze(
                    url: url,
                    options: .forMode(conversation.mode, transcribe: settings.transcribeVideoAudio, offline: settings.offlineOnly),
                    captioner: captioner,
                    progress: { message in Task { @MainActor in s.status = message } })
                if let data = try? JSONEncoder().encode(dossier) { saved[index].extractedText = String(data: data, encoding: .utf8) }
                s.end(step, detail: "\(dossier.frames.count) key frames, \(dossier.sceneStarts.count) scenes, \(dossier.transcript.count) transcript segments", started: t0)
            } catch {
                s.end(step, .failed, detail: error.localizedDescription, started: t0)
                errorMessage = error.localizedDescription
            }
        }

        let user = reuse ?? ChatMessage(role: .user, content: text, attachments: saved)
        conversation.messages.append(user)
        if conversation.messages.filter({ $0.role == .user }).count == 1 { conversation.title = Self.title(from: text) }
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

        var input = TurnInput(text: text, images: images, attachments: saved, history: history, mode: conversation.mode,
                              projectID: conversation.projectID, documentIDs: docIDs,
                              modelOverride: conversation.modelOverride ?? (settings.modelOverride.isEmpty ? nil : settings.modelOverride))
        applyMediaContext(&input, current: saved, question: text)
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
        if !answer.isEmpty || !meta.warnings.isEmpty || !s.outputAttachments.isEmpty {
            conversation.messages.append(ChatMessage(role: .assistant, content: answer.isEmpty ? "_No response._" : answer,
                                                     attachments: s.outputAttachments, meta: meta))
        }
        lastMeta = meta
        conversation.updatedAt = Date()
        store.save(conversation)
        session = nil
        sessionObserver = nil
        onTurnFinished?()
    }

    // MARK: Conversation media context

    /// Numbers every image/video in the conversation, re-sends the most recent images to vision models for follow-up
    /// questions, adds video dossiers (focused on any timestamp in the question) and picks the media an edit applies to.
    private func applyMediaContext(_ input: inout TurnInput, current: [Attachment], question: String) {
        let all: [(Int, Attachment)] = (input.history.enumerated().flatMap { i, m in m.attachments.map { (i, $0) } })
            + current.map { (input.history.count, $0) }
        let images = all.filter { $0.1.kind == .image }
        let videos = all.filter { $0.1.kind == .video }
        var lines: [String] = []
        if images.count > 1 || (!images.isEmpty && current.allSatisfy { $0.kind != .image }) {
            lines.append("Images in this conversation (refer to them by number): " +
                         images.enumerated().map { "Image \($0.offset + 1) = \($0.element.1.filename)\($0.element.0 == input.history.count ? " (just attached)" : "")" }.joined(separator: "; "))
        }
        if input.images.isEmpty, let lastIndex = images.last?.0, lastIndex >= input.history.count - 8 {
            let recent = images.filter { $0.0 == lastIndex }.suffix(3)
            input.historyImages = recent.compactMap { VisionAnalyzer.loadImage(at: $0.1.fileURL) }
            for (n, a) in recent.enumerated() where !(a.1.extractedText ?? "").isEmpty {
                lines.append("Earlier image “\(a.1.filename)” — on-device analysis:\n\(a.1.extractedText!.truncated(to: 1500))" + (n == 0 ? "" : ""))
            }
        }
        let budget = conversation.mode == .instant ? 2500 : (conversation.mode == .thinking ? 6000 : 10000)
        let focus = VideoDossier.focusTime(in: question)
        let recentVideos = videos.suffix(3)
        for (n, v) in recentVideos.enumerated() {
            guard let json = v.1.extractedText?.data(using: .utf8),
                  let dossier = try? JSONDecoder().decode(VideoDossier.self, from: json) else { continue }
            let label = recentVideos.count > 1 ? "Video \(n + 1)" : "The video"
            lines.append("\(label) (analyzed on device; cite times as [m:ss]):\n" + dossier.text(budget: budget / max(1, recentVideos.count), focus: focus))
        }
        input.mediaContext = lines.joined(separator: "\n\n")

        // Media an edit instruction would apply to: the most recent image or video.
        if let last = all.last(where: { $0.1.kind == .image || $0.1.kind == .video })?.1 {
            if last.kind == .image {
                input.editableImage = VisionAnalyzer.loadImage(at: last.fileURL)
                input.editableMediaID = last.mediaID
            } else if let library {
                if let id = last.mediaID { input.editableVideoID = id }
                else {
                    // Uploaded videos join the library so local edits (e.g. vertical crop) can reference them.
                    let dest = MediaFiles.newURL(ext: last.fileURL.pathExtension.isEmpty ? "mov" : last.fileURL.pathExtension)
                    if (try? FileManager.default.copyItem(at: last.fileURL, to: dest)) != nil {
                        let item = library.add(MediaItem(kind: .video, name: last.filename, fileName: dest.lastPathComponent,
                                                         prompt: "", modelName: "Uploaded video", provider: "Uploaded", isLocal: true,
                                                         operation: "upload"))
                        input.editableVideoID = item.id
                    }
                }
            }
        }
    }

    func addVideo(_ url: URL) {
        pending.append(PendingAttachment(kind: .video, filename: url.lastPathComponent, fileURL: url))
    }

    static func store(video url: URL) -> String? {
        let rel = "videos/\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)"
        let dest = Paths.attachments.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dest.path)
            return rel
        } catch { return nil }
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
