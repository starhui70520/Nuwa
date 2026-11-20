import SwiftUI
import UIKit

// MARK: - Native SwiftUI LaTeX / KaTeX Roleplay Card & Math Renderer (120Hz, Zero WKWebView Lag)

private struct LatexStyle {
    var scale: CGFloat = 1.0
    var color: LatexColor? = nil
    var bold: Bool = false
    var italic: Bool = false
    var monospaced: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var hasExplicitBackground: Bool = false
}

private struct LatexColor: Equatable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    var luminance: Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    func resolved(darkMode: Bool, hasExplicitBackground: Bool) -> Color {
        if darkMode && !hasExplicitBackground && a > 0.5 && luminance < 0.28 {
            // Adapt very dark explicit text colors (#111111, #333333, black) so they stay legible on dark chat surfaces
            let lifted = min(0.95, max(0.76, 1.0 - luminance * 0.85))
            return Color(red: lifted, green: lifted, blue: min(0.97, lifted + 0.015), opacity: a)
        }
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    var exactColor: Color {
        Color(red: r, green: g, blue: b, opacity: a)
    }
}

private enum LatexColumnAlign {
    case leading, center, trailing

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private enum LatexMatrixBracket {
    case none, paren, bracket, brace, pipe, doublePipe, leftBraceOnly
}

private indirect enum LatexNode {
    case text(String)
    case space(CGFloat)
    case styled(LatexStyleDelta, [LatexNode])
    case colorBox(bg: LatexColor?, border: LatexColor?, isFrameBox: Bool, body: [LatexNode])
    case rule(width: CGFloat, height: CGFloat)
    case fraction(num: [LatexNode], den: [LatexNode])
    case sqrt(index: [LatexNode]?, body: [LatexNode])
    case script(base: [LatexNode], sup: [LatexNode]?, sub: [LatexNode]?)
    case array(columns: [LatexColumnAlign], rows: [LatexArrayRow], bracket: LatexMatrixBracket)
    case lineBreak(extraSpacing: CGFloat)
}

private struct LatexStyleDelta {
    var scale: CGFloat? = nil
    var color: LatexColor? = nil
    var bold: Bool? = nil
    var italic: Bool? = nil
    var monospaced: Bool? = nil
    var underline: Bool? = nil
    var strikethrough: Bool? = nil
}

private enum LatexArrayRow {
    case cells([[LatexNode]], extraSpacing: CGFloat)
    case hline(dashed: Bool)
}

private final class CachedLatexAST: NSObject {
    let nodes: [LatexNode]
    init(_ nodes: [LatexNode]) { self.nodes = nodes }
}

// MARK: - Recursive-Descent LaTeX / KaTeX Parser

enum LatexParser {
    private static let cache: NSCache<NSString, CachedLatexAST> = {
        let c = NSCache<NSString, CachedLatexAST>()
        c.countLimit = 256
        return c
    }()

    fileprivate static func parse(_ source: String, cacheable: Bool = true) -> [LatexNode] {
        let cleaned = stripOuterDelimiters(source)
        let key = cleaned as NSString
        if cacheable, let hit = cache.object(forKey: key) {
            return hit.nodes
        }
        var state = ParserState(cleaned)
        let nodes = state.parseSequence(stopAt: nil, depth: 0)
        if cacheable {
            cache.setObject(CachedLatexAST(nodes), forKey: key)
        }
        return nodes
    }

    private static func stripOuterDelimiters(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$$") && s.hasSuffix("$$") && s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("\\[") && s.hasSuffix("\\]") && s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("\\(") && s.hasSuffix("\\)") && s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("$") && s.hasSuffix("$") && s.count >= 2 {
            s = String(s.dropFirst(1).dropLast(1))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts inline `$...$` / `\(...\)` expressions into styled AttributedString segments
    /// (colors, bubbles, bold/italic, Greek symbols, superscripts/subscripts) inside normal paragraphs.
    static func inlineAttributed(from formula: String, darkMode: Bool) -> AttributedString {
        let nodes = parse(formula, cacheable: false)
        var output = AttributedString()
        appendInline(nodes: nodes, style: LatexStyle(), darkMode: darkMode, into: &output)
        return output
    }

    private static func appendInline(
        nodes: [LatexNode],
        style: LatexStyle,
        darkMode: Bool,
        into output: inout AttributedString
    ) {
        for node in nodes {
            switch node {
            case .text(let str):
                var seg = AttributedString(str)
                applyInlineStyle(style, darkMode: darkMode, to: &seg)
                output.append(seg)
            case .space(let pt):
                let count = max(1, Int((pt / 5.0).rounded()))
                var seg = AttributedString(String(repeating: " ", count: min(count, 6)))
                applyInlineStyle(style, darkMode: darkMode, to: &seg)
                output.append(seg)
            case .styled(let delta, let children):
                let next = mergeStyle(style, delta: delta)
                appendInline(nodes: children, style: next, darkMode: darkMode, into: &output)
            case .colorBox(let bg, _, _, let body):
                var innerStyle = style
                if bg != nil { innerStyle.hasExplicitBackground = true }
                var boxAttr = AttributedString()
                appendInline(nodes: body, style: innerStyle, darkMode: darkMode, into: &boxAttr)
                if let bg {
                    var pad = AttributedString("\u{2009}")
                    pad.backgroundColor = bg.exactColor
                    boxAttr.backgroundColor = bg.exactColor
                    output.append(pad)
                    output.append(boxAttr)
                    output.append(pad)
                } else {
                    output.append(boxAttr)
                }
            case .rule(let width, _):
                let dashes = max(3, min(20, Int((width / 8.0).rounded())))
                var seg = AttributedString(String(repeating: "─", count: dashes))
                applyInlineStyle(style, darkMode: darkMode, to: &seg)
                output.append(seg)
            case .fraction(let num, let den):
                var nAttr = AttributedString()
                var dAttr = AttributedString()
                appendInline(nodes: num, style: style, darkMode: darkMode, into: &nAttr)
                appendInline(nodes: den, style: style, darkMode: darkMode, into: &dAttr)
                output.append(nAttr)
                output.append(AttributedString("/"))
                output.append(dAttr)
            case .sqrt(let idx, let body):
                if let idx {
                    var idxAttr = AttributedString()
                    appendInline(nodes: idx, style: style, darkMode: darkMode, into: &idxAttr)
                    idxAttr.baselineOffset = 4
                    output.append(idxAttr)
                }
                output.append(AttributedString("√("))
                appendInline(nodes: body, style: style, darkMode: darkMode, into: &output)
                output.append(AttributedString(")"))
            case .script(let base, let sup, let sub):
                appendInline(nodes: base, style: style, darkMode: darkMode, into: &output)
                if let sup {
                    var supAttr = AttributedString()
                    appendInline(nodes: sup, style: style, darkMode: darkMode, into: &supAttr)
                    supAttr.baselineOffset = 4
                    output.append(supAttr)
                }
                if let sub {
                    var subAttr = AttributedString()
                    appendInline(nodes: sub, style: style, darkMode: darkMode, into: &subAttr)
                    subAttr.baselineOffset = -3
                    output.append(subAttr)
                }
            case .array(_, let rows, _):
                for (i, row) in rows.enumerated() {
                    if case .cells(let cols, _) = row {
                        for (cIdx, cell) in cols.enumerated() {
                            if cIdx > 0 { output.append(AttributedString("  ")) }
                            appendInline(nodes: cell, style: style, darkMode: darkMode, into: &output)
                        }
                        if i + 1 < rows.count { output.append(AttributedString("\n")) }
                    }
                }
            case .lineBreak:
                output.append(AttributedString("\n"))
            }
        }
    }

    private static func applyInlineStyle(_ style: LatexStyle, darkMode: Bool, to seg: inout AttributedString) {
        if let color = style.color {
            seg.foregroundColor = color.resolved(darkMode: darkMode, hasExplicitBackground: style.hasExplicitBackground)
        }
        var intent = InlinePresentationIntent()
        if style.bold { intent.insert(.stronglyEmphasized) }
        if style.italic { intent.insert(.emphasized) }
        if style.monospaced { intent.insert(.code) }
        if !intent.isEmpty { seg.inlinePresentationIntent = intent }
        if style.underline { seg.underlineStyle = .single }
        if style.strikethrough { seg.strikethroughStyle = .single }
    }

    fileprivate static func mergeStyle(_ base: LatexStyle, delta: LatexStyleDelta) -> LatexStyle {
        var next = base
        if let s = delta.scale { next.scale = s }
        if let c = delta.color { next.color = c }
        if let b = delta.bold { next.bold = b }
        if let i = delta.italic { next.italic = i }
        if let m = delta.monospaced { next.monospaced = m }
        if let u = delta.underline { next.underline = u }
        if let st = delta.strikethrough { next.strikethrough = st }
        return next
    }
}

private struct ParserState {
    let chars: [Character]
    var index: Int = 0
    private static let maxDepth = 24

