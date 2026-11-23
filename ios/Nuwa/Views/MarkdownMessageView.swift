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
        c.countLimit = ChatMemoryBudget.isConstrainedDevice ? 100 : 250
        c.totalCostLimit = (ChatMemoryBudget.isConstrainedDevice ? 2 : 8) * 1024 * 1024
        return c
    }()

    static let inlineCache: NSCache<NSString, CachedInlineMarkdown> = {
        let cache = NSCache<NSString, CachedInlineMarkdown>()
        cache.countLimit = ChatMemoryBudget.isConstrainedDevice ? 192 : 512
        cache.totalCostLimit = (ChatMemoryBudget.isConstrainedDevice ? 512 : 2048) * 1024
        return cache
    }()

    static func parse(_ rawInput: String, isStreaming: Bool, darkMode: Bool) -> [MarkdownBlock] {
        if isStreaming { return parseBlocks(cleanCitationTags(rawInput), cacheInline: false, darkMode: darkMode) }
        let key = "\(darkMode ? "D" : "L"):\(rawInput)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit.blocks
        }
        let cleaned = cleanCitationTags(rawInput)
        let parsed = parseBlocks(cleaned, cacheInline: true, darkMode: darkMode)
        cache.setObject(CachedMarkdownBlocks(parsed), forKey: key, cost: key.length * 4)
        return parsed
    }

    static func inlineAttributed(_ raw: String, cacheable: Bool = true, darkMode: Bool = false) -> AttributedString {
        let key = "\(darkMode ? "D" : "L"):\(raw)" as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }

        let styled: AttributedString
        if raw.contains("\\(") || raw.contains("$") {
            styled = parseInlineWithLatex(raw, darkMode: darkMode)
        } else {
            let parsed = (try? AttributedString(markdown: raw, options: inlineOptions)) ?? AttributedString(raw)
            styled = styleInlineCodeRuns(parsed)
        }

        if cacheable {
            inlineCache.setObject(CachedInlineMarkdown(styled), forKey: key, cost: key.length * 4)
        }
        return styled
    }

    /// Splits inline `$...$` and `\(...\)` math spans out of Markdown text (never touching backtick code spans
    /// or plain currency like `$100`), rendering math via `LatexParser.inlineAttributed` and normal text via Markdown.
    private static func parseInlineWithLatex(_ raw: String, darkMode: Bool) -> AttributedString {
        let chars = Array(raw)
        var result = AttributedString()
        var mdBuf = ""
        var i = 0
        var inCodeTicks = 0

        func flushMarkdown() {
            guard !mdBuf.isEmpty else { return }
            let parsed = (try? AttributedString(markdown: mdBuf, options: inlineOptions)) ?? AttributedString(mdBuf)
            result.append(styleInlineCodeRuns(parsed))
            mdBuf.removeAll(keepingCapacity: true)
        }

        while i < chars.count {
            let c = chars[i]

            // Preserve inline code spans verbatim so `$var` or `\(` inside backticks is untouched
            if c == "`" {
                var ticks = 0
                while i + ticks < chars.count && chars[i + ticks] == "`" { ticks += 1 }
                if inCodeTicks == 0 {
                    inCodeTicks = ticks
                } else if inCodeTicks == ticks {
                    inCodeTicks = 0
                }
                for _ in 0..<ticks { mdBuf.append("`") }
                i += ticks
                continue
            }

            if inCodeTicks > 0 {
                mdBuf.append(c)
                i += 1
                continue
            }

            // Inline \( ... \)
            if c == "\\" && i + 1 < chars.count && chars[i + 1] == "(" {
                if let closeIdx = findClosingParenMath(in: chars, from: i + 2) {
                    let formula = String(chars[(i + 2)..<closeIdx])
                    flushMarkdown()
                    result.append(LatexParser.inlineAttributed(from: formula, darkMode: darkMode))
                    i = closeIdx + 2
                    continue
                }
            }

            // Inline $ ... $ (skip escaped \$ and currency like "$100" without closing "$")
            if c == "$" && (i == 0 || chars[i - 1] != "\\") && !(i + 1 < chars.count && chars[i + 1] == "$") {
                if let closeIdx = findClosingDollarMath(in: chars, from: i + 1) {
                    let formula = String(chars[(i + 1)..<closeIdx])
                    flushMarkdown()
                    result.append(LatexParser.inlineAttributed(from: formula, darkMode: darkMode))
                    i = closeIdx + 1
                    continue
                }
            }

            mdBuf.append(c)
            i += 1
        }

        flushMarkdown()
        return result
    }

    private static func findClosingParenMath(in chars: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "\\" && chars[j + 1] == ")" {
                return j > start ? j : nil
            }
            j += 1
        }
        return nil
    }

    private static func findClosingDollarMath(in chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, chars[start] != " " && chars[start] != "\t" && chars[start] != "\n" else {
            return nil
        }
        var j = start
        while j < chars.count {
            if chars[j] == "\n" { return nil }
            if chars[j] == "\\" {
                j += 2
                continue
            }
            if chars[j] == "$" {
                if j > start && chars[j - 1] != " " && chars[j - 1] != "\t" {
                    // Reject pure digit currency pairs like "$10 and $20"
                    let inner = String(chars[start..<j])
                    let looksLikeCurrency = inner.first?.isNumber == true && inner.contains(" ") && !inner.contains("\\") && !inner.contains("^") && !inner.contains("_") && !inner.contains("=")
                    return looksLikeCurrency ? nil : j
                }
                return nil
            }
            j += 1
        }
        return nil
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

    private static let blockLatexEnvs = [
        "array", "aligned", "align", "align*", "gathered", "gather", "gather*",
        "cases", "dcases", "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "tabular"
    ]

    private static func matchOpeningBareEnv(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("\\begin{") else { return nil }
        let after = trimmed.dropFirst(7)
        guard let closeBrace = after.firstIndex(of: "}") else { return nil }
        let env = String(after[..<closeBrace])
        return blockLatexEnvs.contains(env) ? env : nil
    }

    private static func parseBlocks(_ input: String, cacheInline: Bool, darkMode: Bool) -> [MarkdownBlock] {
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
                result.append(.paragraph(id: nextId, attributed: inlineAttributed(joined, cacheable: cacheInline, darkMode: darkMode)))
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

            // 3. LaTeX / KaTeX block: $$...$$, \[...\], multi-line or standalone \(...\), or bare \begin{array}...\end{array}
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") || trimmed.hasPrefix("\\(") {
                let opener = String(trimmed.prefix(2))
                let closer: String = opener == "$$" ? "$$" : (opener == "\\[" ? "\\]" : "\\)")
                let afterOpen = String(trimmed.dropFirst(2))

                // Case A: Single-line standalone math block (e.g. $$...$$, \[...\], or standalone \(...\))
                if afterOpen.hasSuffix(closer) && afterOpen.count >= closer.count {
                    let inner = String(afterOpen.dropLast(closer.count)).trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty {
                        flushParagraph()
                        result.append(.math(id: nextId, formula: inner))
                        nextId += 1
                        idx += 1
                        continue
                    }
                }

                // Case B: Multi-line math block (e.g. \(\begin{array}{c} ... \end{array}\), $$ ... $$, \[ ... \])
                // Only treat `\(` as a block if it does NOT close on the same line (otherwise paragraph handles inline math + prose).
                let closesMidLine = afterOpen.contains(closer)
                if !closesMidLine {
                    flushParagraph()
                    var mathLines: [String] = []
                    if !afterOpen.trimmingCharacters(in: .whitespaces).isEmpty {
                        mathLines.append(afterOpen)
                    }
                    idx += 1
                    while idx < lines.count {
                        let curLine = lines[idx]
                        let curTrimmed = curLine.trimmingCharacters(in: .whitespaces)
                        if curTrimmed == closer {
                            idx += 1
                            break
                        }
                        if curTrimmed.hasSuffix(closer) {
                            let withoutCloser = String(curTrimmed.dropLast(closer.count))
                            if !withoutCloser.isEmpty {
                                mathLines.append(withoutCloser)
                            }
                            idx += 1
                            break
                        }
                        mathLines.append(curLine)
                        idx += 1
                    }
                    let formula = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !formula.isEmpty {
                        result.append(.math(id: nextId, formula: formula))
                        nextId += 1
                    }
                    continue
                }
            }

            // 3b. Bare LaTeX environment without outer delimiters (e.g. \begin{array}{c} ... \end{array})
            if let envName = matchOpeningBareEnv(trimmed) {
                flushParagraph()
                let endToken = "\\end{\(envName)}"
                var mathLines: [String] = [line]
                idx += 1
                if !trimmed.contains(endToken) {
                    while idx < lines.count {
                        let curLine = lines[idx]
                        mathLines.append(curLine)
                        idx += 1
                        if curLine.contains(endToken) {
                            break
                        }
                    }
                }
                result.append(.math(id: nextId, formula: mathLines.joined(separator: "\n")))
                nextId += 1
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
                    result.append(.heading(id: nextId, level: level, attributed: inlineAttributed(content, cacheable: cacheInline, darkMode: darkMode)))
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
                result.append(.blockquote(id: nextId, attributed: inlineAttributed(quoteLines.joined(separator: "\n"), cacheable: cacheInline, darkMode: darkMode)))
                nextId += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                let content = String(trimmed.dropFirst(2))
                result.append(.listItem(id: nextId, marker: "•", attributed: inlineAttributed(content, cacheable: cacheInline, darkMode: darkMode)))
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
                result.append(.listItem(id: nextId, marker: marker, attributed: inlineAttributed(content, cacheable: cacheInline, darkMode: darkMode)))
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
        c.countLimit = ChatMemoryBudget.isConstrainedDevice ? 32 : 128
        c.totalCostLimit = (ChatMemoryBudget.isConstrainedDevice ? 1 : 4) * 1024 * 1024
        return c
    }()

    static func purgeCache() {
        cache.removeAllObjects()
    }

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
        cache.setObject(CachedCodeHighlight(attr), forKey: cacheKey, cost: cacheKey.length * 8 + matches.count * 64)
        return attr
    }
}

