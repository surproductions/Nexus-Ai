import SwiftUI

enum Theme {
    static let corner: CGFloat = 14
    static let bubble = Color(uiColor: .secondarySystemBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let hairline = Color(uiColor: .separator).opacity(0.5)
}

struct Pill: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var mono = true

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(mono ? .body.monospacedDigit() : .body).multilineTextAlignment(.trailing)
        }
    }
}

struct MeterBar: View {
    var value: Double   // 0…1
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(tint).frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Lightweight Markdown renderer suited to streamed LLM output.
struct MarkdownView: View {
    var text: String

    enum Block: Hashable {
        case heading(Int, String), paragraph(String), bullet(String, Int), numbered(String, String), code(String, String), quote(String), rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let t):
            inline(t).font(level == 1 ? .title3.weight(.semibold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                .padding(.top, 4)
        case .paragraph(let t):
            inline(t).fixedSize(horizontal: false, vertical: true)
        case .bullet(let t, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(t).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).monospacedDigit().foregroundStyle(.secondary)
                inline(t).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code)
        case .quote(let t):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                inline(t).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var inCode = false
        var codeLang = ""
        var code: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLang, code.joined(separator: "\n")))
                    code = []; inCode = false
                } else {
                    flush(); inCode = true; codeLang = String(t.dropFirst(3)).trimmed
                }
                continue
            }
            if inCode { code.append(line); continue }
            if t.isEmpty { flush(); continue }
            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                if level <= 6, t.dropFirst(level).first == " " {
                    flush(); blocks.append(.heading(level, String(t.dropFirst(level + 1)))); continue
                }
            }
            if t == "---" || t == "***" || t == "___" { flush(); blocks.append(.rule); continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                flush()
                let depth = (line.prefix(while: { $0 == " " }).count) / 2
                blocks.append(.bullet(String(t.dropFirst(2)), min(depth, 3))); continue
            }
            if let r = t.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                flush(); blocks.append(.numbered(String(t[r]).trimmed, String(t[r.upperBound...]))); continue
            }
            if t.hasPrefix("> ") { flush(); blocks.append(.quote(String(t.dropFirst(2)))); continue }
            para.append(line)
        }
        if inCode { blocks.append(.code(codeLang, code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

struct CodeBlockView: View {
    var language: String
    var code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.footnote, design: .monospaced)).padding(10).textSelection(.enabled)
            }
        }
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}
