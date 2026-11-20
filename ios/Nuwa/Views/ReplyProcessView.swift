import SwiftUI

struct ReplyProcessView: View {
    let reply: ReplyPresentation
    let fontSize: Double
    let locale: AppLocale
    let showResults: ([WebSearchResultItem]) -> Void
    let onCopyCode: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var manuallyExpanded: Bool?

    private var expanded: Bool { manuallyExpanded ?? reply.processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if reply.hasDisclosure {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        manuallyExpanded = !expanded
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "atom")
                            .foregroundStyle(reply.stopped ? Color.nuwaLabelTertiary : .nuwaBrandText)
                        ActivityText(title: title, active: reply.processing)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(.system(size: fontSize))
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? (locale == .enUS ? "Expanded" : "已展开") : (locale == .enUS ? "Collapsed" : "已收起"))
            }
            if !reply.hasDisclosure || expanded {
                ForEach(reply.steps) { step in
                    stepRow(step)
                        .overlay(alignment: .topLeading) {
                            if step.id != reply.steps.last?.id {
                                Rectangle().fill(Color.nuwaControlBorder)
                                    .frame(width: 1).padding(.leading, 7.5).padding(.top, 25)
                                    .accessibilityHidden(true)
                            }
                        }
                }
            }
        }
        .onChange(of: reply.processing) { _, _ in manuallyExpanded = nil }
    }

    private var title: String {
        if !reply.processing {
            if reply.answer.isEmpty { return L10n.t("messageThinkStopped", locale: locale) }
            guard let seconds = reply.thinkingSeconds, seconds.isFinite, seconds < Double(Int.max) else {
                return L10n.t("thinking", locale: locale)
            }
            return L10n.count(Int(max(1, seconds.rounded())), singular: "messageThinkDuration", plural: "messageThinkDurationPlural", locale: locale)
        }
        switch reply.steps.last?.body {
        case .search(let search) where search.status == .active:
            return L10n.t(search.images ? "imageSearching" : "searchingNow", locale: locale)
        case .pages(_, let pages) where pages.contains(where: { $0.status == .active }):
            return L10n.t("readingLink", locale: locale)
        default:
            return L10n.t("thinkingNow", locale: locale)
        }
    }

    @ViewBuilder
    private func stepRow(_ step: ReplyPresentation.Step) -> some View {
        switch step.body {
        case .thought(let text), .preamble(let text):
            let active = reply.processing && step.id == reply.steps.last?.id
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(active ? Color.nuwaBrandText : .nuwaLabelTertiary)
                    .frame(width: 5, height: 5).frame(width: 16, height: 21)
                MarkdownMessageView(text: text, fontSize: max(12, fontSize - 2), isStreaming: active, onCopyCode: onCopyCode)
                    .equatable()
            }
            .padding(.vertical, 4)
        case .search(let search):
            SearchStepRow(search: search, stopped: reply.stopped, locale: locale, showResults: showResults)
        case .pages(let action, let pages):
            PageStepRow(action: action, pages: pages, locale: locale, showResults: showResults)
        }
    }
}

private struct ActivityText: View {
    let title: String
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(title)
            .foregroundStyle(Color.nuwaLabelSecondary)
            .overlay {
                if active && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 24)) { tick in
                        let phase = tick.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                        LinearGradient(colors: [.clear, .nuwaLabelPrimary, .clear],
                                       startPoint: UnitPoint(x: phase * 2 - 0.65, y: 0.5),
                                       endPoint: UnitPoint(x: phase * 2, y: 0.5))
                    }
                    .mask(Text(title))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

private struct SearchStepRow: View {
    let search: ReplyPresentation.Search
    let stopped: Bool
    let locale: AppLocale
    let showResults: ([WebSearchResultItem]) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: search.status == .failed ? "exclamationmark.triangle" : "magnifyingglass")
                .frame(width: 16)
            switch search.status {
            case .active:
                ActiveSearchQuery(queries: search.queries, images: search.images, locale: locale)
            case .failed:
                Text(L10n.t(stopped ? "searchStopped" : "toolSearchFail", locale: locale))
            case .done where search.results.isEmpty:
                Text(L10n.t(search.deep ? "toolSearchNoResult" : "messageSearchNoResult", locale: locale))
            case .done:
                Button {
                    showResults(search.results)
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.count(search.results.count,
                                        singular: search.deep ? "toolSearch1Result" : "messageSearchResult",
                                        plural: search.deep ? "toolSearchResults" : "messageSearchResults", locale: locale))
                        SourceThumbnails(items: search.results)
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color.nuwaLabelSecondary)
        .frame(minHeight: 34)
    }
}

