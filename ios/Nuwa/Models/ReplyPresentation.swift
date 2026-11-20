import Foundation

/// A display-only projection. Tool results may arrive after another call; pair by tool ID,
/// but keep the steps at the position of their calls, as in chat-demo's buildReplyView.
struct ReplyPresentation {
    enum Status { case active, done, failed }

    struct Search {
        let kind: String
        var queries: [String]
        var results: [WebSearchResultItem]
        var status: Status

        var deep: Bool { kind == "deep_search" || kind == "deep_image_search" }
        var images: Bool { kind == "image_search" || kind == "deep_image_search" }

        mutating func merge(_ other: Search) {
            queries += other.queries
            var seen = Set(results.map(\.url))
            results += other.results.filter { seen.insert($0.url).inserted }
            if status == .active || other.status == .active { status = .active }
            else if other.status == .done { status = .done }
        }
    }

    struct Page: Identifiable {
        let id: UUID
        let label: String
        let url: String?
        let status: Status
    }

    enum PageAction: String { case open = "open_page", find = "find_in_page", read = "read_link" }

    struct Step: Identifiable {
        enum Body {
            case thought(String), preamble(String), search(Search), pages(PageAction, [Page])
        }
        let id: UUID
        var body: Body
    }

    var steps: [Step] = []
    var answer = ""
    var citations: [TextCitation] = []
    var results: [WebSearchResultItem] = []
    var thinkingSeconds: Double?
    var hasDisclosure = false
    let isStreaming: Bool
    let stopped: Bool
    var processing: Bool { isStreaming && answer.isEmpty }

    init(_ message: ChatMessage) {
        isStreaming = message.isStreaming
        stopped = message.status == .stopped
        if message.stopReason == "refusal" { answer = message.fullTextContent; return }

        var responses: [String: ReplyBlock] = [:]
        for block in message.blocks {
            switch block {
            case .webSearchResult(_, let id, _, _, _), .webFetchResult(_, let id, _, _, _):
                responses[id] = block
            default: break
            }
        }
        results = message.allSearchResults

        var firstTextID: UUID?
        var hasStructuredText = false
        var hasThinking = false
        var duration: Double = 0
        var hasDuration = false
        var ordinarySearches: [String: Int] = [:]
        func flushPreamble() {
            if let firstTextID, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                steps.append(Step(id: firstTextID, body: .preamble(answer)))
            }
            firstTextID = nil
            answer = ""
            citations = []
        }

        for block in message.blocks {
            switch block {
            case .text(let id, let text, let references, let isTemplate):
                hasStructuredText = true
                guard !isTemplate else { continue }
                firstTextID = firstTextID ?? id
                answer += text
                citations += references
            case .thinking(let id, let text, _, let start, let end, let elapsed):
                hasThinking = true
                if let seconds = elapsed ?? start.flatMap({ start in end.map { $0.timeIntervalSince(start) } }) {
                    duration += seconds
                    hasDuration = true
                }
                guard !text.isEmpty else { continue }
                flushPreamble()
                if let last = steps.last, case .thought(let previous) = last.body {
                    steps[steps.count - 1].body = .thought(previous + text)
                } else {
                    steps.append(Step(id: id, body: .thought(text)))
                }
            case .serverToolUse(let id, let call):
                let response = responses[call.id]
                if call.action == "search" {
                    flushPreamble()
                    var items: [WebSearchResultItem] = []
                    var status: Status = isStreaming ? .active : .failed
                    if case .webSearchResult(_, _, _, let found, let error) = response {
                        var seen: Set<String> = []
                        items = found.filter { seen.insert($0.url).inserted }
                        status = error == nil ? .done : .failed
                    }
                    let group = Search(kind: call.kind, queries: call.queries, results: items, status: status)
                    let target = group.deep ? steps.indices.last : ordinarySearches[call.kind]
                    if let target, case .search(var existing) = steps[target].body, existing.kind == group.kind {
                        existing.merge(group)
                        steps[target].body = .search(existing)
                    } else {
                        if !group.deep { ordinarySearches[call.kind] = steps.count }
                        steps.append(Step(id: id, body: .search(group)))
                    }
                } else if let action = PageAction(rawValue: call.action) {
                    var url = call.url
                    var title: String?
                    var status: Status = isStreaming ? .active : .failed
                    if case .webFetchResult(_, _, _, let result, _) = response {
                        url = url ?? result.url
                        title = result.title
                        status = result.errorCode == nil ? .done : .failed
                    }
                    if action == .read && (url?.isEmpty != false || status != .active) { continue }
                    flushPreamble()
                    let page = Page(id: id, label: action == .find ? call.pattern ?? "" : title ?? url ?? "", url: url, status: status)
                    if let last = steps.last, case .pages(action, let pages) = last.body {
                        steps[steps.count - 1].body = .pages(action, pages + [page])
                    } else {
                        steps.append(Step(id: id, body: .pages(action, [page])))
                    }
                }
            case .webSearchResult, .webFetchResult: break
            }
        }

        if !hasStructuredText { answer = message.content }
        if !hasThinking, !message.reasoning.isEmpty {
            hasThinking = true
            steps.insert(Step(id: message.id, body: .thought(message.reasoning)), at: 0)
        }
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer = "" }
        hasDisclosure = (message.thinkingEnabled || hasThinking) && (!steps.isEmpty || processing)
        thinkingSeconds = hasDuration ? duration : message.thinkingSeconds
    }
}
