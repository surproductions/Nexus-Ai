import Foundation
import Combine

/// Tracks installed models and owns the single loaded llama.cpp runtime.
/// Only one GGUF model is resident at a time: on phones, sequential loading is safer and usually faster overall
/// than keeping two models resident and competing for the same unified memory and GPU.
@MainActor
final class ModelManager: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading(modelID: String, progress: Double)
        case ready(modelID: String)
        case failed(String)
    }

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var visionInstalled: Set<String> = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var loadedBackend: LlamaBackend?
    @Published private(set) var loadedEntry: ModelEntry?
    @Published private(set) var loadedContext: Int = 0
    @Published private(set) var lastLoadMs: Int = 0
    @Published var isGenerating = false

    private let hardware: HardwareMonitor
    private var loadTask: Task<LlamaBackend, Error>?
    private var observers: [NSObjectProtocol] = []

    init(hardware: HardwareMonitor) {
        self.hardware = hardware
        rescan()
        observers.append(NotificationCenter.default.addObserver(forName: .nexusMemoryPressure, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMemoryPressure() }
        })
    }

    // MARK: Files

    static func directory(for repo: String) -> URL {
        let dir = Paths.models.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func localURL(_ entry: ModelEntry) -> URL {
        entry.isCustom ? Paths.models.appendingPathComponent("Custom/\(entry.file.filename)")
                       : directory(for: entry.sourceRepo).appendingPathComponent(entry.file.filename)
    }

    static func projectorURL(_ entry: ModelEntry) -> URL? {
        guard let p = entry.visionProjector else { return nil }
        return directory(for: entry.sourceRepo).appendingPathComponent(p.filename)
    }

    func rescan() {
        var inst = Set<String>()
        var vis = Set<String>()
        for e in ModelRegistry.allEntries {
            let url = Self.localURL(e)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
               e.isCustom || size.int64Value == e.file.sizeBytes {
                inst.insert(e.id)
            }
            if let p = Self.projectorURL(e), FileManager.default.fileExists(atPath: p.path) { vis.insert(e.id) }
        }
        installed = inst
        visionInstalled = vis
    }

    func isInstalled(_ id: String) -> Bool { installed.contains(id) }

    func diskUsage() -> Int64 {
        guard let en = FileManager.default.enumerator(at: Paths.models, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func delete(_ entry: ModelEntry, includeProjector: Bool = true) {
        if loadedEntry?.id == entry.id { unload() }
        try? FileManager.default.removeItem(at: Self.localURL(entry))
        if includeProjector, let p = Self.projectorURL(entry) {
            // Projectors can be shared by quantization variants in the same repo.
            let sharedBy = ModelRegistry.catalog.filter { $0.id != entry.id && $0.sourceRepo == entry.sourceRepo && installed.contains($0.id) }
            if sharedBy.isEmpty { try? FileManager.default.removeItem(at: p) }
        }
        if entry.isCustom { CustomModels.remove(entry.id) }
        rescan()
    }

    func deleteProjector(_ entry: ModelEntry) {
        if loadedEntry?.id == entry.id { unload() }
        if let p = Self.projectorURL(entry) { try? FileManager.default.removeItem(at: p) }
        rescan()
    }

    /// Imports a user-provided GGUF file into the sandbox.
    func importModel(from url: URL) throws -> ModelEntry {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        let magic = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        guard magic == Data("GGUF".utf8) else { throw NexusError.generic("\(url.lastPathComponent) is not a GGUF model file.") }
        let dir = Paths.models.appendingPathComponent("Custom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let entry = CustomModels.add(fileURL: dest, sizeBytes: size)
        rescan()
        return entry
    }

    // MARK: Loading

    var reclaimableMemory: UInt64 {
        guard let e = loadedEntry else { return 0 }
        return e.estimatedMemory(context: loadedContext, withVision: loadedBackend?.descriptor.supportsVision ?? false)
    }

    /// Returns a loaded backend for the entry, loading (and unloading the current model) as needed.
    func backend(for entry: ModelEntry, context preferred: Int, vision: Bool) async throws -> LlamaBackend {
        guard installed.contains(entry.id) else { throw NexusError.modelNotInstalled(entry.name) }
        let wantVision = vision && visionInstalled.contains(entry.id)
        if let b = loadedBackend, loadedEntry?.id == entry.id,
           loadedContext >= min(preferred, entry.nativeContext) || loadedContext >= 2048,
           !wantVision || b.descriptor.supportsVision {
            return b
        }
        if let loadTask { _ = try? await loadTask.value }

        guard let ctx = hardware.fittingContext(for: entry, preferred: preferred, vision: wantVision,
                                                reclaimable: reclaimableMemory) else {
            let check = hardware.canLoad(entry, context: 1024, vision: wantVision, reclaimable: reclaimableMemory)
            throw NexusError.insufficientMemory(required: check.required, available: check.available, model: entry.name)
        }
        unload()

        let modelURL = Self.localURL(entry)
        let projector = wantVision ? Self.projectorURL(entry) : nil
        let config = LlamaConfig(contextLength: ctx, batchSize: hardware.tier == .low ? 256 : 512,
                                 gpuLayers: 999, flashAttention: true,
                                 quantizeKVCache: ctx > 8192, threads: Int32(max(2, hardware.device.performanceCores)))
        let id = entry.id
        loadState = .loading(modelID: id, progress: 0)
        let progress = LoadProgress { p in
            Task { @MainActor [weak self] in
                if case .loading(let mid, _) = self?.loadState, mid == id { self?.loadState = .loading(modelID: id, progress: p) }
            }
        }
        let task = Task<LlamaBackend, Error> {
            let runtime = try await LlamaRuntime.load(modelURL: modelURL, projectorURL: projector, config: config, progress: progress)
            return LlamaBackend(runtime: runtime, entry: entry)
        }
        loadTask = task
        do {
            let backend = try await task.value
            loadTask = nil
            loadedBackend = backend
            loadedEntry = entry
            loadedContext = backend.runtime.contextLength
            lastLoadMs = backend.runtime.loadTimeMs
            loadState = .ready(modelID: id)
            hardware.refresh()
            return backend
        } catch {
            loadTask = nil
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func unload() {
        loadedBackend = nil
        loadedEntry = nil
        loadedContext = 0
        if case .ready = loadState { loadState = .idle }
        hardware.refresh()
    }

    private func handleMemoryPressure() {
        // Never pull a model out from under an active generation; otherwise free memory immediately.
        guard !isGenerating else { return }
        if loadedBackend != nil {
            unload()
            loadState = .failed("Model unloaded after an iOS memory warning. It will reload on the next request.")
        }
    }
}