    init(_ input: String) {
        self.chars = Array(input)
    }

    var isAtEnd: Bool { index >= chars.count }
    var current: Character? { index < chars.count ? chars[index] : nil }

    mutating func skipSpaces() {
        while index < chars.count, chars[index] == " " || chars[index] == "\t" || chars[index] == "\n" || chars[index] == "\r" {
            index += 1
        }
    }

    mutating func skipHorizontalSpaces() {
        while index < chars.count, chars[index] == " " || chars[index] == "\t" {
            index += 1
        }
    }

    mutating func peekMatch(_ literal: String) -> Bool {
        let target = Array(literal)
        guard index + target.count <= chars.count else { return false }
        for i in 0..<target.count {
            if chars[index + i] != target[i] { return false }
        }
        return true
    }

    mutating func consumeIf(_ ch: Character) -> Bool {
        guard current == ch else { return false }
        index += 1
        return true
    }

    mutating func parseBracedRaw() -> String? {
        skipSpaces()
        guard consumeIf("{") else { return nil }
        var depth = 1
        var buf: [Character] = []
        while index < chars.count && depth > 0 {
            let c = chars[index]
            index += 1
            if c == "\\" && index < chars.count {
                buf.append(c)
                buf.append(chars[index])
                index += 1
                continue
            }
            if c == "{" { depth += 1; buf.append(c) }
            else if c == "}" {
                depth -= 1
                if depth > 0 { buf.append(c) }
            } else {
                buf.append(c)
            }
        }
        return String(buf)
    }

    mutating func parseBracketRaw() -> String? {
        let saved = index
        skipHorizontalSpaces()
        guard consumeIf("[") else { index = saved; return nil }
        var buf: [Character] = []
        while index < chars.count {
            let c = chars[index]
            index += 1
            if c == "]" { return String(buf) }
            buf.append(c)
        }
        index = saved
        return nil
    }

    mutating func parseGroupOrSingle(depth: Int) -> [LatexNode] {
        guard depth < Self.maxDepth else { return [] }
        skipSpaces()
        if consumeIf("{") {
            return parseSequence(stopAt: "}", depth: depth + 1)
        }
        if let atom = parseSingleAtom(depth: depth + 1) {
            return [atom]
        }
        return []
    }

