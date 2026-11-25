import Foundation

enum ConversationScene: String {
    case creative
    case general
}

struct ResolvedCompaction: Equatable {
    let span: CompactionSpan
    let startRoundIndex: Int
    let endRoundIndex: Int
}

enum ProjectedContextItem {
    case compaction(CompactionSpan)
    case round(question: ChatMessage, reply: ChatMessage)
}

struct CompactionTarget {
    let rounds: [(question: ChatMessage, reply: ChatMessage)]
    let startMessageId: UUID
    let endMessageId: UUID
    let startRoundNumber: Int
    let endRoundNumber: Int
    let scene: ConversationScene
    let title: String
    let originalTokensEstimate: Int
    let previousSummaries: [CompactionSpan]
}

struct ContextStats: Equatable {
    let totalRounds: Int
    let activeCompactions: [ResolvedCompaction]
    let compactedRounds: Int
    let uncompactedCount: Int
    let effectiveTokens: Int
    let estimatedProjectedTokens: Int
    let pressure: Double
    let canManualCompact: Bool
}

struct RecalledMemoryResult: Equatable {
    let blockText: String
    let roundNumbers: [Int]
    let spanTitles: [String]
}

struct CompactionProgress: Equatable {
    let done: Int
    let total: Int
}

/// 1:1 Swift port of chat-demo/src/services/chat/compaction.ts:
/// - Non-destructive chunked context compaction (auto pre-send + manual batch追赶)
/// - Branch-aware active compaction span resolution
/// - Pure-local 0ms IDF-weighted memory recall with Nuwa E2 append-only deduplication
enum ContextCompaction {
    /// Protected verbatim tail rounds so tone, style, and recent details remain intact.
    static let protectedTailRounds = 8
    /// Trigger automatic block compaction when uncompacted rounds reach this count.
    static let autoCompactUncompactedRounds = 20
    /// Trigger automatic block compaction when context input tokens reach this threshold (under 32K extended limit).
    static let autoCompactTokenThreshold = 28_000
    /// Minimum rounds to fold in one auto compaction pass to avoid fragmenting prefix cache.
    static let autoMinCompactableRounds = 6
    /// Maximum rounds / tokens per single auto span.
    static let maxCompactRoundsPerSpan = 50
    static let maxCompactTokensPerSpan = 60_000
    /// Maximum rounds / tokens per chunk during batch catch-up compaction.
    static let batchMaxRoundsPerSpan = 80
    static let batchMaxTokensPerSpan = 75_000
    /// Minimum tail / compactable rounds for manual compaction.
    static let manualMinTailRounds = 2
    static let manualMinCompactableRounds = 2
    /// Display context window scale for the 4-color status ring & progress bar (DeepSeek 1M window).
    static let displayContextWindowTokens = 1_000_000
    /// Concurrent chunk summarization workers.
    static let batchCompactConcurrency = 3