struct MarkdownMessageView: View, Equatable {
    static func purgeRenderCaches() {
        MarkdownParseCache.cache.removeAllObjects()
        MarkdownParseCache.inlineCache.removeAllObjects()
        CodeSyntaxHighlighter.purgeCache()
    }

    let text: String
    let citations: [TextCitation]
    let fontSize: Double
    let isStreaming: Bool
    let onCopyCode: (String) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nuwaFontScale) private var fontScale

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
        let darkMode = colorScheme == .dark
        let blocks = MarkdownParseCache.parse(text, isStreaming: isStreaming, darkMode: darkMode)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let attributed):
                    let size: CGFloat = level == 1 ? fontSize * 1.5 : (level == 2 ? fontSize * 1.375 : (level == 3 ? fontSize * 1.25 : fontSize))
                    Text(attributed)
                        .font(.system(size: size, weight: level <= 3 ? .bold : .semibold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .padding(.top, 4)
                        .modifier(ConditionalTextSelection(enabled: !isStreaming))

                case .paragraph(_, let attributed):
                    Text(attributed)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .lineSpacing(max(4, fontSize * 0.375))
                        .modifier(ConditionalTextSelection(enabled: !isStreaming))
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
                            .lineSpacing(max(4, fontSize * 0.375))
                            .modifier(ConditionalTextSelection(enabled: !isStreaming))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .blockquote(_, let attributed):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.nuwaBrand.opacity(0.6))
                            .frame(width: 3)
                        Text(attributed)
                            .font(.system(size: fontSize * 0.9375))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .lineSpacing(max(3, fontSize * 0.25))
                            .modifier(ConditionalTextSelection(enabled: !isStreaming))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)

                case .code(_, let language, let code):
                    CodeBlockView(language: language, code: code, fontSize: fontSize * 0.8125, isStreaming: isStreaming, onCopy: onCopyCode)

                case .math(_, let formula):
                    LatexRendererView(formula: formula, baseFontSize: fontSize, isStreaming: isStreaming)

                case .table(_, let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows, fontSize: fontSize * 0.9375, darkMode: darkMode)

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
                                        .font(NuwaFont.sized(10, weight: .bold, scale: fontScale))
                                        .foregroundStyle(.white)
                                        .frame(width: max(16, 16 * fontScale), height: max(16, 16 * fontScale))
                                        .background(Color.nuwaBrand, in: Circle())
                                    Text(cite.title ?? URL(string: cite.url)?.host ?? "来源")
                                        .font(NuwaFont.sized(12, scale: fontScale))
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

