import SwiftUI
import UIKit

private enum MarkdownBlock: Identifiable {
    case text(id: Int, content: String)
    case code(id: Int, language: String, code: String)

    var id: Int {
        switch self {
        case .text(let id, _), .code(let id, _, _): return id
        }
    }
}

struct MarkdownMessageView: View {
    let text: String
    let fontSize: Double
    let onCopyCode: (String) -> Void

    private var blocks: [MarkdownBlock] {
        Self.parseBlocks(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .text(_, let content):
                    markdownText(content)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(_, let language, let code):
                    CodeBlockView(language: language, code: code, onCopy: onCopyCode)
                }
            }
        }
    }

    @ViewBuilder
    private func markdownText(_ raw: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: raw, options: options) {
            Text(attributed)
        } else {
            Text(raw)
        }
    }

    private static func parseBlocks(_ input: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let lines = input.components(separatedBy: "\n")
        var currentText: [String] = []
        var currentCode: [String] = []
        var inCodeBlock = false
        var codeLang = ""
        var nextId = 0

        func flushText() {
            let joined = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.text(id: nextId, content: joined))
                nextId += 1
            }
            currentText.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    result.append(.code(id: nextId, language: codeLang, code: currentCode.joined(separator: "\n")))
                    nextId += 1
                    currentCode.removeAll()
                    codeLang = ""
                    inCodeBlock = false
                } else {
                    flushText()
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                currentCode.append(line)
            } else {
                currentText.append(line)
            }
        }

        if inCodeBlock {
            result.append(.code(id: nextId, language: codeLang, code: currentCode.joined(separator: "\n")))
        } else {
            flushText()
        }
        return result
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    let onCopy: (String) -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    onCopy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(.secondarySystemBackground).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }
}

struct ReasoningDisclosureView: View {
    let reasoning: String
    let seconds: Double?
    let isStreaming: Bool

    @State private var expanded = false

    private var headerTitle: String {
        if isStreaming {
            if let seconds {
                return String(format: "正在深度思考 (%.1fs)...", seconds)
            }
            return "正在深度思考..."
        }
        if let seconds {
            return String(format: "已深度思考 (用时 %.1f 秒)", seconds)
        }
        return "思考过程"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.nuwaBrand)
                    Text(headerTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .nuwaGlass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground).opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}
