import SwiftUI
import Combine

/// Composition root: owns every store/service and wires them together.
@MainActor
final class AppModel: ObservableObject {
    let settings = SettingsStore()
    let hardware = HardwareMonitor.shared
    let models: ModelManager
    let downloads = DownloadManager()
    let memory = MemoryStore()
    let conversations = ConversationStore()
    let documents = DocumentStore()
    let evaluations = EvaluationStore()
    let orchestrator: Orchestrator
    let chat: ChatViewModel
    let library = MediaLibrary()
    let creative: CreativeService
    let connectors = ConnectorStore()

    @Published var locked = false
    @Published var selectedTab = 0
    private var bag: Set<AnyCancellable> = []

    init() {
        models = ModelManager(hardware: HardwareMonitor.shared)
        orchestrator = Orchestrator(models: models, hardware: HardwareMonitor.shared, settings: settings, memory: memory,
                                    documents: documents, evaluations: evaluations)
        chat = ChatViewModel(orchestrator: orchestrator, store: conversations, documents: documents, settings: settings)
        creative = CreativeService(library: library, models: models, settings: settings)
        creative.orchestrator = orchestrator
        orchestrator.creative = creative
        chat.library = library
        _ = MediaLibrary.purgeUploads(olderThan: settings.uploadRetentionDays)
        downloads.models = models
        downloads.allowCellular = settings.allowCellularDownloads
        settings.$allowCellularDownloads.sink { [weak self] in self?.downloads.allowCellular = $0 }.store(in: &bag)
        locked = settings.biometricLock
        // Forward nested changes so views observing AppModel refresh.
        for publisher in [settings.objectWillChange, models.objectWillChange, downloads.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    func unlock() async {
        guard settings.biometricLock else { locked = false; return }
        if await Biometrics.authenticate(reason: "Unlock your NEXUS conversations and memories") { locked = false }
    }

    /// Picks up GGUF files the user copied into the app's Documents folder via the Files app.
    func importDroppedModels() {
        let inbox = Paths.documentsInbox
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "gguf" {
            if (try? models.importModel(from: url)) != nil { try? FileManager.default.removeItem(at: url) }
        }
    }

    func wipeAllData() {
        models.unload()
        Database.shared.wipeAll()
        Database.shared.exec("DELETE FROM media;")
        try? FileManager.default.removeItem(at: MediaFiles.directory)
        library.reload()
        conversations.reload()
        memory.reload()
        documents.reload()
        evaluations.reload()
        try? FileManager.default.removeItem(at: Paths.attachments)
        NetworkGate.shared.clearLog()
        chat.newConversation()
    }
}