private struct ConditionalTextSelection: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let fontSize: Double
    let darkMode: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if #available(iOS 16.0, *) {
                    nativeGrid
                } else {
                    legacyGrid
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
            )
        }
    }

    @available(iOS 16.0, *)
    private var nativeGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    tableCell(header, isHeader: true)
                }
            }
            .background(Color.primary.opacity(0.05))

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(0..<max(headers.count, row.count), id: \.self) { column in
                        tableCell(column < row.count ? row[column] : "")
                    }
                }
                .background(rowBackground(index))
            }
        }
    }

    private var legacyGrid: some View {
        let columns = rows.reduce(headers.count) { max($0, $1.count) }
        return NuwaLegacyGrid(verticalSpacing: 0) {
            legacyRow(headers, columns: columns, isHeader: true)
                .background(Color.primary.opacity(0.05))
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                legacyRow(row, columns: columns)
                    .background(rowBackground(index))
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private func legacyRow(_ values: [String], columns: Int, isHeader: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columns, id: \.self) { column in
                NuwaLegacyGridCell(column: column) {
                    tableCell(column < values.count ? values[column] : "", isHeader: isHeader)
                }
            }
        }
    }

    private func tableCell(_ value: String, isHeader: Bool = false) -> some View {
        Text(MarkdownParseCache.inlineAttributed(value, darkMode: darkMode))
            .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(Color.nuwaLabelPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, isHeader ? 8 : 7)
            .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
    }

    private func rowBackground(_ index: Int) -> Color {
        index % 2 == 1 ? Color.primary.opacity(0.02) : .clear
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    let fontSize: Double
    let isStreaming: Bool
    let onCopy: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nuwaFontScale) private var fontScale
    @State private var copied = false

    var body: some View {
        let highlighted = isStreaming
            ? AttributedString(code)
            : CodeSyntaxHighlighter.highlight(code, language: language, dark: colorScheme == .dark)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(NuwaFont.sized(12.5, weight: .medium, design: .monospaced, scale: fontScale))
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
                            .font(NuwaFont.sized(11.5, weight: .medium, scale: fontScale))
                        Text(copied ? "已复制" : "复制")
                            .font(NuwaFont.sized(12.5, weight: .medium, scale: fontScale))
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
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                    .lineSpacing(3.5)
                    .modifier(ConditionalTextSelection(enabled: !isStreaming))
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

    @Environment(\.nuwaFontScale) private var fontScale

    var body: some View {
        if versionInfo.count > 1 {
            HStack(spacing: 2) {
                Button {
                    if versionInfo.index > 0 {
                        onSelect(versionInfo.ids[versionInfo.index - 1])
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(NuwaFont.sized(11, weight: .semibold, scale: fontScale))
                        .foregroundStyle(versionInfo.index > 0 ? Color.nuwaLabelSecondary : Color.nuwaLabelTertiary.opacity(0.4))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(versionInfo.index == 0)

                Text("\(versionInfo.index + 1)/\(versionInfo.count)")
                    .font(NuwaFont.badge(fontScale).monospacedDigit())
                    .foregroundStyle(Color.nuwaLabelSecondary)

                Button {
                    if versionInfo.index + 1 < versionInfo.count {
                        onSelect(versionInfo.ids[versionInfo.index + 1])
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(NuwaFont.sized(11, weight: .semibold, scale: fontScale))
                        .foregroundStyle(versionInfo.index + 1 < versionInfo.count ? Color.nuwaLabelSecondary : Color.nuwaLabelTertiary.opacity(0.4))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(versionInfo.index + 1 >= versionInfo.count)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 28)
            .nuwaPillSurface()
        }
    }
}

/// Full-screen image preview overlay supporting tap-to-zoom, pinch-to-zoom,
/// smooth scrolling for super-tall / super-wide images, and reliable dismissal.
struct ImageLightboxOverlay: View {
    let image: UIImage
    let onDismiss: () -> Void

    @State private var isZoomed = false
    @State private var pinchScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0

    private var imageAspect: CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 1.0 }
        return size.height / size.width
    }

    private var isTallImage: Bool { imageAspect > 1.6 }
    private var isWideImage: Bool { imageAspect < 1.0 / 1.6 }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            if isZoomed || baseScale > 1.05 {
                isZoomed = false
                baseScale = 1.0
                pinchScale = 1.0
            } else {
                isZoomed = true
                baseScale = 1.0
                pinchScale = 1.0
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let viewportW = max(1, proxy.size.width)
            let viewportH = max(1, proxy.size.height)
            let effectiveScale = max(1.0, min(4.0, baseScale * pinchScale))
            let showingZoomed = isZoomed || effectiveScale > 1.05

            ZStack {
                Color.black.opacity(0.94)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                if showingZoomed {
                    ScrollView(isTallImage && effectiveScale <= 1.05 ? .vertical : [.horizontal, .vertical], showsIndicators: true) {
                        let targetW: CGFloat = {
                            if isTallImage {
                                return viewportW * effectiveScale
                            } else if isWideImage {
                                return max(viewportW * 1.8, (viewportH - 120) / max(0.05, imageAspect)) * effectiveScale
                            } else {
                                return viewportW * max(1.8, effectiveScale)
                            }
                        }()
                        let targetH = max(1, targetW * imageAspect)
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: targetW, height: targetH)
                            .padding(.top, 64)
                            .padding(.bottom, 84)
                            .frame(minWidth: viewportW, minHeight: viewportH, alignment: isTallImage ? .top : .center)
                            .contentShape(Rectangle())
                            .onTapGesture { toggleZoom() }
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                pinchScale = value
                            }
                            .onEnded { value in
                                let finalScale = baseScale * value
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                    pinchScale = 1.0
                                    if finalScale < 0.85 {
                                        isZoomed = false
                                        baseScale = 1.0
                                    } else {
                                        baseScale = max(1.0, min(4.0, finalScale))
                                    }
                                }
                            }
                    )
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(effectiveScale)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleZoom() }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 64)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    pinchScale = max(1.0, value)
                                }
                                .onEnded { value in
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                        pinchScale = 1.0
                                        if value > 1.15 {
                                            isZoomed = true
                                            baseScale = min(4.0, value)
                                        }
                                    }
                                }
                        )
                }

                VStack {
                    HStack {
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .nuwaGlass(in: Circle(), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 14)
                    .padding(.trailing, 18)

                    Spacer()

                    HStack(spacing: 12) {
                        Button(action: toggleZoom) {
                            Text(showingZoomed ? "适应屏幕" : "放大查看")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .nuwaGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)

                        Button(action: onDismiss) {
                            Text("关闭")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .nuwaGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }
}
