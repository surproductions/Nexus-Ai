import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers

/// Movie file received from the Photos picker (copied into the app's temporary directory).
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct StudioView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var creative: CreativeService
    @ObservedObject var library: MediaLibrary

    private let tools: [(String, String, String, Color)] = [
        ("Image Generator", "photo.badge.plus", "Text and reference to image", .blue),
        ("Video Generator", "film.stack", "Text or image to video", .purple),
        ("Image Editor", "wand.and.rays", "Edit with instructions", .orange),
        ("Video Editor", "scissors", "Remix, extend, reframe", .pink),
        ("Media Analyzer", "eye", "Understand photos and videos", .green),
        ("Library", "square.grid.2x2", "Saved creations", .teal),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ProviderStatusStrip(creative: creative)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(tools, id: \.0) { tool in
                            NavigationLink { destination(tool.0) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    Image(systemName: tool.1).font(.title2).foregroundStyle(tool.3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.0).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text(tool.2).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                                .padding(14)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !creative.jobs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Generation history").font(.headline)
                                Spacer()
                                Button("Clear finished") { creative.clearFinished() }.font(.caption)
                            }
                            ForEach(creative.jobs.prefix(8)) { job in JobRow(job: job, creative: creative, library: library) }
                        }
                    }
                    if !library.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Recent creations").font(.headline)
                                Spacer()
                                NavigationLink("See all") { LibraryView(library: library, creative: creative) }.font(.caption)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(library.items.prefix(12)) { item in
                                        NavigationLink { MediaDetailView(item: item, library: library, creative: creative) } label: {
                                            MediaThumb(item: item).frame(width: 110, height: 110)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text("Generated media is labelled as AI-generated in its file metadata (IPTC Digital Source Type). Local generation runs on this iPhone; remote providers are always shown with a cloud badge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Studio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { CreativeProvidersView(creative: creative, settings: app.settings) } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Generation providers")
                }
            }
        }
    }

    @ViewBuilder private func destination(_ name: String) -> some View {
        switch name {
        case "Image Generator": ImageGeneratorView(creative: creative, library: library)
        case "Video Generator": VideoGeneratorView(creative: creative, library: library)
        case "Image Editor": ImageEditorView(creative: creative, library: library)
        case "Video Editor": VideoEditorView(creative: creative, library: library)
        case "Media Analyzer": MediaAnalyzerView()
        default: LibraryView(library: library, creative: creative)
        }
    }
}

struct ProviderStatusStrip: View {
    @ObservedObject var creative: CreativeService
    @State private var statuses: [(String, Bool, Bool)] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(statuses, id: \.0) { s in
                    Pill(text: s.0, symbol: s.2 ? "iphone" : "cloud", tint: s.1 ? (s.2 ? .green : .blue) : .secondary)
                }
            }
        }
        .task {
            var out: [(String, Bool, Bool)] = []
            for p in creative.imageProviders { out.append((p.name, await p.status().available, p.isLocal)) }
            for p in creative.videoProviders { out.append((p.name, await p.status().available, p.isLocal)) }
            statuses = out
        }
    }
}

