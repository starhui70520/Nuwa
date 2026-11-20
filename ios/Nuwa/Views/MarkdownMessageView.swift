import SwiftUI
import UIKit

// MARK: - Cached Rich Markdown Parser (Zero Regex Re-compilation, Zero Scroll Jank)

private enum MarkdownBlock: Identifiable {
    case heading(id: Int, level: Int, attributed: AttributedString)
    case paragraph(id: Int, attributed: AttributedString)
    case listItem(id: Int, marker: String, attributed: AttributedString)
    case blockquote(id: Int, attributed: AttributedString)
    case code(id: Int, language: String, code: String)
    case math(id: Int, formula: String)
    case table(id: Int, headers: [String], rows: [[String]])
    case divider(id: Int)

    var id: Int {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _),
             .listItem(let id, _, _),
             .blockquote(let id, _),
             .code(let id, _, _),
             .math(let id, _),
             .table(let id, _, _),
             .divider(let id):
            return id
        }
    }
}

private final class CachedMarkdownBlocks: NSObject {
    let blocks: [MarkdownBlock]
    init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
}

private final class CachedInlineMarkdown: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private enum MarkdownParseCache {
    static let citationRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "\\[citation:(\\d+)\\]")
    static let inlineOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)

    static let cache: NSCache<NSString, CachedMarkdownBlocks> = {
        let c = NSCache<NSString, CachedMarkdownBlocks>()
        c.countLimit = 250
        c.totalCostLimit = 8 * 1024 * 1024
        return c
    }()

    static let inlineCache: NSCache<NSString, CachedInlineMarkdown> = {
        let cache = NSCache<NSString, CachedInlineMarkdown>()
        cache.countLimit = 512
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func parse(_ rawInput: String, isStreaming: Bool) -> [MarkdownBlock] {
        if isStreaming { return parseBlocks(cleanCitationTags(rawInput)) }
        let key = rawInput as NSString
        if let hit = cache.object(forKey: key) {
            return hit.blocks
        }
        let cleaned = cleanCitationTags(rawInput)
        let parsed = parseBlocks(cleaned)
        cache.setObject(CachedMarkdownBlocks(parsed), forKey: key, cost: key.length * 4)
        return parsed
    }

    private static func inlineAttributed(_ raw: String) -> AttributedString {
        let key = raw as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        let value = (try? AttributedString(markdown: raw, options: inlineOptions)) ?? AttributedString(raw)
        inlineCache.setObject(CachedInlineMarkdown(value), forKey: key, cost: key.length * 4)
        return value
    }

    private static func cleanCitationTags(_ input: String) -> String {
        guard let regex = citationRegex, input.contains("[citation:") else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: " [$1]")
    }

    private static func parseBlocks(_ input: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let lines = input.components(separatedBy: "\n")
        var idx = 0
        var nextId = 0
        var paraBuf: [String] = []

        func flushParagraph() {
            let joined = paraBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.paragraph(id: nextId, attributed: inlineAttributed(joined)))
                nextId += 1
            }
            paraBuf.removeAll(keepingCapacity: true)
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                idx += 1
                while idx < lines.count {
                    if lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        idx += 1
                        break
                    }
                    codeLines.append(lines[idx])
                    idx += 1
                }
                result.append(.code(id: nextId, language: lang, code: codeLines.joined(separator: "\n")))
                nextId += 1
                continue
            }

            if trimmed == "$$" || trimmed == "\\[" {
                flushParagraph()
                let closer = trimmed == "$$" ? "$$" : "\\]"
                var mathLines: [String] = []
                idx += 1
                while idx < lines.count {
                    if lines[idx].trimmingCharacters(in: .whitespaces) == closer {
                        idx += 1
                        break
                    }
                    mathLines.append(lines[idx])
                    idx += 1
                }
                result.append(.math(id: nextId, formula: mathLines.joined(separator: "\n")))
                nextId += 1
                continue
            }
            if trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4 {
                flushParagraph()
                let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                result.append(.math(id: nextId, formula: inner))
                nextId += 1
                idx += 1
                continue
            }

            if trimmed.contains("|") && idx + 1 < lines.count && isTableSeparator(lines[idx + 1]) {
                flushParagraph()
                let headers = splitTableRow(trimmed)
                idx += 2
                var rows: [[String]] = []
                while idx < lines.count {
                    let rowLine = lines[idx].trimmingCharacters(in: .whitespaces)
                    if rowLine.isEmpty || !rowLine.contains("|") { break }
                    rows.append(splitTableRow(rowLine))
                    idx += 1
                }
                result.append(.table(id: nextId, headers: headers, rows: rows))
                nextId += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                idx += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                result.append(.divider(id: nextId))
                nextId += 1
                idx += 1
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }
                let level = hashes.count
                if (1...4).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
                    flushParagraph()
                    let content = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                    result.append(.heading(id: nextId, level: level, attributed: inlineAttributed(content)))
                    nextId += 1
                    idx += 1
                    continue
                }
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var quoteLines: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") {
                        quoteLines.append(String(t.dropFirst(2)))
                        idx += 1
                    } else if t == ">" {
                        quoteLines.append("")
                        idx += 1
                    } else {
                        break
                    }
                }
                result.append(.blockquote(id: nextId, attributed: inlineAttributed(quoteLines.joined(separator: "\n"))))
                nextId += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                let content = String(trimmed.dropFirst(2))
                result.append(.listItem(id: nextId, marker: "•", attributed: inlineAttributed(content)))
                nextId += 1
                idx += 1
                continue
            }

            if let dotIdx = trimmed.firstIndex(of: "."),
               trimmed[..<dotIdx].allSatisfy(\.isNumber),
               !trimmed[..<dotIdx].isEmpty,
               trimmed.index(after: dotIdx) < trimmed.endIndex,
               trimmed[trimmed.index(after: dotIdx)] == " " {
                flushParagraph()
                let marker = String(trimmed[...dotIdx])
                let afterSpace = trimmed.index(dotIdx, offsetBy: 2)
                let content = String(trimmed[afterSpace...])
                result.append(.listItem(id: nextId, marker: marker, attributed: inlineAttributed(content)))
                nextId += 1
                idx += 1
                continue
            }

            paraBuf.append(line)
            idx += 1
        }

        flushParagraph()
        return result
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") && t.contains("|") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: ")
        return t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct MarkdownMessageView: View, Equatable {
    let text: String
    let citations: [TextCitation]
    let fontSize: Double
    let isStreaming: Bool
    let onCopyCode: (String) -> Void

    @Environment(\.openURL) private var openURL

    static func == (lhs: MarkdownMessageView, rhs: MarkdownMessageView) -> Bool {
        lhs.text == rhs.text && lhs.fontSize == rhs.fontSize && lhs.citations == rhs.citations
            && lhs.isStreaming == rhs.isStreaming
    }

    init(text: String, citations: [TextCitation] = [], fontSize: Double, isStreaming: Bool = false, onCopyCode: @escaping (String) -> Void) {
        self.text = text
        self.citations = citations
        self.fontSize = fontSize
        self.isStreaming = isStreaming
        self.onCopyCode = onCopyCode
    }

    var body: some View {
        let blocks = MarkdownParseCache.parse(text, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let attributed):
                    let size: CGFloat = level == 1 ? fontSize + 6 : (level == 2 ? fontSize + 4 : (level == 3 ? fontSize + 2 : fontSize))
                    Text(attributed)
                        .font(.system(size: size, weight: level <= 3 ? .bold : .semibold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .padding(.top, 4)
                        .textSelection(.enabled)

                case .paragraph(_, let attributed):
                    Text(attributed)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                case .listItem(_, let marker, let attributed):
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(attributed)
                            .font(.system(size: fontSize))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                        .lineSpacing(6)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .blockquote(_, let attributed):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.nuwaBrand.opacity(0.6))
                            .frame(width: 3)
                        Text(attributed)
                            .font(.system(size: fontSize - 0.5))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)

                case .code(_, let language, let code):
                    CodeBlockView(language: language, code: code, onCopy: onCopyCode)

                case .math(_, let formula):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(formula)
                            .font(.system(size: max(13, fontSize - 1), design: .serif).italic())
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(Color(.secondarySystemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                case .table(_, let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows, fontSize: max(13, fontSize - 1))

                case .divider:
                    Divider()
                        .padding(.vertical, 4)
                }
            }

            if !citations.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(citations.prefix(8).enumerated()), id: \.offset) { idx, cite in
                            Button {
                                if let url = URL(string: cite.url) {
                                    openURL(url)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 16, height: 16)
                                        .background(Color.nuwaBrand, in: Circle())
                                    Text(cite.title ?? URL(string: cite.url)?.host ?? "来源")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.nuwaLabelSecondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .nuwaPillSurface()
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let fontSize: Double

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                        Text(h)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(minWidth: 90, alignment: .leading)
                    }
                }
                .background(Color.primary.opacity(0.05))

                ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(0..<max(headers.count, row.count), id: \.self) { cIdx in
                            let val = cIdx < row.count ? row[cIdx] : ""
                            Text(val)
                                .font(.system(size: fontSize))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(minWidth: 90, alignment: .leading)
                        }
                    }
                    .background(rIdx % 2 == 1 ? Color.primary.opacity(0.02) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
            )
        }
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
                    .foregroundStyle(Color.nuwaLabelSecondary)
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
                        .foregroundStyle(copied ? .green : Color.nuwaLabelSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.nuwaLabelPrimary)
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

