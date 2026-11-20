import SwiftUI
import UIKit

// MARK: - Cached Rich Markdown Parser (Bulletproof Code Blocks, Inline Code Bubbles, Zero Scroll Jank)

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

private final class CachedCodeHighlight: NSObject {
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

    static func inlineAttributed(_ raw: String) -> AttributedString {
        let key = raw as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        let parsed = (try? AttributedString(markdown: raw, options: inlineOptions)) ?? AttributedString(raw)
        let styled = styleInlineCodeRuns(parsed)
        inlineCache.setObject(CachedInlineMarkdown(styled), forKey: key, cost: key.length * 4)
        return styled
    }

    /// Styles inline `code` runs as distinct rounded-feeling highlight pills (matching theme.css inline-code bubble).
    private static func styleInlineCodeRuns(_ source: AttributedString) -> AttributedString {
        var hasCode = false
        for run in source.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                hasCode = true
                break
            }
        }
        guard hasCode else { return source }

        var result = AttributedString()
        for run in source.runs {
            var segment = AttributedString(source[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                var pad = AttributedString("\u{2009}")
                pad.inlinePresentationIntent = .code
                pad.backgroundColor = Color.nuwaInlineCodeFill
                segment.backgroundColor = Color.nuwaInlineCodeFill
                segment.foregroundColor = Color.nuwaLabelPrimary
                result.append(pad)
                result.append(segment)
                result.append(pad)
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func cleanCitationTags(_ input: String) -> String {
        guard let regex = citationRegex, input.contains("[citation:") else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: " [$1]")
    }

    private struct FenceInfo {
        let char: Character
        let count: Int
        let language: String
        let singleLineCode: String?
    }

    /// Detects opening code fences: ```lang, ````lang, ~~~lang, as well as single-line ```lang code ```.
    private static func parseOpeningFence(_ trimmed: String) -> FenceInfo? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let fencePrefix = trimmed.prefix { $0 == first }
        guard fencePrefix.count >= 3 else { return nil }
        let rest = String(trimmed.dropFirst(fencePrefix.count))
        let closingFence = String(repeating: first, count: fencePrefix.count)

        // Single-line fenced block e.g. ```swift print("hi") ```
        if rest.hasSuffix(closingFence), rest.count > closingFence.count {
            let inner = String(rest.dropLast(closingFence.count)).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty {
                let parts = inner.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                if parts.count == 2 && parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" || $0 == "-" || $0 == "_" }) {
                    return FenceInfo(char: first, count: fencePrefix.count, language: String(parts[0]), singleLineCode: String(parts[1]))
                }
                return FenceInfo(char: first, count: fencePrefix.count, language: "", singleLineCode: inner)
            }
        }

        // Standard multi-line opening fence: info string cannot contain backticks for backtick fences
        if first == "`" && rest.contains("`") {
            return nil
        }
        let info = rest.trimmingCharacters(in: .whitespaces)
        let lang = info.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return FenceInfo(char: first, count: fencePrefix.count, language: lang, singleLineCode: nil)
    }

    private static func isClosingFence(_ trimmed: String, char: Character, minCount: Int) -> Bool {
        guard trimmed.first == char else { return false }
        let run = trimmed.prefix { $0 == char }
        guard run.count >= minCount else { return false }
        return trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func parseBlocks(_ input: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
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

        func consumeCodeBlock(fence: FenceInfo, startLine: Int) -> Int {
            if let single = fence.singleLineCode {
                result.append(.code(id: nextId, language: fence.language, code: single))
                nextId += 1
                return startLine + 1
            }
            let closingToken = String(repeating: fence.char, count: fence.count)
            var codeLines: [String] = []
            var cursor = startLine + 1
            while cursor < lines.count {
                let rawLine = lines[cursor]
                let candidate = rawLine.trimmingCharacters(in: .whitespaces)
                if isClosingFence(candidate, char: fence.char, minCount: fence.count) {
                    cursor += 1
                    break
                }
                if candidate.hasSuffix(closingToken), candidate.count > closingToken.count {
                    let trimmedRight = rawLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                    if trimmedRight.hasSuffix(closingToken) {
                        codeLines.append(String(trimmedRight.dropLast(closingToken.count)))
                        cursor += 1
                        break
                    }
                }
                codeLines.append(rawLine)
                cursor += 1
            }
            result.append(.code(id: nextId, language: fence.language, code: codeLines.joined(separator: "\n")))
            nextId += 1
            return cursor
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Standard fenced code block (``` or ~~~, 3+ chars, including single-line fences)
            if let fence = parseOpeningFence(trimmed) {
                flushParagraph()
                idx = consumeCodeBlock(fence: fence, startLine: idx)
                continue
            }

            // 2. Mid-line opening fence without preceding newline (e.g. "示例代码：```python")
            if let fenceRange = trimmed.range(of: "```"),
               fenceRange.lowerBound > trimmed.startIndex {
                let before = String(trimmed[..<fenceRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after = String(trimmed[fenceRange.lowerBound...])
                if let fence = parseOpeningFence(after) {
                    if !before.isEmpty && before != "-" && before != "*" && before != "•" && before != ">" {
                        paraBuf.append(before)
                    }
                    flushParagraph()
                    idx = consumeCodeBlock(fence: fence, startLine: idx)
                    continue
                }
            }

            // 3. Display math block $$...$$ or \[...\]
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

            // 4. Markdown table
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

// MARK: - Lightweight Cached Syntax Highlighter for Code Bubbles

private enum CodeSyntaxHighlighter {
    private static let cache: NSCache<NSString, CachedCodeHighlight> = {
        let c = NSCache<NSString, CachedCodeHighlight>()
        c.countLimit = 128
        return c
    }()

    private static let tokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(//[^\\n]*|#[^\\n]*|/\\*[\\s\\S]*?\\*/)|(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`(?:\\\\.|[^`\\\\])*`)|\\b(func|var|let|const|class|struct|enum|protocol|extension|import|return|if|else|for|while|switch|case|default|break|continue|guard|defer|async|await|try|catch|throw|throws|public|private|internal|fileprivate|final|static|override|init|self|super|true|false|nil|null|None|True|False|def|from|as|with|yield|lambda|in|not|and|or|function|export|interface|type|new|this|typeof|void|int|float|double|bool|string|char|auto|package|go|chan|select|match|fn|pub|mut|impl|use|mod|SELECT|FROM|WHERE|JOIN|INSERT|UPDATE|DELETE|CREATE|TABLE)\\b|\\b(\\d+(?:\\.\\d+)?)\\b",
        options: []
    )

    static func highlight(_ code: String, language: String, dark: Bool) -> AttributedString {
        guard code.count <= 16_000, let regex = tokenRegex else {
            return AttributedString(code)
        }
        let cacheKey = "\(dark ? "D" : "L"):\(language):\(code)" as NSString
        if let hit = cache.object(forKey: cacheKey) {
            return hit.value
        }

        let nsCode = code as NSString
        var attr = AttributedString(code)
        let commentColor = dark ? Color(red: 128/255, green: 140/255, blue: 154/255) : Color(red: 106/255, green: 115/255, blue: 125/255)
        let stringColor = dark ? Color(red: 152/255, green: 195/255, blue: 121/255) : Color(red: 10/255, green: 122/255, blue: 58/255)
        let keywordColor = dark ? Color(red: 198/255, green: 120/255, blue: 221/255) : Color(red: 147/255, green: 51/255, blue: 234/255)
        let numberColor = dark ? Color(red: 209/255, green: 154/255, blue: 102/255) : Color(red: 194/255, green: 65/255, blue: 12/255)

        let fullRange = NSRange(location: 0, length: nsCode.length)
        let matches = regex.matches(in: code, range: fullRange)
        for match in matches {
            let color: Color
            if match.range(at: 1).location != NSNotFound {
                color = commentColor
            } else if match.range(at: 2).location != NSNotFound {
                color = stringColor
            } else if match.range(at: 3).location != NSNotFound {
                color = keywordColor
            } else if match.range(at: 4).location != NSNotFound {
                color = numberColor
            } else {
                continue
            }
            if let swiftRange = Range(match.range, in: code),
               let lower = AttributedString.Index(swiftRange.lowerBound, within: attr),
               let upper = AttributedString.Index(swiftRange.upperBound, within: attr) {
                attr[lower..<upper].foregroundColor = color
            }
        }
        cache.setObject(CachedCodeHighlight(attr), forKey: cacheKey)
        return attr
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
                    CodeBlockView(language: language, code: code, isStreaming: isStreaming, onCopy: onCopyCode)

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
                    .background(Color.nuwaCodeBlockFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75)
                    )

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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let fontSize: Double

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                        Text(MarkdownParseCache.inlineAttributed(h))
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color.primary.opacity(0.05))

                ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<max(headers.count, row.count), id: \.self) { cIdx in
                            let val = cIdx < row.count ? row[cIdx] : ""
                            Text(MarkdownParseCache.inlineAttributed(val))
                                .font(.system(size: fontSize))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
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
    let isStreaming: Bool
    let onCopy: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        let highlighted = isStreaming
            ? AttributedString(code)
            : CodeSyntaxHighlighter.highlight(code, language: language, dark: colorScheme == .dark)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
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
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(copied ? .green : Color.nuwaLabelSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NuwaTactileButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.nuwaCodeBannerFill)

            Divider()
                .opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nuwaCodeBlockFill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.nuwaControlBorder, lineWidth: 0.9)
        )
        .padding(.vertical, 2)
    }
}

// MARK: - Lightweight In-Scroll Message Controls (Zero Glass Shader Overhead)

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