private struct ActiveSearchQuery: View {
    let queries: [String]
    let images: Bool
    let locale: AppLocale
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if queries.isEmpty {
            ActivityText(title: L10n.t(images ? "imageSearching" : "messageSearching", locale: locale), active: true)
        } else {
            HStack(spacing: 6) {
                Text(L10n.t("toolSearchIntro", locale: locale)).fixedSize()
                Text(queries[index % queries.count]).lineLimit(1)
                    .id(index)
                    .transition(.opacity)
            }
            .task(id: queries) {
                index = 0
                guard queries.count > 1 else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    withAnimation(reduceMotion ? nil : .easeIn(duration: 0.22)) {
                        index = (index + 1) % queries.count
                    }
                }
            }
        }
    }
}

private struct PageStepRow: View {
    let action: ReplyPresentation.PageAction
    let pages: [ReplyPresentation.Page]
    let locale: AppLocale
    let showResults: ([WebSearchResultItem]) -> Void

    private var label: String {
        switch action {
        case .open:
            if pages.allSatisfy({ $0.status == .failed }) { return L10n.t("toolOpenFail", locale: locale) }
            return L10n.count(pages.count, singular: "toolOpenOneIntro", plural: "toolOpensIntro", locale: locale)
        case .find: return L10n.t(pages.allSatisfy { $0.status == .failed } ? "toolFindFail" : "toolFindIntro", locale: locale)
        case .read: return locale == .enUS ? "Reading" : "正在阅读"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: action == .find ? "text.magnifyingglass" : action == .read ? "link" : "globe")
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                ActivityText(title: label, active: action == .read)
                ForEach(action == .open ? Array(pages.prefix(5)) : pages) { page in
                    if !page.label.isEmpty {
                        if action != .find, page.status != .failed, let url = webURL(page.url) {
                            Link(destination: url) {
                                Label(page.label, systemImage: "arrow.up.right").lineLimit(1)
                            }
                        } else {
                            Text(page.label).lineLimit(1)
                        }
                    }
                }
                if action == .open && pages.count > 5 {
                    Button(L10n.t("toolOpenViewAll", locale: locale)) {
                        var seen = Set<String>()
                        showResults(pages.compactMap { page in
                            guard let url = page.url, seen.insert(url).inserted else { return nil }
                            return WebSearchResultItem(url: url, title: page.label, snippet: nil, siteName: nil, siteIcon: nil, pageAge: nil)
                        })
                    }
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color.nuwaLabelSecondary)
        .padding(.vertical, 5)
    }
}

private func webURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
          ["https", "http"].contains(scheme), url.host != nil else { return nil }
    return url
}

private struct SourceLogo: View {
    let item: WebSearchResultItem
    var body: some View {
        AsyncImage(url: webURL(item.siteIcon)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "link").font(.system(size: 10)).foregroundStyle(Color.nuwaLabelTertiary)
            }
        }
        .frame(width: 16, height: 16)
        .background(Color(.tertiarySystemFill), in: Circle())
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.nuwaChatBackground, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

private struct SourceThumbnails: View {
    let items: [WebSearchResultItem]
    var body: some View {
        HStack(spacing: -4) {
            ForEach(items.prefix(4)) { SourceLogo(item: $0) }
        }
    }
}

struct SearchSourcesButton: View {
    let items: [WebSearchResultItem]
    let locale: AppLocale
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SourceThumbnails(items: items)
                Text(L10n.count(items.count, singular: "messageSearchSummary", plural: "messageSearchSummaries", locale: locale))
            }
            .font(.footnote)
            .foregroundStyle(Color.nuwaLabelSecondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SearchSourcesPanel: View {
    let items: [WebSearchResultItem]
    let locale: AppLocale
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("searchResults", locale: locale)).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.t("close", locale: locale))
            }
            .padding(.leading, 20).padding(.trailing, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if let url = webURL(item.url) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        Text("\(index + 1)").monospacedDigit()
                                        SourceLogo(item: item)
                                        Text(item.siteName ?? url.host() ?? "").lineLimit(1)
                                        if let age = item.pageAge, !age.isEmpty {
                                            Text("·").accessibilityHidden(true)
                                            Text(age).lineLimit(1)
                                        }
                                    }
                                    .font(.caption).foregroundStyle(Color.nuwaLabelTertiary)
                                    Text(item.title.isEmpty ? item.url : item.title)
                                        .font(.subheadline.weight(.medium)).lineLimit(2)
                                    if let snippet = item.snippet, !snippet.isEmpty {
                                        Text(snippet).font(.footnote).foregroundStyle(Color.nuwaLabelSecondary).lineLimit(3)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.nuwaLabelPrimary)
        .background(Color.nuwaChatBackground.ignoresSafeArea())
        .accessibilityAction(.escape, dismiss)
    }
}