    mutating func parseSequence(stopAt: Character?, depth: Int, stopAtEndEnv: String? = nil) -> [LatexNode] {
        guard depth < Self.maxDepth else { return [] }
        var nodes: [LatexNode] = []
        var textBuf = ""

        func flushText() {
            if !textBuf.isEmpty {
                nodes.append(.text(textBuf))
                textBuf.removeAll(keepingCapacity: true)
            }
        }

        while index < chars.count {
            if let stopAt, chars[index] == stopAt {
                index += 1
                break
            }
            if let env = stopAtEndEnv, peekMatch("\\end{\(env)}") {
                break
            }

            let ch = chars[index]

            // Handle declaration switches that apply to the rest of the current group!
            if ch == "\\" {
                let saved = index
                let cmd = readCommandName()
                if let delta = declarationStyleDelta(for: cmd) {
                    flushText()
                    var finalDelta = delta
                    if cmd == "color" {
                        if let rawColor = parseBracedRaw() {
                            finalDelta.color = parseLatexColor(rawColor)
                        }
                    }
                    // If the user wrote `\Large{text}` directly, apply to that brace group;
                    // otherwise apply to the rest of the enclosing group!
                    skipHorizontalSpaces()
                    if current == "{" {
                        let group = parseGroupOrSingle(depth: depth + 1)
                        nodes.append(.styled(finalDelta, group))
                    } else {
                        let rest = parseSequence(stopAt: stopAt, depth: depth + 1, stopAtEndEnv: stopAtEndEnv)
                        nodes.append(.styled(finalDelta, rest))
                        return nodes
                    }
                    continue
                } else {
                    index = saved
                }
            }

            if ch == "^" || ch == "_" {
                flushText()
                var base: [LatexNode] = []
                if let last = nodes.popLast() {
                    if case .text(let str) = last, str.count > 1 {
                        let prefix = String(str.dropLast())
                        let lastChar = String(str.last!)
                        nodes.append(.text(prefix))
                        base = [.text(lastChar)]
                    } else {
                        base = [last]
                    }
                }
                var sup: [LatexNode]? = nil
                var sub: [LatexNode]? = nil
                while index < chars.count && (chars[index] == "^" || chars[index] == "_") {
                    let isSup = chars[index] == "^"
                    index += 1
                    let arg = parseGroupOrSingle(depth: depth + 1)
                    if isSup { sup = arg } else { sub = arg }
                }
                nodes.append(.script(base: base, sup: sup, sub: sub))
                continue
            }

            if ch == "{" {
                flushText()
                index += 1
                let inner = parseSequence(stopAt: "}", depth: depth + 1)
                nodes.append(contentsOf: inner)
                continue
            }

            if ch == "~" {
                flushText()
                index += 1
                nodes.append(.space(4))
                continue
            }

            if ch == "\n" || ch == "\r" {
                index += 1
                // Collapse bare newlines in LaTeX into subtle whitespace (actual linebreaks use \\)
                if !textBuf.isEmpty && !textBuf.hasSuffix(" ") {
                    textBuf.append(" ")
                }
                continue
            }

            if ch == "\\" {
                flushText()
                if let node = parseCommand(depth: depth + 1) {
                    nodes.append(node)
                }
                continue
            }

            textBuf.append(ch)
            index += 1
        }

        flushText()
        return coalesceNodes(nodes)
    }

    private mutating func parseSingleAtom(depth: Int) -> LatexNode? {
        guard index < chars.count else { return nil }
        let ch = chars[index]
        if ch == "\\" {
            return parseCommand(depth: depth)
        }
        index += 1
        return .text(String(ch))
    }

    private mutating func readCommandName() -> String {
        guard current == "\\" else { return "" }
        index += 1
        guard index < chars.count else { return "" }
        let first = chars[index]
        if first.isLetter {
            var name = ""
            while index < chars.count && chars[index].isLetter {
                name.append(chars[index])
                index += 1
            }
            // Handle starred commands like \hspace*
            if index < chars.count && chars[index] == "*" {
                name.append("*")
                index += 1
            }
            return name
        } else {
            index += 1
            return String(first)
        }
    }

    private func declarationStyleDelta(for cmd: String) -> LatexStyleDelta? {
        switch cmd {
        case "Huge": return LatexStyleDelta(scale: 2.05)
        case "huge": return LatexStyleDelta(scale: 1.72)
        case "LARGE": return LatexStyleDelta(scale: 1.44)
        case "Large": return LatexStyleDelta(scale: 1.28)
        case "large": return LatexStyleDelta(scale: 1.14)
        case "normalsize": return LatexStyleDelta(scale: 1.0)
        case "small": return LatexStyleDelta(scale: 0.88)
        case "footnotesize": return LatexStyleDelta(scale: 0.80)
        case "scriptsize": return LatexStyleDelta(scale: 0.72)
        case "tiny": return LatexStyleDelta(scale: 0.64)
        case "bf", "bfseries": return LatexStyleDelta(bold: true)
        case "it", "itshape": return LatexStyleDelta(italic: true)
        case "tt", "ttfamily": return LatexStyleDelta(monospaced: true)
        case "rm", "rmfamily", "sf", "sffamily": return LatexStyleDelta(italic: false)
        case "color": return LatexStyleDelta()
        default: return nil
        }
    }

