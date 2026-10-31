import SwiftUI
import PhotosUI
import AVKit

/// Upload photos/videos and have a conversation about them. Uses the same orchestration pipeline as Chat (so all
/// analysis runs on device unless a cloud model is explicitly selected).
struct MediaAnalyzerView: View {
    @EnvironmentObject var app: AppModel
    @State private var chat: ChatViewModel?

    var body: some View {
        Group {
            if let chat { AnalyzerBody(chat: chat, settings: app.settings) } else { ProgressView() }
        }
        .navigationTitle("Media Analyzer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard chat == nil else { return }
            let vm = ChatViewModel(orchestrator: app.orchestrator, store: app.conversations, documents: app.documents, settings: app.settings)
            vm.library = app.library
            vm.conversation.title = "Media analysis"
            chat = vm
        }
    }
}

private struct AnalyzerBody: View {
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var settings: SettingsStore
    @State private var items: [PhotosPickerItem] = []
    @State private var seek: (URL, Double)?
    @State private var showSeek = false
    @State private var loading = false

    private let actions = [
        ("Summarize", "Summarize everything in the attached media. For videos, give a timestamped summary of the important moments."),
        ("Detailed analysis", "Give a detailed analysis of the attached media: what is shown, what is happening, notable details and anything unusual."),
        ("Extract text", "Extract all readable text from the attached media exactly as written, organized by image or timestamp."),
        ("Report", "Write a structured report about the attached media with sections: Overview, Key observations, Text found, Timeline (for videos), Conclusions."),
        ("Compare", "Compare the attached images or videos and list their similarities and differences."),
    ]

    private var latestVideoURL: URL? {
        chat.conversation.messages.flatMap(\.attachments).last { $0.kind == .video }?.fileURL
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if chat.conversation.messages.isEmpty && chat.pending.isEmpty {
                        EmptyStateView(symbol: "eye", title: "Analyze photos and videos",
                                       message: "Add screenshots, photos, diagrams, charts or videos, then ask anything. Frames, on-screen text and speech are processed on this iPhone.")
                    }
                    if let url = latestVideoURL {
                        VideoPlayer(player: AVPlayer(url: url)).frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(chat.conversation.messages) { msg in
                        MessageRow(message: msg, showThinking: settings.showThinking, onTrace: {}, onRegenerate: nil,
                                   onDelete: { chat.delete(msg) }, videoURL: latestVideoURL,
                                   onSeek: { url, t in seek = (url, t); showSeek = true })
                    }
                    if let s = chat.session { StreamingRow(session: s, showThinking: settings.showThinking) }
                    if let e = chat.errorMessage { Text(e).font(.footnote).foregroundStyle(.red) }
                }
                .padding()
            }
            VStack(spacing: 8) {
                if !chat.pending.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(chat.pending) { p in
                                Label(p.filename, systemImage: p.kind == .video ? "film" : "photo").font(.caption)
                                    .padding(8).background(Theme.card, in: Capsule())
                            }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(actions, id: \.0) { a in
                            Button(a.0) { chat.send(a.1) }
                                .buttonStyle(.bordered)
                                .disabled(chat.isGenerating || (chat.pending.isEmpty && chat.conversation.messages.isEmpty))
                        }
                    }
                }
                HStack {
                    PhotosPicker(selection: $items, maxSelectionCount: 6, matching: .any(of: [.images, .videos])) {
                        Image(systemName: loading ? "hourglass" : "plus.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Add photos or videos")
                    TextField("Ask about your media", text: $chat.draft, axis: .vertical).textFieldStyle(.roundedBorder)
                    if chat.isGenerating {
                        Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    } else {
                        Button { chat.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .disabled(chat.draft.trimmed.isEmpty && chat.pending.isEmpty)
                    }
                }
                Text("Mode: \(chat.mode.title) — \(chat.mode == .instant ? "8 frames, labels and OCR" : chat.mode == .thinking ? "16 frames, captions with a vision model" : "32 frames, detailed captions, longer transcripts")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .background(.bar)
        }
        .onChange(of: items) { picked in
            loading = true
            Task {
                for item in picked {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
                       let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                        chat.addVideo(movie.url)
                    } else if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        chat.addImage(img)
                    }
                }
                items = []
                loading = false
            }
        }
        .sheet(isPresented: $showSeek) {
            if let seek { VideoSeekSheet(url: seek.0, time: seek.1) }
        }
    }
}