    private static let creativeSceneRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"角色扮演|扮演|人设|世界观|小说|剧情|伏笔|口癖|第一章|第一卷|章节|主控|设定|修仙|穿越|重生|「[^」]{2,}」|『[^』]{2,}』|(?:他|她)[^。\n]{0,12}(?:说道|低声|轻笑|皱眉|冷声|问道)"#,
        options: []
    )

    private static let keywordsLineRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\n*<!--\s*KEYWORDS:\s*([^\n]+?)\s*-->\s*$"#,
        options: [.caseInsensitive]
    )

    private static let recallIntentRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"记得|记不记得|来着|当初|之前|最早|上次|那次|那块|那半张|那个|刻着|写着|发誓|答应|说过|原话|临终|临走|叫什么|具体|背错|暗号|押的|真名|付出|失去|记得吗"#,
        options: []
    )

    private static let asciiTermRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9][A-Za-z0-9._-]{1,}"#,
        options: []
    )

    private static let quotedTermRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[「『“"]([^「『“"」』”]{2,12})[」』”"]"#,
        options: []
    )

    private static let cjkSegmentRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[\u4e00-\u9fff]{2,}"#,
        options: []
    )

    private static let recallStopWords: Set<String> = [
        "我们", "你们", "他们", "自己", "这个", "那个", "什么", "怎么", "为什么", "可以", "已经",
        "还是", "但是", "因为", "所以", "如果", "然后", "现在", "觉得", "知道", "看着", "抬头",
        "低声", "问道", "笑着", "摇头", "点头", "时候", "地方", "东西", "一下", "一点", "有些",
        "有点", "好像", "刚才", "其实", "不是", "没有", "不会", "不能", "应该", "可能", "这么",
        "那么", "这里", "那里", "出来", "进去",
    ]

    static let systemPromptCreative = """
    你是一位专业的小说编辑与剧情档案员，擅长为长篇写作与角色扮演整理高保真、低幻觉的记忆档案。
    你必须严格遵守以下规则：
    1. 忠实原文：严禁编造、脑补对话中未发生的事件、台词或心理活动。
    2. 保留专有名词：所有人名、昵称、地名、组织、招式、道具、特定称呼与角色口癖必须原样保留。
    3. 双轨保真：既要提炼不可丢失的核心设定与人设锚点，也要按时间顺序记录剧情脉络与状态变更。
    4. 增量不重复：若提供了既有记忆，仅总结本次新增片段，不要重复抄写未变化的内容。
    5. 直接输出记忆档案正文，不要输出任何开场白或元解释。
    """

    static let systemPromptGeneral = """
    你是一位严谨的对话上下文整理助手，擅长为长对话（日常咨询、学习、分析、技术协作等）提炼高保真、低冗余的阶段记忆。
    你必须严格遵守以下规则：
    1. 忠实原文：严禁编造对话中未出现的结论、数字、参数或事实。
    2. 保留关键信息：人名、项目名、文件路径、代码标识、明确的数字/日期/偏好与约束条件必须原样保留。
    3. 增量不重复：若提供了既有记忆，仅总结本次新增片段，不要重复抄写未变化的内容。
    4. 高信息密度：删去客套寒暄与重复解释，保留目标、已定结论、关键依据与待办事项。
    5. 直接输出整理后的正文，不要输出任何开场白或元解释。
    """

    static func systemPrompt(for scene: ConversationScene) -> String {
        scene == .creative ? systemPromptCreative : systemPromptGeneral
    }

    // MARK: - Token Estimation & Formatting

    static func estimateTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for code in text.utf16 {
            if (code >= 0x4E00 && code <= 0x9FFF)
                || (code >= 0x3400 && code <= 0x4DBF)
                || (code >= 0x3000 && code <= 0x303F)
                || (code >= 0xFF00 && code <= 0xFFEF) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return max(1, Int(ceil(Double(cjk) * 1.5 + Double(other) * 0.3)))
    }

    static func estimateRoundTokens(_ round: (question: ChatMessage, reply: ChatMessage)) -> Int {
        estimateTextTokens(round.question.content) + estimateTextTokens(round.reply.fullTextContent) + 16
    }

    static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.2fM", Double(tokens) / 1_000_000.0)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fk", Double(tokens) / 1_000.0)
        }
        return String(tokens)
    }

    // MARK: - Scene Detection

    static func detectConversationScene(_ rounds: [(question: ChatMessage, reply: ChatMessage)]) -> ConversationScene {
        guard let regex = creativeSceneRegex else { return .general }
        var score = 0
        let sampleCount = min(rounds.count, 6)
        for i in 0..<sampleCount {
            let text = "\(rounds[i].question.content)\n\(rounds[i].reply.fullTextContent)"
            let range = NSRange(text.startIndex..., in: text)
            score += regex.numberOfMatches(in: text, options: [], range: range)
        }
        return score >= 3 ? .creative : .general
    }

    // MARK: - Branch-Aware Compaction Resolution & Projection

    static func resolveActiveCompactions(
        rounds: [(question: ChatMessage, reply: ChatMessage)],
        compactions: [CompactionSpan]?
    ) -> [ResolvedCompaction] {
        guard let compactions, !compactions.isEmpty, !rounds.isEmpty else { return [] }
        var userIndexById = [UUID: Int](minimumCapacity: rounds.count)
        var replyIndexById = [UUID: Int](minimumCapacity: rounds.count)
        for (i, round) in rounds.enumerated() {
            userIndexById[round.question.id] = i
            replyIndexById[round.reply.id] = i
        }

        var matched: [ResolvedCompaction] = []
        for span in compactions {
            if let startIdx = userIndexById[span.startMessageId],
               let endIdx = replyIndexById[span.endMessageId],
               startIdx <= endIdx {
                matched.append(ResolvedCompaction(span: span, startRoundIndex: startIdx, endRoundIndex: endIdx))
            }
        }
        if matched.count <= 1 { return matched }

        matched.sort { lhs, rhs in
            if lhs.startRoundIndex != rhs.startRoundIndex {
                return lhs.startRoundIndex < rhs.startRoundIndex
            }
            let lenL = lhs.endRoundIndex - lhs.startRoundIndex
            let lenR = rhs.endRoundIndex - rhs.startRoundIndex
            if lenL != lenR {
                return lenL > lenR
            }
            return lhs.span.updatedAt > rhs.span.updatedAt
        }

        var active: [ResolvedCompaction] = []
        var coveredUntil = -1
        for item in matched {
            if item.startRoundIndex > coveredUntil {
                active.append(item)
                coveredUntil = item.endRoundIndex
            }
        }
        return active
    }

    static func projectContextItems(
        history: [ChatMessage],
        compactions: [CompactionSpan]?
    ) -> [ProjectedContextItem] {
        let rounds = AIClient.contextRounds(history)
        let active = resolveActiveCompactions(rounds: rounds, compactions: compactions)
        if active.isEmpty {
            return rounds.map { .round(question: $0.question, reply: $0.reply) }
        }

        var byStart = [Int: ResolvedCompaction](minimumCapacity: active.count)
        for item in active {
            byStart[item.startRoundIndex] = item
        }

        var projected: [ProjectedContextItem] = []
        var i = 0
        while i < rounds.count {
            if let hit = byStart[i] {
                projected.append(.compaction(hit.span))
                i = hit.endRoundIndex + 1
            } else {
                projected.append(.round(question: rounds[i].question, reply: rounds[i].reply))
                i += 1
            }
        }
        return projected
    }

    static func toCompactionMessagePair(_ span: CompactionSpan) -> (userText: String, assistantText: String) {
        let trimmedSummary = span.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let userText = """
        <context_memory title="\(span.title)" rounds="\(span.coveredRounds)">
        \(trimmedSummary)
        </context_memory>
        以上是此前已整理的对话记忆，请严格遵循其中的设定、事实、约束与上下文状态，自然承接后续对话。
        """
        let assistantText = "已载入此前记忆，我将保持上下文与设定连贯继续。"
        return (userText, assistantText)
    }

    // MARK: - Context Stats & Target Selection

    static func inspectContextStats(
        visibleMessages: [ChatMessage],
        compactions: [CompactionSpan]?
    ) -> ContextStats {
        let rounds = AIClient.contextRounds(visibleMessages)
        let active = resolveActiveCompactions(rounds: rounds, compactions: compactions)

        var coveredFlags = [Bool](repeating: false, count: rounds.count)
        var latestCompactionTime: Date?
        var summaryTokens = 0
        var compactedRounds = 0

        for item in active {
            summaryTokens += item.span.summaryTokensEstimate
            compactedRounds += item.span.coveredRounds
            if latestCompactionTime == nil || item.span.updatedAt > latestCompactionTime! {
                latestCompactionTime = item.span.updatedAt
            }
            for i in item.startRoundIndex...item.endRoundIndex where i < coveredFlags.count {
                coveredFlags[i] = true
            }
        }

        var uncompactedCount = 0
        var uncompactedTokens = 0
        for i in rounds.indices where !coveredFlags[i] {
            uncompactedCount += 1
            uncompactedTokens += estimateRoundTokens(rounds[i])
        }

        var latestUsageInput: Int?
        for i in stride(from: rounds.count - 1, through: 0, by: -1) {
            let reply = rounds[i].reply
            if let tokens = reply.usage?.inputTokens, tokens > 0 {
                if latestCompactionTime == nil || reply.createdAt > latestCompactionTime! {
                    latestUsageInput = tokens
                }
                break
            }
        }

        let estimatedProjectedTokens = summaryTokens + uncompactedTokens
        let effectiveTokens = latestUsageInput ?? estimatedProjectedTokens
        let pressure = min(1.0, Double(effectiveTokens) / Double(displayContextWindowTokens))

        return ContextStats(
            totalRounds: rounds.count,
            activeCompactions: active,
            compactedRounds: compactedRounds,
            uncompactedCount: uncompactedCount,
            effectiveTokens: effectiveTokens,
            estimatedProjectedTokens: estimatedProjectedTokens,
            pressure: pressure,
            canManualCompact: uncompactedCount >= manualMinCompactableRounds + manualMinTailRounds
        )
    }

    static func selectCompactionTarget(
        visibleMessages: [ChatMessage],
        compactions: [CompactionSpan]?,
        source: CompactionSource
    ) -> CompactionTarget? {
        let rounds = AIClient.contextRounds(visibleMessages)
        let active = resolveActiveCompactions(rounds: rounds, compactions: compactions)
        let startOffset = active.last.map { $0.endRoundIndex + 1 } ?? 0
        guard startOffset < rounds.count else { return nil }
        let uncompacted = Array(rounds[startOffset...])

        if source == .auto {
            let stats = inspectContextStats(visibleMessages: visibleMessages, compactions: compactions)
            let hitRoundThreshold = uncompacted.count >= autoCompactUncompactedRounds
            let hitTokenThreshold = stats.effectiveTokens >= autoCompactTokenThreshold
            guard hitRoundThreshold || hitTokenThreshold else { return nil }
            let compactCount = uncompacted.count - protectedTailRounds
            guard compactCount >= autoMinCompactableRounds else { return nil }
            return buildTarget(
                rawSlice: Array(uncompacted.prefix(compactCount)),
                startOffset: startOffset,
                previousSummaries: active.map(\.span)
            )
        }

        let tailKeep = uncompacted.count >= protectedTailRounds + manualMinCompactableRounds
            ? protectedTailRounds
            : manualMinTailRounds
        let compactCount = uncompacted.count - tailKeep
        guard compactCount >= manualMinCompactableRounds else { return nil }
        return buildTarget(
            rawSlice: Array(uncompacted.prefix(compactCount)),
            startOffset: startOffset,
            previousSummaries: active.map(\.span)
        )
    }

    static func selectBatchCompactionTargets(
        visibleMessages: [ChatMessage],
        compactions: [CompactionSpan]?
    ) -> [CompactionTarget] {
        let rounds = AIClient.contextRounds(visibleMessages)
        let active = resolveActiveCompactions(rounds: rounds, compactions: compactions)
        let startOffset = active.last.map { $0.endRoundIndex + 1 } ?? 0
        guard startOffset < rounds.count else { return [] }
        let uncompacted = Array(rounds[startOffset...])

        let tailKeep = uncompacted.count >= protectedTailRounds + manualMinCompactableRounds
            ? protectedTailRounds
            : manualMinTailRounds
        let compactableTotal = uncompacted.count - tailKeep
        guard compactableTotal >= manualMinCompactableRounds else { return [] }

        let allCompactable = Array(uncompacted.prefix(compactableTotal))
        let previousSummaries = active.map(\.span)
        var targets: [CompactionTarget] = []
        var cursor = 0
        while cursor < allCompactable.count {
            let remaining = Array(allCompactable[cursor...])
            if remaining.count < manualMinCompactableRounds { break }
            let target = buildTarget(
                rawSlice: remaining,
                startOffset: startOffset + cursor,
                previousSummaries: cursor == 0 ? previousSummaries : [],
                maxRounds: batchMaxRoundsPerSpan,
                maxTokens: batchMaxTokensPerSpan
            )
            targets.append(target)
            cursor += target.rounds.count
        }
        return targets
    }

    private static func capCompactionSlice(
        _ slice: [(question: ChatMessage, reply: ChatMessage)],
        maxRounds: Int,
        maxTokens: Int
    ) -> [(question: ChatMessage, reply: ChatMessage)] {
        var capped: [(question: ChatMessage, reply: ChatMessage)] = []
        var tokens = 0
        for round in slice {
            let roundTokens = estimateRoundTokens(round)
            if capped.count >= manualMinCompactableRounds && (capped.count >= maxRounds || tokens + roundTokens > maxTokens) {
                break
            }
            capped.append(round)
            tokens += roundTokens
        }
        return capped
    }

    private static func buildTarget(
        rawSlice: [(question: ChatMessage, reply: ChatMessage)],
        startOffset: Int,
        previousSummaries: [CompactionSpan],
        maxRounds: Int = maxCompactRoundsPerSpan,
        maxTokens: Int = maxCompactTokensPerSpan
    ) -> CompactionTarget {
        let slice = capCompactionSlice(rawSlice, maxRounds: maxRounds, maxTokens: maxTokens)
        let startRoundNumber = startOffset + 1
        let endRoundNumber = startOffset + slice.count
        let scene = detectConversationScene(slice)
        let originalTokensEstimate = slice.reduce(0) { $0 + estimateRoundTokens($1) }
        let title = scene == .creative
            ? "第 \(startRoundNumber)–\(endRoundNumber) 轮剧情记忆"
            : "第 \(startRoundNumber)–\(endRoundNumber) 轮对话记忆"
        return CompactionTarget(
            rounds: slice,
            startMessageId: slice[0].question.id,
            endMessageId: slice[slice.count - 1].reply.id,
            startRoundNumber: startRoundNumber,
            endRoundNumber: endRoundNumber,
            scene: scene,
            title: title,
            originalTokensEstimate: originalTokensEstimate,
            previousSummaries: previousSummaries
        )
    }

    // MARK: - Prompt Formatting & Parsing

    static func formatTranscriptForCompaction(_ target: CompactionTarget) -> String {
        var sections: [String] = []

        if !target.previousSummaries.isEmpty {
            let prevText = target.previousSummaries
                .map { "[\($0.title)]\n\($0.summary)" }
                .joined(separator: "\n\n")
            sections.append("【既有记忆（仅供参考，请勿重复抄写未变化内容）】\n\(prevText)")
        }

        let isOpeningBlock = target.startRoundNumber == 1
        let transcript = target.rounds.enumerated().map { idx, round in
            let roundNo = target.startRoundNumber + idx
            let rawUser = round.question.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let userText = rawUser.isEmpty ? "（附件消息）" : rawUser
            let replyText = round.reply.fullTextContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return "--- 第 \(roundNo) 轮 ---\n【用户】\n\(userText)\n\n【助手】\n\(replyText)"
        }.joined(separator: "\n\n")

        sections.append("【本次需要整理的对话片段（第 \(target.startRoundNumber)–\(target.endRoundNumber) 轮）】\n\(transcript)")

        if target.scene == .creative {
            let anchorHint = isOpeningBlock
                ? "（完整提炼角色性格、称呼、口癖、文风要求与世界观规则）"
                : "（仅记录本段新增或变更的设定）"
            sections.append("""
            请按以下结构输出整理后的记忆档案（无内容的条目可省略）：
            ### 1. 核心设定与人设锚点\(anchorHint)
            - ...
            ### 2. 剧情脉络
            - ...
            ### 3. 人物状态与关系变化
            - 角色名：当前位置 / 状态 / 关系变化 / 秘密
            ### 4. 关键物品、约定与未回收伏笔
            - ...
            ### 5. 尾声衔接锚点
            - （本片段结束时的精确时间、地点、在场人物与动作）

            最后另起一行，列出 5–12 个本段最核心的专有名词、人名、地点或道具关键词（用顿号分隔）：
            <!-- KEYWORDS: 关键词1、关键词2、关键词3 -->
            """)
        } else {
            let goalHint = isOpeningBlock
                ? "（提炼用户背景、核心需求、格式或风格要求）"
                : "（仅记录本段新增或变更的要求）"
            sections.append("""
            请按以下结构输出整理后的阶段记忆（无内容的条目可省略）：
            ### 1. 核心目标与约束偏好\(goalHint)
            - ...
            ### 2. 已确认的结论与关键事实
            - ...
            ### 3. 重要细节（数据 / 专有名词 / 路径 / 决策依据）
            - ...
            ### 4. 未决问题与后续衔接点
            - ...

            最后另起一行，列出 5–12 个本段最核心的专有名词、主题或实体关键词（用顿号分隔）：
            <!-- KEYWORDS: 关键词1、关键词2、关键词3 -->
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    static func parseSummaryAndKeywords(_ raw: String) -> (summary: String, keywords: [String]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = keywordsLineRegex,
              let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges >= 2,
              let matchRange = Range(match.range, in: trimmed),
              let captureRange = Range(match.range(at: 1), in: trimmed)
        else {
            return (trimmed, [])
        }
        let summary = String(trimmed[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: "、,，/｜|")
        var seen = Set<String>()
        var keywords: [String] = []
        for piece in String(trimmed[captureRange]).components(separatedBy: separators) {
            let item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.count >= 2 && item.count <= 24 && seen.insert(item).inserted {
                keywords.append(item)
            }
        }
        return (summary.isEmpty ? trimmed : summary, keywords)
    }

    // MARK: - V1 Pure-Local Zero-Latency Memory Recall (Nuwa E2 Append-Only Dedup)

    private static func extractRecallTerms(_ text: String) -> [String] {
        var terms = Set<String>()
        var ordered: [String] = []
        func insert(_ term: String) {
            if terms.insert(term).inserted {
                ordered.append(term)
            }
        }

        let nsRange = NSRange(text.startIndex..., in: text)

        if let regex = asciiTermRegex {
            for match in regex.matches(in: text, options: [], range: nsRange) {
                if let range = Range(match.range, in: text) {
                    insert(String(text[range]).lowercased())
                }
            }
        }

        if let regex = quotedTermRegex {
            for match in regex.matches(in: text, options: [], range: nsRange) {
                if match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) {
                    let phrase = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !phrase.isEmpty && !recallStopWords.contains(phrase) {
                        insert(phrase)
                    }
                }
            }
        }

        if let regex = cjkSegmentRegex {
            for match in regex.matches(in: text, options: [], range: nsRange) {
                if let range = Range(match.range, in: text) {
                    let chars = Array(text[range])
                    for n in 2...3 where chars.count >= n {
                        for i in 0...(chars.count - n) {
                            let gram = String(chars[i..<(i + n)])
                            if !recallStopWords.contains(gram) {
                                insert(gram)
                            }
                        }
                    }
                }
            }
        }

        return ordered
    }

    private static func extractFocusedSnippet(_ text: String, terms: [String], maxLen: Int = 700) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLen { return trimmed }
        let paras = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !paras.isEmpty else { return String(trimmed.prefix(maxLen)) }
        let lowerTerms = terms.map { $0.lowercased() }
        var bestIdx = paras.count - 1
        var bestHits = -1
        for (i, para) in paras.enumerated() {
            let lower = para.lowercased()
            var hits = 0
            for term in lowerTerms where lower.contains(term) {
                hits += 1
            }
            if hits >= bestHits {
                bestHits = hits
                bestIdx = i
            }
        }
        let start = max(0, bestIdx - 1)
        let end = min(paras.count, bestIdx + 2)
        return String(paras[start..<end].joined(separator: "\n").prefix(maxLen))
    }

    static func recallRelevantHistory(
        queryText: String,
        history: [ChatMessage],
        compactions: [CompactionSpan]?
    ) -> RecalledMemoryResult? {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let compactions, !compactions.isEmpty else { return nil }
        let rounds = AIClient.contextRounds(history)
        let active = resolveActiveCompactions(rounds: rounds, compactions: compactions)
        guard !active.isEmpty else { return nil }

        struct CoveredEntry {
            let roundNumber: Int
            let spanTitle: String
            let userText: String
            let replyText: String
            let docLower: String
        }

        var covered: [CoveredEntry] = []
        var coveredIndexes = Set<Int>()
        var allKeywords = Set<String>()

        for item in active {
            for kw in item.span.keywords ?? [] {
                allKeywords.insert(kw.lowercased())
            }
            for i in item.startRoundIndex...item.endRoundIndex where i < rounds.count {
                coveredIndexes.insert(i)
                let userText = rounds[i].question.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let replyText = rounds[i].reply.fullTextContent.trimmingCharacters(in: .whitespacesAndNewlines)
                covered.append(CoveredEntry(
                    roundNumber: i + 1,
                    spanTitle: item.span.title,
                    userText: userText,
                    replyText: replyText,
                    docLower: "\(userText)\n\(replyText)".lowercased()
                ))
            }
        }

        guard !covered.isEmpty else { return nil }

        var tailParts: [String] = []
        var alreadyRecalledInTail = Set<Int>()
        for i in rounds.indices where !coveredIndexes.contains(i) {
            tailParts.append(rounds[i].question.content)
            tailParts.append(rounds[i].reply.fullTextContent)
            for num in rounds[i].reply.recalledMemory?.roundNumbers ?? [] {
                alreadyRecalledInTail.insert(num)
            }
        }
        let tailLower = tailParts.joined(separator: "\n").lowercased()

        let hasIntent: Bool = {
            guard let regex = recallIntentRegex else { return false }
            let range = NSRange(trimmedQuery.startIndex..., in: trimmedQuery)
            return regex.firstMatch(in: trimmedQuery, options: [], range: range) != nil
        }()
        let queryTerms = extractRecallTerms(trimmedQuery)
        guard !queryTerms.isEmpty else { return nil }

        let hitIndexKeyword = queryTerms.contains { term in
            let lower = term.lowercased()
            return allKeywords.contains(lower) && !tailLower.contains(lower)
        }

        guard hasIntent || hitIndexKeyword else { return nil }

        let totalCovered = covered.count
        let maxDf = max(3, Int(floor(Double(totalCovered) * 0.12)))
        var usefulTerms: [(lower: String, weight: Double)] = []

        for term in queryTerms {
            let lower = term.lowercased()
            var df = 0
            for entry in covered where entry.docLower.contains(lower) {
                df += 1
            }
            if df > 0 && df <= maxDf {
                let idf = log(Double(totalCovered + 1) / (Double(df) + 0.5)) + 0.5
                let lengthBoost = term.count >= 3 ? 1.5 : 1.0
                let indexBoost = allKeywords.contains(lower) ? 1.6 : 1.0
                let tailPenalty = tailLower.contains(lower) ? 0.35 : 1.0
                usefulTerms.append((lower, idf * lengthBoost * indexBoost * tailPenalty))
            }
        }

        guard !usefulTerms.isEmpty else { return nil }

        var scored: [(entry: CoveredEntry, score: Double)] = []
        for entry in covered {
            if alreadyRecalledInTail.contains(entry.roundNumber) { continue }
            var score = 0.0
            for t in usefulTerms where entry.docLower.contains(t.lower) {
                score += t.weight
            }
            if score > 0 {
                scored.append((entry, score))
            }
        }

        scored.sort { $0.score > $1.score }
        let threshold = totalCovered >= 30 ? 8.0 : 4.2
        let top = scored
            .filter { $0.score >= threshold }
            .prefix(2)
            .map(\.entry)
            .sorted { $0.roundNumber < $1.roundNumber }

        guard !top.isEmpty else { return nil }

        let snippets = top.map { entry in
            "[第 \(entry.roundNumber) 轮原始片段 · \(entry.spanTitle)]\n用户：\(extractFocusedSnippet(entry.userText, terms: queryTerms))\n助手：\(extractFocusedSnippet(entry.replyText, terms: queryTerms))"
        }

        var uniqueTitles: [String] = []
        var seenTitles = Set<String>()
        for entry in top where seenTitles.insert(entry.spanTitle).inserted {
            uniqueTitles.append(entry.spanTitle)
        }

        let blockText = "<recalled_memory note=\"以下仅是较早时间点的历史原文切片，仅供核对具体细节；人物当前关系与场景状态请严格以近期对话为准\">\n\(snippets.joined(separator: "\n\n"))\n</recalled_memory>"
        return RecalledMemoryResult(
            blockText: blockText,
            roundNumbers: top.map(\.roundNumber),
            spanTitles: uniqueTitles
        )
    }

    // MARK: - Span Mutation Helpers

    static func upsertSpan(_ span: CompactionSpan, into existing: [CompactionSpan]?) -> [CompactionSpan] {
        var list = existing ?? []
        if let idx = list.firstIndex(where: { $0.id == span.id }) {
            list[idx] = span
        } else {
            list.append(span)
        }
        return list
    }

    static func removeSpan(id spanId: UUID, from existing: [CompactionSpan]?) -> [CompactionSpan]? {
        guard var list = existing, !list.isEmpty else { return existing }
        list.removeAll { $0.id == spanId }
        return list.isEmpty ? nil : list
    }
}
