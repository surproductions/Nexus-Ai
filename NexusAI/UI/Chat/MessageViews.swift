import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    var showThinking: Bool
    var onTrace: () -> Void
    var onRegenerate: (() -> Void)?
    var onDelete: () -> Void
    /// Video in the conversation that timestamps in this message refer to.
    var videoURL: URL? = nil
    var onSeek: ((URL, Double) -> Void)? = nil
    @State private var thinkingExpanded = false

    private var timestamps: [Double] {
        guard videoURL != nil, let re = try? NSRegularExpression(pattern: #"\b(\d{1,2}):([0-5]\d)\b"#) else { return [] }
        let text = message.content
        var seen = Set<Int>()
        var out: [Double] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
                  let mm = Int(text[r1]), let ss = Int(text[r2]) else { continue }
            let t = mm * 60 + ss
            if seen.insert(t).inserted { out.append(Double(t)) }
            if out.count >= 10 { break }
        }
        return out
    }

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantBody
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    AttachmentStrip(attachments: message.attachments, onPlay: { url in onSeek?(url, 0) })
                }
                Text(message.content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)
            }
        }
        .contextMenu {
            Button { UIPasteboard.general.string = message.content } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showThinking, let thinking = message.meta?.thinking, !thinking.isEmpty {
                ThinkingDisclosure(text: thinking, expanded: $thinkingExpanded, live: false)
            }
            MarkdownView(text: message.content)
            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments, large: true, onPlay: { url in onSeek?(url, 0) })
            }
            if let videoURL, !timestamps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(timestamps, id: \.self) { t in
                            Button { onSeek?(videoURL, t) } label: { Label(VideoDossier.stamp(t), systemImage: "play.circle") }
                                .font(.caption.monospacedDigit()).buttonStyle(.bordered).controlSize(.small)
                                .accessibilityLabel("Play video at \(VideoDossier.stamp(t))")
                        }
                    }
                }
            }
            if let meta = message.meta {
                if !meta.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(meta.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !meta.sources.isEmpty { SourcesView(sources: meta.sources) }
                MetaFooter(meta: meta, onTrace: onTrace, onRegenerate: onRegenerate)
            }
        }
        .contextMenu {
            Button { UIPasteboard.general.string = message.content } label: { Label("Copy", systemImage: "doc.on.doc") }
            ShareLink(item: message.content) { Label("Share", systemImage: "square.and.arrow.up") }
            if let onRegenerate { Button(action: onRegenerate) { Label("Regenerate", systemImage: "arrow.clockwise") } }
            Button(action: onTrace) { Label("Reasoning trace", systemImage: "list.bullet.rectangle") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

struct StreamingRow: View {
    @ObservedObject var session: TurnSession
    var showThinking: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showThinking && !session.thinking.isEmpty {
                ThinkingDisclosure(text: session.thinking, expanded: $expanded, live: session.text.isEmpty)
            }
            if session.text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(session.status.isEmpty ? "Thinking…" : session.status)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                .transition(.opacity)
            } else {
                MarkdownView(text: session.text)
                if !session.status.isEmpty {
                    Text(session.status).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if session.trace.count > 1 {
                LiveTrace(steps: session.trace)
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.text.isEmpty)
    }
}

struct ThinkingDisclosure: View {
    var text: String
    @Binding var expanded: Bool
    var live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").imageScale(.small)
                    Text(live ? "Thinking…" : "Thought process").font(.caption.weight(.medium))
                    Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded || live {
                Text(live ? String(text.suffix(600)) : text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .lineLimit(live ? 6 : nil)
            }
        }
    }
}

struct LiveTrace: View {
    var steps: [TraceStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps.suffix(6)) { step in
                HStack(spacing: 6) {
                    statusIcon(step.status)
                    Text(step.agent).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(step.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(Color(uiColor: .tertiarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

@ViewBuilder
func statusIcon(_ s: TraceStep.Status) -> some View {
    switch s {
    case .running: ProgressView().controlSize(.mini)
    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
    case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).imageScale(.small)
    case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary).imageScale(.small)
    }
}

struct MetaFooter: View {
    var meta: MessageMeta
    var onTrace: () -> Void
    var onRegenerate: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { content } }
        }
    }

    @ViewBuilder private var content: some View {
        Pill(text: meta.mode.shortTitle, symbol: meta.mode.symbol, tint: meta.mode.tint)
        if !meta.modelName.isEmpty {
            Pill(text: meta.modelName, symbol: meta.usedCloud ? "cloud" : "iphone", tint: meta.usedCloud ? .orange : .secondary)
        }
        if let tps = meta.tokensPerSecond, tps > 0 { Pill(text: String(format: "%.1f tok/s", tps)) }
        if let ms = meta.totalMs { Pill(text: ms > 9_999 ? "\(ms / 1000)s" : String(format: "%.1fs", Double(ms) / 1000)) }
        if meta.usedWeb { Pill(text: "Web", symbol: "globe", tint: .blue) }
        if !meta.toolsUsed.isEmpty { Pill(text: meta.toolsUsed.joined(separator: ", "), symbol: "wrench.and.screwdriver") }
        if meta.verified != nil { Pill(text: "Verified", symbol: "checkmark.shield", tint: .green) }
        Button(action: onTrace) { Image(systemName: "list.bullet.rectangle").font(.caption) }
            .buttonStyle(.borderless).accessibilityLabel("Show reasoning trace")
        if let onRegenerate {
            Button(action: onRegenerate) { Image(systemName: "arrow.clockwise").font(.caption) }
                .buttonStyle(.borderless).accessibilityLabel("Regenerate")
        }
    }
}

struct SourcesView: View {
    var sources: [SourceRef]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { expanded.toggle() } } label: {
                Label("\(sources.count) source\(sources.count == 1 ? "" : "s")", systemImage: "link")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if expanded {
                ForEach(Array(sources.enumerated()), id: \.offset) { i, s in
                    VStack(alignment: .leading, spacing: 2) {
                        if let url = URL(string: s.location), url.scheme?.hasPrefix("http") == true {
                            Link("[\(i + 1)] \(s.title)", destination: url).font(.caption)
                        } else {
                            Text("[\(i + 1)] \(s.title) — \(s.location)").font(.caption)
                        }
                        if !s.snippet.isEmpty { Text(s.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
    }
}

struct AttachmentStrip: View {
    var attachments: [Attachment]
    var large = false
    var onPlay: ((URL) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    switch a.kind {
                    case .image:
                        if let img = UIImage(contentsOfFile: a.fileURL.path) {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: large ? 220 : 72, height: large ? 220 : 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .contextMenu {
                                    ShareLink(item: a.fileURL) { Label("Share", systemImage: "square.and.arrow.up") }
                                }
                                .accessibilityLabel(a.mediaID != nil ? "Generated image \(a.filename)" : "Attached image \(a.filename)")
                        } else {
                            Label(a.filename, systemImage: "photo").font(.caption)
                        }
                    case .video:
                        Button { onPlay?(a.fileURL) } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
                                VStack(spacing: 4) {
                                    Image(systemName: "play.circle.fill").font(.title)
                                    Text(a.filename).font(.caption2).lineLimit(1)
                                }
                                .foregroundStyle(.white).padding(6)
                            }
                            .frame(width: large ? 220 : 110, height: large ? 124 : 72)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play video \(a.filename)")
                    case .document:
                        Label(a.filename, systemImage: "doc.text").font(.caption).lineLimit(1)
                            .padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }
}

struct TraceSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let meta = message.meta {
                    Section("Routing") {
                        StatRow(label: "Mode", value: meta.mode.title, mono: false)
                        StatRow(label: "Model", value: meta.modelName.isEmpty ? "—" : meta.modelName, mono: false)
                        if !meta.routeReason.isEmpty { Text(meta.routeReason).font(.footnote).foregroundStyle(.secondary) }
                        StatRow(label: "Processing", value: meta.usedCloud ? "Cloud provider" : "On this device", mono: false)
                    }
                    Section("Performance (measured)") {
                        if let t = meta.ttftMs { StatRow(label: "Time to first token", value: "\(t) ms") }
                        if let s = meta.tokensPerSecond { StatRow(label: "Decode speed", value: String(format: "%.1f tok/s", s)) }
                        if let n = meta.generatedTokens { StatRow(label: "Generated tokens", value: "\(n)") }
                        if let total = meta.totalMs { StatRow(label: "Total time", value: "\(total) ms") }
                    }
                    if let v = meta.verified {
                        Section("Verification") { Text(v).font(.footnote) }
                    }
                    Section("Steps") {
                        ForEach(meta.trace) { step in
                            HStack(alignment: .top, spacing: 10) {
                                statusIcon(step.status).frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(step.agent).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Spacer()
                                        if step.durationMs > 0 { Text("\(step.durationMs) ms").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
                                    }
                                    Text(step.title).font(.subheadline)
                                    if !step.detail.isEmpty { Text(step.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                } else {
                    Text("No trace recorded for this message.")
                }
            }
            .navigationTitle("Reasoning trace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