struct JobRow: View {
    let job: CreativeJob
    @ObservedObject var creative: CreativeService
    @ObservedObject var library: MediaLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: job.kind == .video ? "film" : "photo").foregroundStyle(.secondary)
                Text(job.prompt).font(.subheadline).lineLimit(1)
                Spacer()
                Pill(text: job.isLocal ? "Local" : "Remote", symbol: job.isLocal ? "iphone" : "cloud", tint: job.isLocal ? .green : .blue)
            }
            switch job.state {
            case .running:
                if let p = job.progress { ProgressView(value: p) } else { ProgressView() }
                HStack {
                    Text(job.message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { creative.cancel(job) }.font(.caption)
                }
            case .succeeded:
                HStack(spacing: 8) {
                    ForEach(job.resultIDs, id: \.self) { id in
                        if let item = library.item(id) { MediaThumb(item: item).frame(width: 56, height: 56) }
                    }
                    Spacer()
                    Text("\(job.providerName) · \(Int(Date().timeIntervalSince(job.started)))s ago").font(.caption2).foregroundStyle(.tertiary)
                }
            case .failed(let e): Text(e).font(.caption).foregroundStyle(.red)
            case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MediaThumb: View {
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
                .clipped()
            HStack(spacing: 3) {
                if item.kind == .video { Image(systemName: "play.fill") }
                Image(systemName: item.isLocal ? "iphone" : "cloud")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: item.id) {
            let i = item
            image = await Task.detached { MediaLibrary.thumbnail(for: i) }.value
        }
        .accessibilityLabel("\(item.kind == .video ? "Video" : "Image"): \(item.name)")
    }
}

/// Provider picker: "Automatic" or a specific provider, showing availability and whether it's local or remote.
struct ImageProviderPicker: View {
    @ObservedObject var creative: CreativeService
    @Binding var selection: String
    var needs: Set<ImageCapability>
    @State private var status: [String: ProviderStatus] = [:]

    var body: some View {
        Picker("Provider", selection: $selection) {
            Text("Automatic").tag("")
            ForEach(creative.imageProviders.filter { needs.isSubset(of: $0.capabilities) }, id: \.id) { p in
                Text("\(p.name)\(p.isLocal ? " · on device" : " · remote")\(status[p.id]?.available == false ? " (unavailable)" : "")").tag(p.id)
            }
        }
        .task {
            for p in creative.imageProviders { status[p.id] = await p.status() }
        }
        if let s = status[selection], !selection.isEmpty, !s.available {
            Text(s.reason).font(.caption).foregroundStyle(.orange)
        }
        if let p = creative.imageProvider(selection) {
            Text(p.styleNote).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CreativeProvidersView: View {
    @ObservedObject var creative: CreativeService
    @ObservedObject var settings: SettingsStore
    @State private var openAIKey = ""
    @State private var falKey = ""
    @State private var statuses: [String: ProviderStatus] = [:]
    @State private var newEndpoint = FalEndpoint(id: "", name: "", kind: .textToVideo)

    var body: some View {
        Form {
            Section {
                Toggle("Cloud image & video generation", isOn: $settings.allowCloudGeneration).disabled(settings.offlineOnly)
            } footer: {
                Text("Off by default. When on, generation prompts and any images you attach to that request are sent to the provider you use. Videos you upload for analysis are never sent. Local providers keep working offline.")
            }
            Section("On device") {
                statusRow("apple.playground", "Apple Image Playground", "Built-in · animation, illustration, sketch")
                statusRow("local.sd21", "Stable Diffusion 2.1 (Core ML)", "Download in Models · 512×512 · photorealistic and custom styles")
                Text("Video generation is not practical on iPhone hardware: current video models need tens of GB of memory and minutes of datacenter GPU time per clip. NEXUS offers video through connected providers only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                SecureField(Keychain.get(CreativeKeys.openAI) == nil ? "OpenAI API key" : "OpenAI key stored — enter to replace", text: $openAIKey)
                TextField("Image model", text: $creative.openAIImageModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Video model", text: $creative.openAIVideoModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save OpenAI key") { Keychain.set(openAIKey, for: CreativeKeys.openAI); openAIKey = ""; refresh() }.disabled(openAIKey.isEmpty)
                statusRow("openai.image", "OpenAI Images", "Generation and natural-language editing")
                statusRow("openai.video", "OpenAI Video", "Text/image to video, remix")
            } header: { Text("OpenAI") }
            Section {
                SecureField(Keychain.get(CreativeKeys.fal) == nil ? "fal.ai API key" : "fal.ai key stored — enter to replace", text: $falKey)
                Button("Save fal.ai key") { Keychain.set(falKey, for: CreativeKeys.fal); falKey = ""; refresh() }.disabled(falKey.isEmpty)
                ForEach(creative.falEndpoints) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name)
                        Text("\(e.kind.rawValue) · \(e.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .onDelete { creative.falEndpoints.remove(atOffsets: $0) }
                DisclosureGroup("Add endpoint") {
                    TextField("Endpoint id (e.g. fal-ai/…)", text: $newEndpoint.id).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Display name", text: $newEndpoint.name)
                    Picker("Type", selection: $newEndpoint.kind) { ForEach(FalEndpoint.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Button("Add") {
                        var e = newEndpoint
                        if e.name.isEmpty { e.name = e.id }
                        if e.kind == .textToVideo || e.kind == .imageToVideo, e.durations.isEmpty { e.durations = [5] }
                        creative.falEndpoints.append(e)
                        newEndpoint = FalEndpoint(id: "", name: "", kind: .textToVideo)
                    }.disabled(newEndpoint.id.isEmpty)
                }
                Button("Restore preset endpoints") { creative.falEndpoints = FalEndpoint.presets }
            } header: { Text("fal.ai") } footer: {
                Text("Each fal model defines its own parameters; NEXUS sends prompt, size/aspect, count, duration and image_url. Keys are stored only in this device's Keychain.")
            }
        }
        .navigationTitle("Generation providers")
        .task { refresh() }
    }

    private func refresh() {
        Task {
            var s: [String: ProviderStatus] = [:]
            for p in creative.imageProviders { s[p.id] = await p.status() }
            for p in creative.videoProviders { s[p.id] = await p.status() }
            if s["local.sd21"] == nil { s["local.sd21"] = ProviderStatus(available: false, reason: "Not downloaded") }
            statuses = s
        }
    }

    private func statusRow(_ id: String, _ title: String, _ detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(statuses[id]?.reason ?? detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: statuses[id]?.available == true ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(statuses[id]?.available == true ? .green : .secondary)
        }
    }
}
