import SwiftUI
import PhotosUI
import AVKit

struct ImageGeneratorView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var creative: CreativeService
    @ObservedObject var library: MediaLibrary
    @State var prompt = ""
    @State private var negative = ""
    @State private var styleID = "custom"
    @State private var aspect: AspectRatio = .square
    @State private var quality: GenerationQuality = .standard
    @State private var count = 1
    @State private var strength = 0.6
    @State private var transparent = false
    @State private var providerID = ""
    @State private var references: [UIImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var running = false
    @State private var refining = false
    @State private var results: [MediaItem] = []
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt).frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty { Text("Describe the image you want…").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 4).allowsHitTesting(false) }
                    }
                HStack {
                    Button {
                        refining = true
                        Task { prompt = await creative.refinePrompt(prompt, video: false, mode: app.settings.mode); refining = false }
                    } label: { Label(refining ? "Refining…" : "Refine with AI", systemImage: "sparkles") }
                    .disabled(prompt.trimmed.isEmpty || refining)
                    Spacer()
                    Text("Runs locally with your chat model").font(.caption2).foregroundStyle(.tertiary)
                }
            } header: { Text("Prompt") }

            Section("Style") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(StylePreset.all) { s in
                            Button { styleID = s.id } label: {
                                Text(s.name).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(styleID == s.id ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill), in: Capsule())
                                    .foregroundStyle(styleID == s.id ? Color.accentColor : .primary)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Picker("Aspect ratio", selection: $aspect) { ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Quality", selection: $quality) { ForEach(GenerationQuality.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Stepper("Variations: \(count)", value: $count, in: 1...4)
            }

            Section {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .images) {
                    Label(references.isEmpty ? "Add reference images" : "Change reference images", systemImage: "photo.on.rectangle")
                }
                if !references.isEmpty {
                    ScrollView(.horizontal) {
                        HStack { ForEach(references.indices, id: \.self) { Image(uiImage: references[$0]).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8)) } }
                    }
                    VStack(alignment: .leading) {
                        Text("Reference influence: \(Int((1 - strength) * 100))%").font(.caption)
                        Slider(value: $strength, in: 0.2...0.95)
                    }
                }
            } header: { Text("Reference") } footer: {
                Text("References are uploaded only if you pick a remote provider.")
            }

            Section("Advanced") {
                TextField("Negative prompt (things to avoid)", text: $negative)
                Toggle("Transparent background", isOn: $transparent)
                ImageProviderPicker(creative: creative, selection: $providerID, needs: neededCapabilities)
            }

            Section {
                if running, let job = creative.jobs.first, job.state == .running {
                    VStack(alignment: .leading, spacing: 6) {
                        if let p = job.progress { ProgressView(value: p) } else { ProgressView() }
                        Text("\(job.message) · \(job.providerName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancel", role: .destructive) { creative.cancel(job); task?.cancel() }
                } else {
                    Button { generate() } label: {
                        Label("Generate", systemImage: "wand.and.stars").frame(maxWidth: .infinity).font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmed.isEmpty)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
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
                }
            }
        }
        .navigationTitle("Image Generator")
        .onChange(of: pickerItems) { items in
            Task {
                var imgs: [UIImage] = []
                for i in items { if let d = try? await i.loadTransferable(type: Data.self), let u = UIImage(data: d) { imgs.append(u) } }
                references = imgs
            }
        }
    }

    private var neededCapabilities: Set<ImageCapability> {
        var n: Set<ImageCapability> = [.textToImage]
        if !references.isEmpty { n.insert(.reference) }
        if transparent { n.insert(.transparentBackground) }
        return n
    }

    private func generate() {
        var req = ImageGenRequest(prompt: prompt.trimmed)
        req.negativePrompt = negative
        req.style = StylePreset.named(styleID)
        req.aspect = aspect
        req.quality = quality
        req.count = count
        req.referenceImages = references.compactMap(\.normalizedCGImage)
        req.referenceStrength = strength
        req.transparentBackground = transparent
        running = true
        error = nil
        task = Task {
            do { results = try await creative.generateImages(req, providerID: providerID.isEmpty ? nil : providerID, mode: app.settings.mode) + results }
            catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

struct VideoGeneratorView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var creative: CreativeService
    @ObservedObject var library: MediaLibrary
    @State var prompt = ""
    @State private var duration = 8
    @State private var aspect: AspectRatio = .landscape
    @State private var styleID = "cinematic"
    @State private var camera = ""
    @State private var motion = ""
    @State private var lighting = ""
    @State private var mood = ""
    @State private var audio = false
    @State private var providerID = ""
    @State private var reference: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var running = false
    @State private var result: MediaItem?
    @State private var error: String?
    @State private var refinement = ""
    @State private var statuses: [String: ProviderStatus] = [:]

    private let cameraPresets = ["Static", "Slow push-in", "Slow pull-out", "Orbit around subject", "Tracking shot", "Aerial drone shot", "Handheld", "Low-angle pan", "Dolly zoom"]

    private var provider: VideoGenerationProvider? {
        providerID.isEmpty ? creative.videoProviders.first { statuses[$0.id]?.available == true } : creative.videoProvider(providerID)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt).frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty { Text("Describe the video: subject, action, setting…").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 4).allowsHitTesting(false) }
                    }
                Button { Task { prompt = await creative.refinePrompt(prompt, video: true, mode: app.settings.mode) } } label: {
                    Label("Develop prompt with AI", systemImage: "sparkles")
                }.disabled(prompt.trimmed.isEmpty)
            } header: { Text("Prompt") }

            Section("Shot") {
                Picker("Duration", selection: $duration) {
                    ForEach(provider?.durations ?? [4, 8, 12], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Aspect ratio", selection: $aspect) {
                    ForEach(provider?.aspects ?? [.landscape, .portrait], id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Camera", selection: $camera) {
                    Text("Model decides").tag("")
                    ForEach(cameraPresets, id: \.self) { Text($0).tag($0) }
                }
                TextField("Subject / environment motion", text: $motion)
                TextField("Lighting (e.g. neon night, golden hour)", text: $lighting)
                TextField("Mood", text: $mood)
                Picker("Style", selection: $styleID) { ForEach(StylePreset.all) { Text($0.name).tag($0.id) } }
                if provider?.capabilities.contains(.audio) == true { Toggle("Generate audio", isOn: $audio) }
            }

            Section {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(reference == nil ? "Start from an image (image-to-video)" : "Change start image", systemImage: "photo")
                }
                if let reference {
                    HStack {
                        Image(uiImage: reference).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                        Button("Remove", role: .destructive) { self.reference = nil }
                    }
                }
                Picker("Provider", selection: $providerID) {
                    Text("Automatic").tag("")
                    ForEach(creative.videoProviders, id: \.id) { p in
                        Text("\(p.name)\(statuses[p.id]?.available == false ? " (unavailable)" : "")").tag(p.id)
                    }
                }
                if let p = provider, let s = statuses[p.id] {
                    Label(s.reason, systemImage: s.available ? "cloud" : "exclamationmark.triangle").font(.caption).foregroundStyle(s.available ? Color.secondary : Color.orange)
                } else if statuses.values.allSatisfy({ !$0.available }) {
                    Text("No video provider is available. Video generation runs only on connected providers (OpenAI or fal.ai). Add a key in Studio → Providers and enable cloud generation.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Source & provider") } footer: {
                Text("Your prompt (and start image, if any) is sent to the selected provider. Generation typically takes 1–5 minutes; progress shown is reported by the provider.")
            }

            Section {
                if running, let job = creative.jobs.first, job.state == .running {
                    if let p = job.progress { ProgressView(value: p) } else { ProgressView() }
                    Text(job.message).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel", role: .destructive) { creative.cancel(job) }
                } else {
                    Button { generate(remix: nil) } label: { Label("Generate video", systemImage: "film").frame(maxWidth: .infinity).font(.headline) }
                        .buttonStyle(.borderedProminent)
                        .disabled(prompt.trimmed.isEmpty)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }

            if let result {
                Section("Result") {
                    VideoPlayer(player: AVPlayer(url: result.url)).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 12))
                    NavigationLink("Details & export") { MediaDetailView(item: result, library: library, creative: creative) }
                    TextField("Refine: e.g. make the lighting darker, increase the rain", text: $refinement, axis: .vertical)
                    Button("Apply refinement") {
                        let item = result
                        running = true
                        Task {
                            do { self.result = try await creative.editVideo(item, instruction: refinement); refinement = "" }
                            catch { self.error = error.localizedDescription }
                            running = false
                        }
                    }.disabled(refinement.trimmed.isEmpty || running)
                }
            }
        }
        .navigationTitle("Video Generator")
        .task {
            for p in creative.videoProviders { statuses[p.id] = await p.status() }
        }
        .onChange(of: pickerItem) { item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { reference = UIImage(data: d) } }
        }
    }

    private func generate(remix: String?) {
        var req = VideoGenRequest(prompt: prompt.trimmed)
        req.durationSeconds = duration
        req.aspect = aspect
        req.style = StylePreset.named(styleID)
        req.camera = camera
        req.motion = motion
        req.lighting = lighting
        req.mood = mood
        req.audio = audio
        req.referenceImage = reference?.normalizedCGImage
        req.remixOf = remix
        running = true
        error = nil
        Task {
            do { result = try await creative.generateVideo(req, providerID: providerID.isEmpty ? nil : providerID) }
            catch { self.error = error.localizedDescription }
            running = false
        }
    }
}