// MARK: - Lightweight In-Scroll Message Controls (Zero Glass Shader Overhead)

struct ReasoningDisclosureView: View {
    let reasoning: String
    let seconds: Double?
    let isStreaming: Bool
    let fontSize: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var headerTitle: String {
        if isStreaming {
            if let seconds {
                return String(format: "正在深度思考 (%.0f 秒)...", seconds)
            }
            return "正在思考..."
        }
        if let seconds {
            return String(format: "已思考（用时 %.0f 秒）", max(1, seconds))
        }
        return "思考过程"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(headerTitle)
                        .font(.system(size: max(12, fontSize - 1)))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(NuwaTactileButtonStyle())

            if expanded {
                Text(reasoning)
                    .font(.system(size: max(12, fontSize - 1)))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.nuwaControlBorder).frame(width: 1)
                    }
            }
        }
    }
}

struct SearchSummaryPillView: View {
    let results: [WebSearchResultItem]
    let isSearching: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if isSearching {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在搜索网页...")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                } else {
                    Image(systemName: "globe")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.nuwaBrandText)
                    Text("已阅读 \(results.count) 个网页")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .nuwaPillSurface()
        }
        .buttonStyle(NuwaTactileButtonStyle())
        .disabled(results.isEmpty)
    }
}

struct SearchPanelSheet: View {
    let results: [WebSearchResultItem]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                    Button {
                        if let url = URL(string: item.url) {
                            openURL(url)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("\(idx + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Color.nuwaBrand, in: Circle())
                                Text(item.siteName ?? URL(string: item.url)?.host ?? "")
                                    .font(.caption)
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .lineLimit(1)
                                Spacer()
                                if let age = item.pageAge, !age.isEmpty {
                                    Text(age)
                                        .font(.caption2)
                                        .foregroundStyle(Color.nuwaLabelTertiary)
                                }
                            }
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .lineLimit(2)
                            if let snippet = item.snippet, !snippet.isEmpty {
                                Text(snippet)
                                    .font(.caption)
                                    .foregroundStyle(Color.nuwaLabelSecondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("搜索结果 (\(results.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct BranchSwitcherView: View {
    let versionInfo: MessageVersionInfo
    let onSelect: (UUID) -> Void

    var body: some View {
        if versionInfo.count > 1 {
            HStack(spacing: 2) {
                Button {
                    if versionInfo.index > 0 {
                        onSelect(versionInfo.ids[versionInfo.index - 1])
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(versionInfo.index > 0 ? Color.nuwaLabelSecondary : Color.nuwaLabelTertiary.opacity(0.4))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(versionInfo.index == 0)

                Text("\(versionInfo.index + 1)/\(versionInfo.count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.nuwaLabelSecondary)

                Button {
                    if versionInfo.index + 1 < versionInfo.count {
                        onSelect(versionInfo.ids[versionInfo.index + 1])
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(versionInfo.index + 1 < versionInfo.count ? Color.nuwaLabelSecondary : Color.nuwaLabelTertiary.opacity(0.4))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(versionInfo.index + 1 >= versionInfo.count)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .nuwaPillSurface()
        }
    }
}

/// Displays read_link / open_page / find_in_page tool activity pills matching ReplyArea.tsx.
struct ReplyToolsStatusView: View {
    let blocks: [ReplyBlock]
    let isStreaming: Bool
    @Environment(\.openURL) private var openURL

    private struct FetchedPage: Identifiable {
        let id: String
        let url: String
        let title: String
        let failed: Bool
    }

    private var activeReadingLink: String? {
        guard isStreaming else { return nil }
        var finishedIds = Set<String>()
        for b in blocks {
            if case .webFetchResult(_, let tid, _, _, _) = b { finishedIds.insert(tid) }
        }
        for b in blocks.reversed() {
            if case .serverToolUse(_, let info) = b,
               (info.action == "read_link" || info.action == "open_page"),
               !finishedIds.contains(info.id) {
                return info.url
            }
        }
        return nil
    }

    private var fetchedPages: [FetchedPage] {
        var seen = Set<String>()
        var pages: [FetchedPage] = []
        for b in blocks {
            if case .webFetchResult(_, let tid, _, let info, _) = b {
                let url = info.url ?? ""
                if url.isEmpty || seen.contains(url) { continue }
                seen.insert(url)
                let label = (info.title?.isEmpty == false) ? info.title! : (URL(string: url)?.host ?? url)
                pages.append(FetchedPage(id: tid, url: url, title: label, failed: info.errorCode != nil))
            }
        }
        return pages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let readingUrl = activeReadingLink {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在浏览网页")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                    if let host = URL(string: readingUrl)?.host {
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(Color.nuwaLabelTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .nuwaPillSurface()
            }

            if !fetchedPages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(fetchedPages.prefix(5)) { page in
                            Button {
                                if !page.failed, let url = URL(string: page.url) {
                                    openURL(url)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: page.failed ? "exclamationmark.circle" : "link")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(page.failed ? .orange : Color.nuwaBrandText)
                                    Text(page.title)
                                        .font(.caption)
                                        .foregroundStyle(Color.nuwaLabelSecondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .nuwaPillSurface()
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                            .disabled(page.failed)
                        }
                    }
                }
            }
        }
    }
}

/// Full-screen pinch-to-zoom image preview overlay for message/draft image attachments.
struct ImageLightboxOverlay: View {
    let image: UIImage
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1.0, min(4.0, value))
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                if scale < 1.05 { scale = 1.0 }
                            }
                        }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .nuwaGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .padding(.trailing, 18)
        }
    }
}
