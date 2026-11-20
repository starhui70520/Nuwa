import SwiftUI
import UIKit

private struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionSummaryItem]
}

struct SessionDrawerView: View {
    @ObservedObject var listStore: SessionListStore
    @ObservedObject var settings: SettingsStore
    let activeSessionId: UUID?
    let isOpen: Bool
    let suppressSearchFocus: Bool
    let onSearchFocusChanged: (Bool) -> Void
    let onSelectSession: (UUID) -> Void
    let onCreateNewSession: () -> Void
    let onTogglePin: (UUID) -> Void
    let onSetSessionsPinned: (Set<UUID>, Bool) -> Void
    let onRenameSession: (UUID, String) -> Void
    let onDeleteSession: (UUID) -> Void
    let onDeleteSessions: (Set<UUID>) -> Void
    let onSearch: (String) async -> Set<UUID>
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nuwaFontScale) private var fontScale
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var searchResult: (query: String, ids: Set<UUID>)?
    @State private var selectMode = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    @State private var deletingSession: SessionSummaryItem?
    @State private var renamingSession: SessionSummaryItem?
    @State private var renameDraft = ""

    private static let selectImpact = UIImpactFeedbackGenerator(style: .light)
    private let topUpURL = URL(string: "https://platform.deepseek.com/top_up")!

    private var loc: AppLocale { settings.locale }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private struct SearchInput: Equatable {
        let query: String
        let summaries: [SessionSummaryItem]
    }

    private var groupedSessions: [SessionGroup] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let weekStart = calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        let monthStart = calendar.date(byAdding: .day, value: -30, to: todayStart) ?? todayStart
        var pinned: [SessionSummaryItem] = []
        var today: [SessionSummaryItem] = []
        var yesterday: [SessionSummaryItem] = []
        var last7Days: [SessionSummaryItem] = []
        var last30Days: [SessionSummaryItem] = []
        var earlier: [SessionSummaryItem] = []

        let matches = searchResult?.query == query ? searchResult?.ids : nil
        for s in listStore.summaries where query.isEmpty || matches?.contains(s.id) == true {
            if s.isPinned {
                pinned.append(s)
            } else if s.updatedAt >= todayStart {
                today.append(s)
            } else if s.updatedAt >= yesterdayStart {
                yesterday.append(s)
            } else if s.updatedAt >= weekStart {
                last7Days.append(s)
            } else if s.updatedAt >= monthStart {
                last30Days.append(s)
            } else {
                earlier.append(s)
            }
        }

        let isEn = loc == .enUS
        var groups: [SessionGroup] = []
        if !pinned.isEmpty { groups.append(SessionGroup(id: "pinned", title: isEn ? "Pinned" : "置顶", sessions: pinned)) }
        if !today.isEmpty { groups.append(SessionGroup(id: "today", title: isEn ? "Today" : "今天", sessions: today)) }
        if !yesterday.isEmpty { groups.append(SessionGroup(id: "yesterday", title: isEn ? "Yesterday" : "昨天", sessions: yesterday)) }
        if !last7Days.isEmpty { groups.append(SessionGroup(id: "7days", title: isEn ? "Last 7 Days" : "7 天内", sessions: last7Days)) }
        if !last30Days.isEmpty { groups.append(SessionGroup(id: "30days", title: isEn ? "Last 30 Days" : "30 天内", sessions: last30Days)) }
        if !earlier.isEmpty { groups.append(SessionGroup(id: "earlier", title: isEn ? "Earlier" : "更早", sessions: earlier)) }
        return groups
    }

    private var validSelectedIds: Set<UUID> {
        let existing = Set(listStore.summaries.map(\.id))
        return selectedIds.intersection(existing)
    }

    private var allSelectedPinned: Bool {
        guard !validSelectedIds.isEmpty else { return false }
        let byId = Dictionary(uniqueKeysWithValues: listStore.summaries.map { ($0.id, $0) })
        return validSelectedIds.allSatisfy { byId[$0]?.isPinned == true }
    }

    private func triggerLightHaptic() {
        guard UIDevice.current.userInterfaceIdiom == .phone && settings.hapticFeedbackEnabled else { return }
        Self.selectImpact.impactOccurred(intensity: 0.75)
    }

    private func dismissSearchFocus() {
        if isSearchFocused {
            isSearchFocused = false
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                window.endEditing(true)
            }
        }
    }

    var body: some View {
        let groups = groupedSessions
        let searchInput = SearchInput(query: isOpen ? query : "", summaries: isOpen && !query.isEmpty ? listStore.summaries : [])
        VStack(spacing: 0) {
            // Top Header: Multi-Select Header OR 44pt Search Pill (1:1 Android 0.1.31 mobile sider)
            if selectMode {
                HStack(spacing: 12) {
                    Text(loc == .enUS ? "\(validSelectedIds.count) selected" : "已选择 \(validSelectedIds.count) 个对话")
                        .font(NuwaFont.navTitle(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Spacer()
                    Button {
                        exitSelectMode()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .frame(width: 36, height: 36)
                            .nuwaGlass(in: Circle(), interactive: true)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("退出多选")
                }
                .frame(minHeight: max(44, 28 + 16 * fontScale))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(NuwaFont.sized(15.5, weight: .regular, scale: fontScale))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                    TextField(L10n.t("searchPlaceholder", locale: loc), text: $searchText)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            dismissSearchFocus()
                        }
                        .font(NuwaFont.control(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(maxWidth: .infinity, minHeight: max(44, 28 + 16 * fontScale))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.nuwaLabelTertiary)
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    if isSearchFocused {
                        Button {
                            dismissSearchFocus()
                        } label: {
                            Text(L10n.t("cancel", locale: loc))
                                .font(NuwaFont.captionMedium(fontScale))
                                .foregroundStyle(Color.nuwaBrandText)
                                .padding(.horizontal, 2)
                                .frame(minHeight: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: max(44, 28 + 16 * fontScale))
                .background {
                    Color.clear
                        .contentShape(Capsule())
                        .onTapGesture {
                            if !isSearchFocused && !suppressSearchFocus {
                                isSearchFocused = true
                            }
                        }
                }
                .nuwaGlass(
                    in: Capsule(),
                    tint: colorScheme == .dark ? .white.opacity(0.08) : nil,
                    interactive: false
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }

            // Session list / Empty state
            if listStore.summaries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text(L10n.t("emptyTitle", locale: loc))
                        .font(NuwaFont.bodyMedium(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Text(L10n.t("emptySubtitle", locale: loc))
                        .font(NuwaFont.sublabel(fontScale))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                        .multilineTextAlignment(.center)
                    Button {
                        dismissSearchFocus()
                        onCreateNewSession()
                        onClose()
                    } label: {
                        Text(L10n.t("newChat", locale: loc))
                            .font(NuwaFont.pill(fontScale))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .frame(minHeight: max(40, 26 + 14 * fontScale))
                            .background(Color.nuwaBrand, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(NuwaTactileButtonStyle())
                    .padding(.top, 6)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissSearchFocus()
                }
            } else if groups.isEmpty {
                VStack {
                    Spacer()
                    if !query.isEmpty && searchResult?.query != query {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.t("emptySearch", locale: loc))
                            .font(NuwaFont.sublabel(fontScale))
                            .foregroundStyle(Color.nuwaLabelTertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissSearchFocus()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { groupIdx, group in
                            HStack(alignment: .center) {
                                Text(group.title)
                                    .font(NuwaFont.sectionHeader(fontScale))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                Spacer()
                                if groupIdx == 0 && !selectMode {
                                    Button {
                                        dismissSearchFocus()
                                        triggerLightHaptic()
                                        enterSelectMode(initialId: nil)
                                    } label: {
                                        MultiSelectGlyph()
                                            .foregroundStyle(Color.nuwaLabelTertiary)
                                            .frame(width: 32, height: 28)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.92))
                                    .accessibilityLabel(L10n.t("multiSelect", locale: loc))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, groupIdx == 0 ? 4 : 20)
                            .padding(.bottom, 6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSearchFocused {
                                    dismissSearchFocus()
                                }
                            }

                            ForEach(group.sessions) { session in
                                sessionRow(session)
                            }
                        }

                        Color.clear
                            .frame(height: isSearchFocused ? 420 : 12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSearchFocused {
                                    dismissSearchFocus()
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .nuwaNoScrollEdgeEffect()
            }

            // Bottom bar: Clean flat multi-select bar OR Borderless Android 0.1.31 profile row
            if selectMode {
                HStack(spacing: 0) {
                    Button {
                        onSetSessionsPinned(validSelectedIds, !allSelectedPinned)
                        exitSelectMode()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: allSelectedPinned ? "pin.slash" : "pin")
                                .font(NuwaFont.sized(15, weight: .medium, scale: fontScale))
                            Text(L10n.t(allSelectedPinned ? "unpin" : "pin", locale: loc))
                                .font(NuwaFont.controlMedium(fontScale))
                        }
                        .foregroundStyle(validSelectedIds.isEmpty ? Color.nuwaLabelTertiary : Color.nuwaLabelPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NuwaTactileButtonStyle())
                    .disabled(validSelectedIds.isEmpty)

                    Rectangle()
                        .fill(Color.nuwaControlBorder)
                        .frame(width: 0.75, height: 18)

                    Button {
                        showBatchDeleteConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(NuwaFont.sized(15, weight: .medium, scale: fontScale))
                            Text(L10n.t("delete", locale: loc))
                                .font(NuwaFont.controlMedium(fontScale))
                        }
                        .foregroundStyle(validSelectedIds.isEmpty ? Color.nuwaLabelTertiary : .red)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NuwaTactileButtonStyle())
                    .disabled(validSelectedIds.isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
            } else {
                HStack(spacing: 8) {
                    Button {
                        dismissSearchFocus()
                        onOpenSettings()
                    } label: {
                        HStack(spacing: 10) {
                            Image("NuwaLogo")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(Circle())

                            Text(settings.profileDisplayName)
                                .font(NuwaFont.sized(15.5, weight: .medium, scale: fontScale))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(minHeight: 50, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.98))
                    .layoutPriority(1)

                    if let balance = settings.deepSeekBalanceText {
                        Button {
                            dismissSearchFocus()
                            openURL(topUpURL)
                        } label: {
                            Text(balance)
                                .font(NuwaFont.badge(fontScale).monospacedDigit())
                                .foregroundStyle(settings.isBalanceLow ? .red : Color.nuwaBrandText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (settings.isBalanceLow ? Color.red : Color.nuwaBrand).opacity(0.14),
                                    in: Capsule()
                                )
                                .lineLimit(1)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.95))
                        .fixedSize()
                        .layoutPriority(2)
                        .accessibilityLabel(L10n.t("topUp", locale: loc))
                    }

                    Button {
                        dismissSearchFocus()
                        onOpenSettings()
                    } label: {
                        HStack(spacing: 0) {
                            Spacer(minLength: 4)
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.nuwaLabelTertiary)
                                .fixedSize()
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.98))
                    .layoutPriority(-1)
                    .accessibilityLabel(L10n.t("settings", locale: loc))
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        }
        .task(id: searchInput) {
            guard isOpen else { return }
            guard !searchInput.query.isEmpty else {
                searchResult = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let ids = await onSearch(searchInput.query)
            if !Task.isCancelled { searchResult = (searchInput.query, ids) }
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused && suppressSearchFocus {
                dismissSearchFocus()
                onSearchFocusChanged(false)
            } else {
                onSearchFocusChanged(focused)
            }
        }
        .onChange(of: suppressSearchFocus) { _, suppressed in
            if suppressed {
                dismissSearchFocus()
            }
        }
        .onChange(of: isOpen) { _, open in
            if open {
                Task { await settings.refreshBalance() }
            } else {
                dismissSearchFocus()
                exitSelectMode()
            }
        }
        .alert(L10n.t("rename", locale: loc), isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField(L10n.t("untitledChat", locale: loc), text: $renameDraft)
            Button(L10n.t("cancel", locale: loc), role: .cancel) { renamingSession = nil }
            Button(L10n.t("confirm", locale: loc)) {
                if let target = renamingSession {
                    onRenameSession(target.id, renameDraft)
                }
                renamingSession = nil
            }
        }
        .alert("永久删除对话", isPresented: Binding(
            get: { deletingSession != nil },
            set: { if !$0 { deletingSession = nil } }
        )) {
            Button(L10n.t("cancel", locale: loc), role: .cancel) { deletingSession = nil }
            Button(L10n.t("delete", locale: loc), role: .destructive) {
                if let target = deletingSession {
                    onDeleteSession(target.id)
                }
                deletingSession = nil
            }
        } message: {
            Text("删除后，该对话将不可恢复。确认删除吗？")
        }
        .alert("删除选中的 \(validSelectedIds.count) 个对话", isPresented: $showBatchDeleteConfirm) {
            Button(L10n.t("cancel", locale: loc), role: .cancel) {}
            Button(L10n.t("delete", locale: loc), role: .destructive) {
                onDeleteSessions(validSelectedIds)
                exitSelectMode()
            }
        } message: {
            Text("删除后，选中的对话将不可恢复。确认删除吗？")
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSummaryItem) -> some View {
        let isActive = !selectMode && session.id == activeSessionId
        let isSelected = selectedIds.contains(session.id)

        HStack(spacing: 10) {
            if selectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.nuwaBrand : Color.nuwaLabelTertiary)
            } else if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.nuwaBrandText)
            }

            Text(session.title.isEmpty ? L10n.t("untitledChat", locale: loc) : session.title)
                .font(isActive ? NuwaFont.rowTitleMedium(fontScale) : NuwaFont.rowTitle(fontScale))
                .foregroundStyle(isActive ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isActive && !selectMode {
                Menu {
                    sessionMenuItems(for: session)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.nuwaBrandText.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, isActive && !selectMode ? 8 : 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: max(46, 30 + 16 * fontScale), alignment: .leading)
        .background(
            isActive ? Color.nuwaSidebarActive : (selectMode && isSelected ? Color.nuwaSidebarActive.opacity(0.65) : Color.clear),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            dismissSearchFocus()
            if selectMode {
                toggleSelected(session.id)
            } else {
                onSelectSession(session.id)
                onClose()
            }
        }
        .contextMenu {
            if !selectMode {
                sessionMenuItems(for: session)
            }
        }
    }

    @ViewBuilder
    private func sessionMenuItems(for session: SessionSummaryItem) -> some View {
        Button {
            onTogglePin(session.id)
        } label: {
            Label(L10n.t(session.isPinned ? "unpin" : "pin", locale: loc), systemImage: session.isPinned ? "pin.slash" : "pin")
        }
        Button {
            enterSelectMode(initialId: session.id)
        } label: {
            Label(L10n.t("multiSelect", locale: loc), systemImage: "checkmark.circle")
        }
        Button {
            renameDraft = session.title
            renamingSession = session
        } label: {
            Label(L10n.t("rename", locale: loc), systemImage: "pencil")
        }
        Button(role: .destructive) {
            deletingSession = session
        } label: {
            Label(L10n.t("delete", locale: loc), systemImage: "trash")
        }
    }

    private func enterSelectMode(initialId: UUID?) {
        dismissSearchFocus()
        withAnimation(.easeInOut(duration: 0.16)) {
            selectMode = true
            selectedIds = initialId.map { [$0] } ?? []
        }
    }

    private func exitSelectMode() {
        withAnimation(.easeInOut(duration: 0.16)) {
            selectMode = false
            selectedIds.removeAll()
        }
    }

    private func toggleSelected(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }
}

/// Crisp two-row multi-select bullet glyph matching the Android 0.1.31 sidebar header icon.
private struct MultiSelectGlyph: View {
    var body: some View {
        VStack(spacing: 4.5) {
            HStack(spacing: 3.5) {
                Circle().strokeBorder(lineWidth: 1.4).frame(width: 6, height: 6)
                Capsule().frame(width: 8, height: 1.5)
            }
            HStack(spacing: 3.5) {
                Circle().strokeBorder(lineWidth: 1.4).frame(width: 6, height: 6)
                Capsule().frame(width: 8, height: 1.5)
            }
        }
    }
}