    private mutating func parseCommand(depth: Int) -> LatexNode? {
        let cmd = readCommandName()
        guard !cmd.isEmpty else { return nil }

        switch cmd {
        // Explicit line breaks
        case "\\", "newline", "cr":
            var extra: CGFloat = 0
            if let spacingRaw = parseBracketRaw() {
                extra = parseDimension(spacingRaw, defaultPt: 4)
            }
            return .lineBreak(extraSpacing: extra)

        // Escaped punctuation / spaces
        case " ": return .space(4)
        case ",": return .space(2.5)
        case ":": return .space(4)
        case ";": return .space(5.5)
        case "!": return .space(0)
        case "quad": return .space(12)
        case "qquad": return .space(24)
        case "enspace", "enskip": return .space(8)
        case "thinspace": return .space(2.5)
        case "medspace": return .space(4)
        case "thickspace": return .space(5.5)
        case "hspace", "hspace*":
            let raw = parseBracedRaw() ?? ""
            return .space(max(0, parseDimension(raw, defaultPt: 8)))
        case "vspace", "vspace*":
            let raw = parseBracedRaw() ?? ""
            return .lineBreak(extraSpacing: max(0, parseDimension(raw, defaultPt: 6)))
        case "phantom", "hphantom":
            let raw = parseBracedRaw() ?? ""
            return .space(CGFloat(max(1, raw.count)) * 6)
        case "%", "_", "&", "#", "$", "{", "}":
            return .text(cmd)
        case "textbackslash":
            return .text("\\")

        // Colors & Boxes (Roleplay cards & bubbles!)
        case "textcolor":
            let colorStr = parseBracedRaw() ?? ""
            let body = parseGroupOrSingle(depth: depth + 1)
            return .styled(LatexStyleDelta(color: parseLatexColor(colorStr)), body)

        case "colorbox":
            let bgStr = parseBracedRaw() ?? ""
            let body = parseGroupOrSingle(depth: depth + 1)
            return .colorBox(bg: parseLatexColor(bgStr), border: nil, isFrameBox: false, body: body)

        case "fcolorbox":
            let borderStr = parseBracedRaw() ?? ""
            let bgStr = parseBracedRaw() ?? ""
            let body = parseGroupOrSingle(depth: depth + 1)
            return .colorBox(bg: parseLatexColor(bgStr), border: parseLatexColor(borderStr), isFrameBox: true, body: body)

        case "fbox", "boxed", "framebox":
            _ = parseBracketRaw() // optional width
            _ = parseBracketRaw() // optional align
            let body = parseGroupOrSingle(depth: depth + 1)
            return .colorBox(bg: nil, border: nil, isFrameBox: true, body: body)

        case "rule":
            _ = parseBracketRaw() // optional raise
            let wRaw = parseBracedRaw() ?? "6em"
            let hRaw = parseBracedRaw() ?? "1pt"
            return .rule(width: parseDimension(wRaw, defaultPt: 80), height: max(0.75, parseDimension(hRaw, defaultPt: 1)))

        // Text & Font style wrappers
        case "text", "textrm", "mathrm", "textsf", "mathsf", "operatorname", "mbox", "hbox":
            let body = parseGroupOrSingle(depth: depth + 1)
            return .styled(LatexStyleDelta(italic: false), body)
        case "textbf", "mathbf", "boldsymbol", "bm":
            let body = parseGroupOrSingle(depth: depth + 1)
            return .styled(LatexStyleDelta(bold: true), body)
        case "textit", "emph", "mathit":
            let body = parseGroupOrSingle(depth: depth + 1)
            return .styled(LatexStyleDelta(italic: true), body)
        case "texttt", "mathtt":
            let body = parseGroupOrSingle(depth: depth + 1)
            return .styled(LatexStyleDelta(monospaced: true), body)
        case "underline":
            let body = parseGroupOrSingle(depth: depth + 1)
            return .styled(LatexStyleDelta(underline: true), body)
        case "sout", "cancel", "bcancel", "xcancel":
            let body = parseGroupOrSingle(depth: depth + 1)
            return .styled(LatexStyleDelta(strikethrough: true), body)
        case "overline", "bar", "hat", "tilde", "vec", "dot", "ddot":
            let body = parseGroupOrSingle(depth: depth + 1)
            return .styled(LatexStyleDelta(), body)

        // Math structures
        case "frac", "dfrac", "tfrac", "cfrac":
            let num = parseGroupOrSingle(depth: depth + 1)
            let den = parseGroupOrSingle(depth: depth + 1)
            return .fraction(num: num, den: den)

        case "sqrt":
            let idxRaw = parseBracketRaw()
            let idxNodes: [LatexNode]? = idxRaw.map { LatexParser.parse($0, cacheable: false) }
            let body = parseGroupOrSingle(depth: depth + 1)
            return .sqrt(index: idxNodes, body: body)

        case "begin":
            let envName = (parseBracedRaw() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return parseEnvironment(envName, depth: depth + 1)

        case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr":
            skipHorizontalSpaces()
            guard index < chars.count else { return nil }
            let delim = chars[index]
            index += 1
            if delim == "." { return nil }
            if delim == "\\" {
                let dCmd = readCommandName()
                return .text(symbolMap[dCmd] ?? dCmd)
            }
            return .text(String(delim))

        // Style directives that don't produce visible glyphs
        case "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits", "notag", "nonumber":
            return nil

        // Standalone single trailing backslash before newline (defensive LLM fallback)
        case "\n", "\r":
            return .lineBreak(extraSpacing: 0)

        default:
            if let sym = symbolMap[cmd] {
                return .text(sym)
            }
            return .text(cmd)
        }
    }

    private mutating func parseEnvironment(_ name: String, depth: Int) -> LatexNode {
        var colAligns: [LatexColumnAlign] = [.center]
        var bracket: LatexMatrixBracket = .none

        switch name {
        case "array", "tabular":
            let spec = parseBracedRaw() ?? "c"
            colAligns = parseColumnSpec(spec)
        case "aligned", "align", "align*", "split", "eqnarray", "eqnarray*":
            colAligns = [.trailing, .leading]
        case "gathered", "gather", "gather*":
            colAligns = [.center]
        case "cases", "dcases", "rcases":
            colAligns = [.leading, .leading]
            bracket = .leftBraceOnly
        case "matrix":
            colAligns = [.center]
            bracket = .none
        case "pmatrix":
            colAligns = [.center]
            bracket = .paren
        case "bmatrix":
            colAligns = [.center]
            bracket = .bracket
        case "Bmatrix":
            colAligns = [.center]
            bracket = .brace
        case "vmatrix":
            colAligns = [.center]
            bracket = .pipe
        case "Vmatrix":
            colAligns = [.center]
            bracket = .doublePipe
        default:
            colAligns = [.leading]
        }

        // Extract raw environment body up to matching \end{name}
        let body = readEnvironmentBody(name: name)
        let rows = parseArrayRows(body, depth: depth + 1)
        return .array(columns: colAligns, rows: rows, bracket: bracket)
    }

    private mutating func readEnvironmentBody(name: String) -> String {
        let beginToken = "\\begin{\(name)}"
        let endToken = "\\end{\(name)}"
        var nesting = 1
        var buf: [Character] = []

        while index < chars.count && nesting > 0 {
            if peekMatch(beginToken) {
                nesting += 1
                buf.append(contentsOf: beginToken)
                index += beginToken.count
            } else if peekMatch(endToken) {
                nesting -= 1
                if nesting == 0 {
                    index += endToken.count
                    break
                } else {
                    buf.append(contentsOf: endToken)
                    index += endToken.count
                }
            } else {
                buf.append(chars[index])
                index += 1
            }
        }
        return String(buf)
    }

    private func parseArrayRows(_ body: String, depth: Int) -> [LatexArrayRow] {
        // Split body into raw rows on top-level `\\` (respecting nested braces & \begin..\end)
        let rawChars = Array(body)
        var rows: [LatexArrayRow] = []
        var currentRow = ""
        var braceDepth = 0
        var envDepth = 0
        var i = 0

        func flushRow(extraSpacing: CGFloat) {
            var trimmed = currentRow.trimmingCharacters(in: .whitespacesAndNewlines)
            currentRow.removeAll(keepingCapacity: true)
            guard !trimmed.isEmpty else { return }

            // Handle leading \hline / \hdashline commands
            while true {
                if trimmed.hasPrefix("\\hline") {
                    rows.append(.hline(dashed: false))
                    trimmed = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("\\hdashline") {
                    rows.append(.hline(dashed: true))
                    trimmed = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("\\midrule") || trimmed.hasPrefix("\\toprule") || trimmed.hasPrefix("\\bottomrule") {
                    let dropCount = trimmed.hasPrefix("\\bottomrule") ? 11 : 8
                    rows.append(.hline(dashed: false))
                    trimmed = String(trimmed.dropFirst(dropCount)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    break
                }
            }

            guard !trimmed.isEmpty else { return }
            let rawCells = splitTopLevelCells(trimmed)
            let parsedCells = rawCells.map { cellStr -> [LatexNode] in
                var st = ParserState(cellStr)
                return st.parseSequence(stopAt: nil, depth: depth + 1)
            }
            if !parsedCells.allSatisfy({ $0.isEmpty }) {
                rows.append(.cells(parsedCells, extraSpacing: extraSpacing))
            }
        }

        while i < rawChars.count {
            let c = rawChars[i]
            if c == "\\" {
                // Check \begin / \end nesting
                if matches(rawChars, at: i, literal: "\\begin{") {
                    envDepth += 1
                } else if matches(rawChars, at: i, literal: "\\end{") {
                    envDepth = max(0, envDepth - 1)
                }

                // Top-level row break: `\\` (with optional `[dim]`)
                if braceDepth == 0 && envDepth == 0 && i + 1 < rawChars.count && rawChars[i + 1] == "\\" {
                    i += 2
                    var spacing: CGFloat = 0
                    // Optional [6pt]
                    var look = i
                    while look < rawChars.count && (rawChars[look] == " " || rawChars[look] == "\t") { look += 1 }
                    if look < rawChars.count && rawChars[look] == "[" {
                        var endBracket = look + 1
                        var dimBuf = ""
                        while endBracket < rawChars.count && rawChars[endBracket] != "]" {
                            dimBuf.append(rawChars[endBracket])
                            endBracket += 1
                        }
                        if endBracket < rawChars.count && rawChars[endBracket] == "]" {
                            spacing = parseDimension(dimBuf, defaultPt: 4)
                            i = endBracket + 1
                        }
                    }
                    flushRow(extraSpacing: spacing)
                    continue
                }

                // Defensive fallback: lone `\` right before newline at top level of an array
                if braceDepth == 0 && envDepth == 0 {
                    var look = i + 1
                    while look < rawChars.count && (rawChars[look] == " " || rawChars[look] == "\t") { look += 1 }
                    if look < rawChars.count && (rawChars[look] == "\n" || rawChars[look] == "\r") {
                        i = look + 1
                        flushRow(extraSpacing: 0)
                        continue
                    }
                }

                // Escaped character (don't treat \{ or \} as brace nesting)
                currentRow.append(c)
                if i + 1 < rawChars.count {
                    i += 1
                    currentRow.append(rawChars[i])
                }
                i += 1
                continue
            }

            if c == "{" { braceDepth += 1 }
            else if c == "}" { braceDepth = max(0, braceDepth - 1) }

            currentRow.append(c)
            i += 1
        }

        flushRow(extraSpacing: 0)
        return rows
    }

    private func splitTopLevelCells(_ row: String) -> [String] {
        let chars = Array(row)
        var cells: [String] = []
        var buf = ""
        var braceDepth = 0
        var envDepth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                if matches(chars, at: i, literal: "\\begin{") { envDepth += 1 }
                else if matches(chars, at: i, literal: "\\end{") { envDepth = max(0, envDepth - 1) }
                buf.append(c)
                if i + 1 < chars.count {
                    i += 1
                    buf.append(chars[i])
                }
                i += 1
                continue
            }
            if c == "{" { braceDepth += 1 }
            else if c == "}" { braceDepth = max(0, braceDepth - 1) }
            else if c == "&" && braceDepth == 0 && envDepth == 0 {
                cells.append(buf)
                buf.removeAll(keepingCapacity: true)
                i += 1
                continue
            }
            buf.append(c)
            i += 1
        }
        cells.append(buf)
        return cells
    }

    private func matches(_ arr: [Character], at offset: Int, literal: String) -> Bool {
        let target = Array(literal)
        guard offset + target.count <= arr.count else { return false }
        for j in 0..<target.count {
            if arr[offset + j] != target[j] { return false }
        }
        return true
    }

    private func parseColumnSpec(_ spec: String) -> [LatexColumnAlign] {
        var aligns: [LatexColumnAlign] = []
        for ch in spec {
            switch ch {
            case "l": aligns.append(.leading)
            case "c": aligns.append(.center)
            case "r": aligns.append(.trailing)
            default: break
            }
        }
        return aligns.isEmpty ? [.center] : aligns
    }

    private func coalesceNodes(_ nodes: [LatexNode]) -> [LatexNode] {
        var out: [LatexNode] = []
        for node in nodes {
            if case .text(let nextText) = node,
               case .text(let prevText)? = out.last {
                out[out.count - 1] = .text(prevText + nextText)
            } else {
                out.append(node)
            }
        }
        return out
    }

    private func parseDimension(_ raw: String, defaultPt: CGFloat) -> CGFloat {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let numStr = String(s.prefix { $0.isNumber || $0 == "." || $0 == "-" })
        guard let val = Double(numStr) else { return defaultPt }
        if s.hasSuffix("em") { return CGFloat(val * 14.0) }
        if s.hasSuffix("ex") { return CGFloat(val * 7.5) }
        if s.hasSuffix("cm") { return CGFloat(val * 28.0) }
        if s.hasSuffix("mm") { return CGFloat(val * 2.8) }
        if s.hasSuffix("in") { return CGFloat(val * 72.0) }
        return CGFloat(val)
    }

    private func parseLatexColor(_ raw: String) -> LatexColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s != "none", s != "transparent" else { return nil }

        // Named CSS / LaTeX colors
        if let named = namedColors[s] {
            return named
        }

        // rgb(r, g, b)
        if s.hasPrefix("rgb(") && s.hasSuffix(")") {
            let inner = s.dropFirst(4).dropLast(1)
            let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 3 {
                return LatexColor(r: parts[0] / 255.0, g: parts[1] / 255.0, b: parts[2] / 255.0, a: 1.0)
            }
        }

        // Hex (#RGB, #RRGGBB, #RRGGBBAA, or bare RRGGBB)
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

        switch hex.count {
        case 3:
            let r = Double((value >> 8) & 0xF) / 15.0
            let g = Double((value >> 4) & 0xF) / 15.0
            let b = Double(value & 0xF) / 15.0
            return LatexColor(r: r, g: g, b: b, a: 1.0)
        case 6:
            let r = Double((value >> 16) & 0xFF) / 255.0
            let g = Double((value >> 8) & 0xFF) / 255.0
            let b = Double(value & 0xFF) / 255.0
            return LatexColor(r: r, g: g, b: b, a: 1.0)
        case 8:
            let r = Double((value >> 24) & 0xFF) / 255.0
            let g = Double((value >> 16) & 0xFF) / 255.0
            let b = Double((value >> 8) & 0xFF) / 255.0
            let a = Double(value & 0xFF) / 255.0
            return LatexColor(r: r, g: g, b: b, a: a)
        default:
            return nil
        }
    }

    private var namedColors: [String: LatexColor] {
        [
            "black": LatexColor(r: 0.08, g: 0.08, b: 0.09, a: 1),
            "white": LatexColor(r: 1, g: 1, b: 1, a: 1),
            "red": LatexColor(r: 0.90, g: 0.22, b: 0.22, a: 1),
            "crimson": LatexColor(r: 0.86, g: 0.08, b: 0.24, a: 1),
            "blue": LatexColor(r: 0.22, g: 0.39, b: 0.99, a: 1),
            "navy": LatexColor(r: 0.08, g: 0.16, b: 0.48, a: 1),
            "skyblue": LatexColor(r: 0.38, g: 0.72, b: 0.95, a: 1),
            "green": LatexColor(r: 0.13, g: 0.68, b: 0.33, a: 1),
            "teal": LatexColor(r: 0.08, g: 0.56, b: 0.56, a: 1),
            "cyan": LatexColor(r: 0.06, g: 0.68, b: 0.78, a: 1),
            "orange": LatexColor(r: 0.95, g: 0.52, b: 0.12, a: 1),
            "coral": LatexColor(r: 0.98, g: 0.45, b: 0.36, a: 1),
            "yellow": LatexColor(r: 0.92, g: 0.74, b: 0.08, a: 1),
            "gold": LatexColor(r: 0.88, g: 0.66, b: 0.14, a: 1),
            "purple": LatexColor(r: 0.58, g: 0.24, b: 0.85, a: 1),
            "violet": LatexColor(r: 0.54, g: 0.32, b: 0.88, a: 1),
            "indigo": LatexColor(r: 0.31, g: 0.27, b: 0.78, a: 1),
            "pink": LatexColor(r: 0.93, g: 0.42, b: 0.64, a: 1),
            "magenta": LatexColor(r: 0.86, g: 0.16, b: 0.58, a: 1),
            "brown": LatexColor(r: 0.55, g: 0.34, b: 0.20, a: 1),
            "gray": LatexColor(r: 0.53, g: 0.55, b: 0.58, a: 1),
            "grey": LatexColor(r: 0.53, g: 0.55, b: 0.58, a: 1),
            "darkgray": LatexColor(r: 0.33, g: 0.35, b: 0.38, a: 1),
            "lightgray": LatexColor(r: 0.82, g: 0.84, b: 0.86, a: 1),
            "silver": LatexColor(r: 0.75, g: 0.75, b: 0.78, a: 1),
            "olive": LatexColor(r: 0.50, g: 0.52, b: 0.16, a: 1),
            "maroon": LatexColor(r: 0.52, g: 0.10, b: 0.14, a: 1),
        ]
    }

    private var symbolMap: [String: String] {
        [
            // Greek lowercase
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
            "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
            "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ",
            "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
            "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
            // Greek uppercase
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
            "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
            // Operators & relations
            "times": "×", "div": "÷", "pm": "±", "mp": "∓", "cdot": "·", "cdots": "⋯",
            "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱", "ast": "∗", "star": "★",
            "circ": "∘", "bullet": "•", "oplus": "⊕", "otimes": "⊗",
            "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠",
            "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝",
            "ll": "≪", "gg": "≫", "perp": "⊥", "parallel": "∥",
            // Arrows
            "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
            "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔",
            "implies": "⇒", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
            // Sets & logic
            "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "supset": "⊃",
            "subseteq": "⊆", "supseteq": "⊇", "cup": "∪", "cap": "∩", "emptyset": "∅", "varnothing": "∅",
            "forall": "∀", "exists": "∃", "neg": "¬", "lnot": "¬", "land": "∧", "lor": "∨",
            "therefore": "∴", "because": "∵",
            // Calculus & misc
            "sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮",
            "infty": "∞", "partial": "∂", "nabla": "∇", "angle": "∠", "degree": "°",
            "triangle": "△", "square": "□", "blacksquare": "■", "diamond": "◇", "lozenge": "◊",
            "checkmark": "✓", "heartsuit": "♡", "spadesuit": "♠", "clubsuit": "♣", "diamondsuit": "♢",
            "ell": "ℓ", "hbar": "ℏ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
            "mid": "∣", "vert": "|", "Vert": "‖", "langle": "⟨", "rangle": "⟩",
            "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
            "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec", "csc": "csc",
            "log": "log", "ln": "ln", "exp": "exp", "lim": "lim", "max": "max", "min": "min",
            "sup": "sup", "inf": "inf", "det": "det", "gcd": "gcd", "arg": "arg", "deg": "deg",
            "mod": "mod", "bmod": "mod", "pmod": "mod",
        ]
    }
}

// MARK: - SwiftUI Renderer View

struct LatexRendererView: View {
    let formula: String
    let baseFontSize: Double
    let isStreaming: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let nodes = LatexParser.parse(formula, cacheable: !isStreaming)
        let darkMode = colorScheme == .dark
        let baseStyle = LatexStyle()

