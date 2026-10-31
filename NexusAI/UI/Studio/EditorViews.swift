import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers

struct ImageEditorView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var creative: CreativeService
    @ObservedObject var library: MediaLibrary
    @State var sourceItem: MediaItem?
    @State private var source: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var instruction = ""
    @State private var providerID = ""
    @State private var running = false
    @State private var results: [MediaItem] = []
    @State private var error: String?

    private let quick = [
        ("Remove background", "Remove the background", "scissors"),
        ("Beach background", "Change the background to a sunny beach", "photo"),
        ("More realistic", "Make this look more realistic", "camera"),
        ("Warmer light", "Make the lighting warmer", "sun.max"),
        ("Enhance", "Enhance", "wand.and.stars"),
        ("Upscale 2×", "Upscale", "arrow.up.left.and.arrow.down.right"),
        ("3 versions", "Create three different versions", "square.on.square"),
    ]

    var body: some View {
        Form {
            Section("Image") {
                if let source {
                    Image(uiImage: source).resizable().scaledToFit().frame(maxHeight: 280).frame(maxWidth: .infinity)
                }
                HStack {
                    PhotosPicker(selection: $pickerItem, matching: .images) { Label("Photos", systemImage: "photo") }
                    Spacer()
                    Button { showLibrary = true } label: { Label("Library", systemImage: "square.grid.2x2") }
                }
                .buttonStyle(.borderless)
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quick, id: \.0) { q in
                            Button { instruction = q.1; apply() } label: {
                                Label(q.0, systemImage: q.2).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(source == nil || running)
                        }
                    }
                }
                TextField("Describe the edit, e.g. remove the object on the left", text: $instruction, axis: .vertical)
                ImageProviderPicker(creative: creative, selection: $providerID, needs: [.instructionEdit])
                Button { apply() } label: { Label(running ? "Editing…" : "Apply edit", systemImage: "wand.and.rays").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || instruction.trimmed.isEmpty || running)
                if running, let job = creative.jobs.first, job.state == .running {
                    if let p = job.progress { ProgressView(value: p) } else { ProgressView() }
                    Text(job.message).font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: { Text("Edit") } footer: {
                Text("Background removal, enhancement, warmth and 2× upscaling run on device with classic (non-generative) processing. Other instructions use a generative provider: on-device Stable Diffusion re-imagines the whole image, while OpenAI and FLUX Kontext follow instructions more precisely (remote).")
            }
            if !results.isEmpty {
                Section("Results") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        ForEach(results) { item in
                            NavigationLink { MediaDetailView(item: item, library: library, creative: creative) } label: {
                                MediaThumb(item: item).aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                    Button("Continue editing the latest result") {
                        if let first = results.first { sourceItem = first; source = UIImage(contentsOfFile: first.url.path) }
                    }
                }
            }
        }
        .navigationTitle("Image Editor")
        .onAppear { if let s = sourceItem, source == nil { source = UIImage(contentsOfFile: s.url.path) } }
        .onChange(of: pickerItem) { item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { source = UIImage(data: d); sourceItem = nil } }
        }
        .sheet(isPresented: $showLibrary) {
            LibraryPicker(library: library, kind: .image) { item in sourceItem = item; source = UIImage(contentsOfFile: item.url.path) }
        }
    }

    private func apply() {
        guard let cg = source?.normalizedCGImage else { return }
        running = true
        error = nil
        let item = sourceItem
        Task {
            do {
                let out = try await creative.editImage(item, source: cg, instruction: instruction, mode: app.settings.mode,
                                                       providerID: providerID.isEmpty ? nil : providerID)
                results = out + results
            } catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

struct VideoEditorView: View {
    @ObservedObject var creative: CreativeService
    @ObservedObject var library: MediaLibrary
    @State var item: MediaItem?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var instruction = ""
    @State private var running = false
    @State private var error: String?
    @State private var result: MediaItem?

    var body: some View {
        Form {
            Section("Video") {
                if let item {
                    VideoPlayer(player: AVPlayer(url: item.url)).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(item.prompt.isEmpty ? item.name : item.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack {
                    PhotosPicker(selection: $pickerItem, matching: .videos) { Label("Photos", systemImage: "film") }
                    Spacer()
                    Button { showLibrary = true } label: { Label("Library", systemImage: "square.grid.2x2") }
                }
                .buttonStyle(.borderless)
            }
            Section {
                Button { run("Create a vertical version for social media") } label: { Label("Vertical 9:16 version (on device)", systemImage: "rectangle.portrait") }
                Button { run("Extend this scene") } label: { Label("Extend the scene (image-to-video + local join)", systemImage: "arrow.right.to.line") }
                TextField("Describe a change, e.g. change the environment to nighttime", text: $instruction, axis: .vertical)
                Button { run(instruction) } label: { Label(running ? "Working…" : "Apply change", systemImage: "wand.and.rays").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(item == nil || instruction.trimmed.isEmpty || running)
                if running, let job = creative.jobs.first, job.state == .running {
                    if let p = job.progress { ProgressView(value: p) } else { ProgressView() }
                    Text(job.message).font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: { Text("Edit") } footer: {
                Text("Vertical reframing runs locally. Extending uses the last frame as the start image for a connected video model, then joins the clips on device. Other changes remix the video (OpenAI) or re-generate it from the original prompt plus your change.")
            }
            if let result {
                Section("Result") {
                    VideoPlayer(player: AVPlayer(url: result.url)).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    NavigationLink("Details & export") { MediaDetailView(item: result, library: library, creative: creative) }
                    Button("Edit this result") { item = result; self.result = nil }
                }
            }
        }
        .navigationTitle("Video Editor")
        .onChange(of: pickerItem) { picked in
            Task {
                guard let movie = try? await picked?.loadTransferable(type: PickedMovie.self) else { return }
                let dest = MediaFiles.newURL(ext: movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension)
                try? FileManager.default.moveItem(at: movie.url, to: dest)
                item = library.add(MediaItem(kind: .video, name: "Imported video", fileName: dest.lastPathComponent, prompt: "",
                                             modelName: "Uploaded video", provider: "Uploaded", isLocal: true, operation: "upload"))
            }
        }
        .sheet(isPresented: $showLibrary) { LibraryPicker(library: library, kind: .video) { item = $0 } }
    }

    private func run(_ text: String) {
        guard let item else { return }
        running = true
        error = nil
        Task {
            do { result = try await creative.editVideo(item, instruction: text) } catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

struct LibraryPicker: View {
    @ObservedObject var library: MediaLibrary
    let kind: MediaItem.Kind
    var onPick: (MediaItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(library.items.filter { $0.kind == kind }) { item in
                        Button { onPick(item); dismiss() } label: { MediaThumb(item: item).aspectRatio(1, contentMode: .fit) }
                    }
                }
                .padding()
            }
            .navigationTitle("Choose from Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct LibraryView: View {
    @ObservedObject var library: MediaLibrary
    @ObservedObject var creative: CreativeService
    @State private var folder = "All"
    @State private var kindFilter = 0
    @State private var query = ""

    private var filtered: [MediaItem] {
        library.items.filter { item in
            (folder == "All" || (folder == "Favorites" ? item.favorite : item.folder == folder)) &&
            (kindFilter == 0 || (kindFilter == 1 ? item.kind == .image : item.kind == .video)) &&
            (query.isEmpty || item.prompt.localizedCaseInsensitiveContains(query) || item.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $kindFilter) { Text("All").tag(0); Text("Images").tag(1); Text("Videos").tag(2) }.pickerStyle(.segmented)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["All", "Favorites"] + library.folders, id: \.self) { f in
                            Button(f) { folder = f }.buttonStyle(.bordered).tint(folder == f ? .accentColor : .secondary)
                        }
                    }
                }
                if filtered.isEmpty {
                    EmptyStateView(symbol: "photo.stack", title: "Nothing here yet", message: "Images and videos you create are saved here with their prompts and settings.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 8)], spacing: 8) {
                    ForEach(filtered) { item in
                        NavigationLink { MediaDetailView(item: item, library: library, creative: creative) } label: {
                            MediaThumb(item: item).aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
                Text("\(library.items.count) items · \(ByteCountFormatter.file(library.usage()))").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .searchable(text: $query, prompt: "Search prompts")
        .navigationTitle("Library")
    }
}

struct MediaDetailView: View {
    @State var item: MediaItem
    @ObservedObject var library: MediaLibrary
    @ObservedObject var creative: CreativeService
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var newFolder = ""
    @State private var moving = false
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                if item.kind == .image, let img = UIImage(contentsOfFile: item.url.path) {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity)
                        .accessibilityLabel("Generated image: \(item.prompt)")
                } else if item.kind == .video {
                    VideoPlayer(player: AVPlayer(url: item.url)).frame(height: 260)
                }
                HStack {
                    Pill(text: item.isLocal ? "Created on device" : "Created remotely · \(item.provider)", symbol: item.isLocal ? "iphone" : "cloud",
                         tint: item.isLocal ? .green : .blue)
                    Pill(text: "AI-generated", symbol: "sparkles", tint: .purple)
                }
            }
            Section("Actions") {
                ShareLink(item: item.url) { Label("Share / Export", systemImage: "square.and.arrow.up") }
                Button {
                    Task {
                        do { try await library.saveToPhotos(item); message = "Saved to Photos." } catch { message = error.localizedDescription }
                    }
                } label: { Label("Save to Photos", systemImage: "photo.on.rectangle.angled") }
                Button { library.toggleFavorite(item); item.favorite.toggle() } label: {
                    Label(item.favorite ? "Unfavorite" : "Favorite", systemImage: item.favorite ? "star.fill" : "star")
                }
                Button { newName = item.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button { newFolder = item.folder; moving = true } label: { Label("Move to folder", systemImage: "folder") }
                if !item.prompt.isEmpty {
                    NavigationLink {
                        if item.kind == .image { ImageGeneratorView(creative: creative, library: library, prompt: item.prompt) }
                        else { VideoGeneratorView(creative: creative, library: library, prompt: item.prompt) }
                    } label: { Label("Reuse prompt", systemImage: "arrow.uturn.left") }
                }
                NavigationLink {
                    if item.kind == .image { ImageEditorView(creative: creative, library: library, sourceItem: item) }
                    else { VideoEditorView(creative: creative, library: library, item: item) }
                } label: { Label("Edit", systemImage: "wand.and.rays") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
            Section("Generation details") {
                if !item.prompt.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("Prompt").font(.caption).foregroundStyle(.secondary); Text(item.prompt).textSelection(.enabled) } }
                if !item.negativePrompt.isEmpty { StatRow(label: "Negative", value: item.negativePrompt, mono: false) }
                StatRow(label: "Model", value: item.modelName, mono: false)
                if !item.modelVersion.isEmpty { StatRow(label: "Version", value: item.modelVersion, mono: false) }
                StatRow(label: "Provider", value: item.provider, mono: false)
                StatRow(label: "Processing", value: item.isLocal ? "Local (on device)" : "Remote", mono: false)
                StatRow(label: "Operation", value: item.operation, mono: false)
                StatRow(label: "Created", value: item.created.formatted(date: .abbreviated, time: .shortened), mono: false)
                if item.width > 0 { StatRow(label: "Size", value: "\(item.width)×\(item.height)") }
                ForEach(item.settings.sorted(by: { $0.key < $1.key }).filter { $0.value != "" && $0.value != "-" }, id: \.key) { kv in
                    StatRow(label: kv.key.capitalized, value: kv.value, mono: false)
                }
                if let parent = library.item(item.parentID) {
                    NavigationLink { MediaDetailView(item: parent, library: library, creative: creative) } label: { Label("Source: \(parent.name)", systemImage: "arrow.turn.up.left") }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { library.rename(item, to: newName); item.name = newName }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Move to folder", isPresented: $moving) {
            TextField("Folder name (empty = none)", text: $newFolder)
            Button("Move") { library.move(item, to: newFolder.trimmed); item.folder = newFolder.trimmed }
            Button("Cancel", role: .cancel) {}
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { library.delete(item); dismiss() }
        }
    }
}

/// Plays a conversation video at a given time (used by timestamp chips).
struct VideoSeekSheet: View {
    let url: URL
    let time: Double
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .onAppear {
                    let p = AVPlayer(url: url)
                    p.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    p.play()
                    player = p
                }
                .onDisappear { player?.pause() }
                .navigationTitle("At \(VideoDossier.stamp(time))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