        if nodes.isEmpty {
            EmptyView()
        } else {
            LatexNodeListView(
                nodes: nodes,
                style: baseStyle,
                baseFontSize: baseFontSize,
                alignment: .leading,
                darkMode: darkMode
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

private struct LatexNodeListView: View {
    let nodes: [LatexNode]
    let style: LatexStyle
    let baseFontSize: Double
    let alignment: LatexColumnAlign
    let darkMode: Bool

    var body: some View {
        let lines = splitLines(nodes)
        if lines.count > 1 {
            VStack(alignment: alignment.horizontalAlignment, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    LatexInlineRowView(
                        nodes: line.nodes,
                        style: style,
                        baseFontSize: baseFontSize,
                        alignment: alignment,
                        darkMode: darkMode
                    )
                    .padding(.bottom, line.extraSpacing)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        } else if let only = lines.first {
            LatexInlineRowView(
                nodes: only.nodes,
                style: style,
                baseFontSize: baseFontSize,
                alignment: alignment,
                darkMode: darkMode
            )
        }
    }

    private struct LineSegment {
        let nodes: [LatexNode]
        let extraSpacing: CGFloat
    }

    private func splitLines(_ input: [LatexNode]) -> [LineSegment] {
        var result: [LineSegment] = []
        var buf: [LatexNode] = []
        for node in input {
            if case .lineBreak(let extra) = node {
                if !buf.isEmpty {
                    result.append(LineSegment(nodes: buf, extraSpacing: extra))
                    buf = []
                }
            } else {
                buf.append(node)
            }
        }
        if !buf.isEmpty {
            result.append(LineSegment(nodes: buf, extraSpacing: 0))
        }
        return result
    }
}

/// Renders a single horizontal line of LaTeX nodes.
/// - Pure text/styled runs collapse into a single wrappable `Text(AttributedString)` so captions & disclaimers wrap gracefully.
/// - Lines containing `\colorbox`, `\fbox`, `\frac`, `\sqrt`, `\rule`, or nested arrays render via clean flex `HStack` so chat bubbles & icons align naturally.
private struct LatexInlineRowView: View {
    let nodes: [LatexNode]
    let style: LatexStyle
    let baseFontSize: Double
    let alignment: LatexColumnAlign
    let darkMode: Bool

    var body: some View {
        // Unwrap single block-level array so it takes full width directly
        if nodes.count == 1, case .array(let cols, let rows, let bracket) = nodes[0] {
            LatexArrayView(
                columns: cols,
                rows: rows,
                bracket: bracket,
                style: style,
                baseFontSize: baseFontSize,
                darkMode: darkMode
            )
        } else if isPureTextTree(nodes) {
            Text(buildAttributedText(nodes: nodes, style: style))
                .multilineTextAlignment(alignment.textAlignment)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // Mix of text, spaces, bubbles (\colorbox), boxes (\fbox), fractions, etc.
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(groupedSegments(nodes).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .textRun(let runNodes):
                        Text(buildAttributedText(nodes: runNodes, style: style))
                            .multilineTextAlignment(alignment.textAlignment)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    case .spacer(let width):
                        Color.clear.frame(width: width, height: 1)
                    case .complex(let node):
                        renderComplex(node)
                    }
                }
            }
        }
    }

    private enum RowSegment {
        case textRun([LatexNode])
        case spacer(CGFloat)
        case complex(LatexNode)
    }

    private func groupedSegments(_ items: [LatexNode]) -> [RowSegment] {
        var segments: [RowSegment] = []
        var textBuf: [LatexNode] = []

        func flush() {
            if !textBuf.isEmpty {
                segments.append(.textRun(textBuf))
                textBuf.removeAll()
            }
        }

        for item in items {
            switch item {
            case .space(let pt):
                flush()
                if case .spacer(let prev)? = segments.last {
                    segments[segments.count - 1] = .spacer(prev + pt)
                } else {
                    segments.append(.spacer(pt))
                }
            case .text, .script:
                textBuf.append(item)
            case .styled(_, let children) where isPureTextTree(children):
                textBuf.append(item)
            default:
                flush()
                segments.append(.complex(item))
            }
        }
        flush()
        return segments
    }

    private func isPureTextTree(_ list: [LatexNode]) -> Bool {
        for item in list {
            switch item {
            case .text, .space:
                continue
            case .styled(_, let children):
                if !isPureTextTree(children) { return false }
            case .script(let b, let sup, let sub):
                if !isPureTextTree(b) { return false }
                if let sup, !isPureTextTree(sup) { return false }
                if let sub, !isPureTextTree(sub) { return false }
            default:
                return false
            }
        }
        return true
    }

    private func buildAttributedText(nodes: [LatexNode], style: LatexStyle) -> AttributedString {
        var result = AttributedString()
        appendText(nodes: nodes, style: style, into: &result)
        return result
    }

    private func appendText(nodes: [LatexNode], style: LatexStyle, into output: inout AttributedString) {
        for node in nodes {
            switch node {
            case .text(let str):
                var seg = AttributedString(str)
                let size = max(10, baseFontSize * style.scale)
                var font = Font.system(size: size, weight: style.bold ? .semibold : .regular, design: style.monospaced ? .monospaced : .default)
                if style.italic { font = font.italic() }
                seg.font = font
                if let c = style.color {
                    seg.foregroundColor = c.resolved(darkMode: darkMode, hasExplicitBackground: style.hasExplicitBackground)
                } else {
                    seg.foregroundColor = Color.nuwaLabelPrimary
                }
                if style.underline { seg.underlineStyle = .single }
                if style.strikethrough { seg.strikethroughStyle = .single }
                output.append(seg)

            case .space(let pt):
                let spaces = max(1, min(14, Int((pt / 4.5).rounded())))
                var seg = AttributedString(String(repeating: "\u{00A0}", count: spaces))
                seg.font = .system(size: max(10, baseFontSize * style.scale))
                output.append(seg)

            case .styled(let delta, let children):
                let next = LatexParser.mergeStyle(style, delta: delta)
                appendText(nodes: children, style: next, into: &output)

            case .script(let base, let sup, let sub):
                appendText(nodes: base, style: style, into: &output)
                let scriptScale = style.scale * 0.72
                if let sup {
                    var supStyle = style
                    supStyle.scale = scriptScale
                    var supAttr = AttributedString()
                    appendText(nodes: sup, style: supStyle, into: &supAttr)
                    supAttr.baselineOffset = baseFontSize * style.scale * 0.34
                    output.append(supAttr)
                }
                if let sub {
                    var subStyle = style
                    subStyle.scale = scriptScale
                    var subAttr = AttributedString()
                    appendText(nodes: sub, style: subStyle, into: &subAttr)
                    subAttr.baselineOffset = -baseFontSize * style.scale * 0.22
                    output.append(subAttr)
                }

            default:
                break
            }
        }
    }

    @ViewBuilder
    private func renderComplex(_ node: LatexNode) -> some View {
        switch node {
        case .styled(let delta, let children):
            let next = LatexParser.mergeStyle(style, delta: delta)
            LatexInlineRowView(
                nodes: children,
                style: next,
                baseFontSize: baseFontSize,
                alignment: alignment,
                darkMode: darkMode
            )

        case .colorBox(let bg, let border, let isFrameBox, let body):
            let boxStyle: LatexStyle = {
                var s = style
                if bg != nil { s.hasExplicitBackground = true }
                return s
            }()
            let strokeColor: Color = {
                if let border { return border.exactColor }
                if let c = style.color {
                    return c.resolved(darkMode: darkMode, hasExplicitBackground: style.hasExplicitBackground).opacity(0.65)
                }
                return Color.nuwaLabelSecondary.opacity(0.55)
            }()
            let cornerRadius: CGFloat = bg != nil ? 10 : 6
            let hPad: CGFloat = bg != nil ? 11 : 10
            let vPad: CGFloat = bg != nil ? 6 : 4

            LatexInlineRowView(
                nodes: body,
                style: boxStyle,
                baseFontSize: baseFontSize,
                alignment: .leading,
                darkMode: darkMode
            )
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background {
                if let bg {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(bg.exactColor)
                }
            }
            .overlay {
                if isFrameBox || border != nil {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                }
            }

        case .rule(let width, let height):
            let fill = style.color?.resolved(darkMode: darkMode, hasExplicitBackground: style.hasExplicitBackground)
                ?? Color.nuwaLabelTertiary.opacity(0.6)
            Rectangle()
                .fill(fill)
                .frame(maxWidth: min(width, 280), minHeight: height, maxHeight: height)

        case .fraction(let num, let den):
            let fracStyle: LatexStyle = {
                var s = style
                s.scale = max(0.75, style.scale * 0.88)
                return s
            }()
            let barColor = style.color?.resolved(darkMode: darkMode, hasExplicitBackground: style.hasExplicitBackground)
                ?? Color.nuwaLabelPrimary
            VStack(spacing: 2) {
                LatexInlineRowView(nodes: num, style: fracStyle, baseFontSize: baseFontSize, alignment: .center, darkMode: darkMode)
                Rectangle()
                    .fill(barColor.opacity(0.85))
                    .frame(height: 1)
                    .frame(minWidth: 16)
                LatexInlineRowView(nodes: den, style: fracStyle, baseFontSize: baseFontSize, alignment: .center, darkMode: darkMode)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 3)

        case .sqrt(let indexNodes, let body):
            let stroke = style.color?.resolved(darkMode: darkMode, hasExplicitBackground: style.hasExplicitBackground)
                ?? Color.nuwaLabelPrimary
            HStack(alignment: .center, spacing: 1) {
                if let indexNodes {
                    let idxStyle = LatexParser.mergeStyle(style, delta: LatexStyleDelta(scale: style.scale * 0.65))
                    LatexInlineRowView(nodes: indexNodes, style: idxStyle, baseFontSize: baseFontSize, alignment: .trailing, darkMode: darkMode)
                        .offset(y: -4)
                }
                Text("√")
                    .font(.system(size: max(12, baseFontSize * style.scale * 1.1)))
                    .foregroundStyle(stroke)
                VStack(spacing: 1) {
                    Rectangle().fill(stroke.opacity(0.85)).frame(height: 1)
                    LatexInlineRowView(nodes: body, style: style, baseFontSize: baseFontSize, alignment: .leading, darkMode: darkMode)
                        .padding(.horizontal, 2)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

        case .array(let cols, let rows, let bracket):
            LatexArrayView(
                columns: cols,
                rows: rows,
                bracket: bracket,
                style: style,
                baseFontSize: baseFontSize,
                darkMode: darkMode
            )

        default:
            EmptyView()
        }
    }
}

private struct LatexArrayView: View {
    let columns: [LatexColumnAlign]
    let rows: [LatexArrayRow]
    let bracket: LatexMatrixBracket
    let style: LatexStyle
    let baseFontSize: Double
    let darkMode: Bool

    private var maxCols: Int {
        rows.reduce(1) { acc, row in
            if case .cells(let cells, _) = row { return max(acc, cells.count) }
            return acc
        }
    }

    var body: some View {
        if maxCols <= 1 && bracket == .none {
            // Single-column array (e.g. \begin{array}{c} / {l} / {r} roleplay cards & bubbles!)
            // Renders full-width responsive VStack so captions and chat bubbles wrap cleanly on iPhone!
            let colAlign = columns.first ?? .center
            VStack(alignment: colAlign.horizontalAlignment, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .hline(let dashed):
                        if dashed {
                            HorizontalLineShape()
                                .stroke(style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
                                .foregroundStyle(Color.nuwaControlBorder)
                                .frame(height: 1)
                                .padding(.vertical, 2)
                        } else {
                            Divider()
                                .padding(.vertical, 2)
                        }
                    case .cells(let cells, let extraSpacing):
                        if let first = cells.first {
                            LatexInlineRowView(
                                nodes: first,
                                style: style,
                                baseFontSize: baseFontSize,
                                alignment: colAlign,
                                darkMode: darkMode
                            )
                            .padding(.bottom, extraSpacing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: colAlign.frameAlignment)
            .padding(.vertical, 4)
        } else {
            // Multi-column array / aligned equations / cases / matrices
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 4) {
                    leftBracketView
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            switch row {
                            case .hline:
                                Divider().gridCellUnsizedAxes(.horizontal)
                            case .cells(let cells, let extraSpacing):
                                GridRow {
                                    ForEach(0..<maxCols, id: \.self) { colIdx in
                                        let align = colIdx < columns.count ? columns[colIdx] : (columns.last ?? .center)
                                        let cellNodes = colIdx < cells.count ? cells[colIdx] : []
                                        LatexInlineRowView(
                                            nodes: cellNodes,
                                            style: style,
                                            baseFontSize: baseFontSize,
                                            alignment: align,
                                            darkMode: darkMode
                                        )
                                        .gridColumnAlignment(align.horizontalAlignment)
                                    }
                                }
                                .padding(.bottom, extraSpacing)
                            }
                        }
                    }
                    rightBracketView
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var leftBracketView: some View {
        switch bracket {
        case .none: EmptyView()
        case .paren: bracketSymbol("(")
        case .bracket: bracketSymbol("[")
        case .brace, .leftBraceOnly: bracketSymbol("{")
        case .pipe: bracketSymbol("|")
        case .doublePipe: bracketSymbol("‖")
        }
    }

    @ViewBuilder
    private var rightBracketView: some View {
        switch bracket {
        case .none, .leftBraceOnly: EmptyView()
        case .paren: bracketSymbol(")")
        case .bracket: bracketSymbol("]")
        case .brace: bracketSymbol("}")
        case .pipe: bracketSymbol("|")
        case .doublePipe: bracketSymbol("‖")
        }
    }

    private func bracketSymbol(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: max(20, baseFontSize * 1.6), weight: .light))
            .foregroundStyle(Color.nuwaLabelSecondary)
    }
}

private struct HorizontalLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
