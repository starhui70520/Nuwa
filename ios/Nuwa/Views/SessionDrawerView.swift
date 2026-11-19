import SwiftUI

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

    @State private var searchText = ""
    @State private var searchResult: (query: String, ids: Set<UUID>)?
    @State private var selectMode = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    @State private var deletingSession: SessionSummaryItem?
    @State private var renamingSession: SessionSummaryItem?
    @State private var renameDraft = ""

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

    var body: some View {
        let groups = isOpen ? groupedSessions : []
        let searchInput = SearchInput(query: isOpen ? query : "", summaries: isOpen && !query.isEmpty ? listStore.summaries : [])
        VStack(spacing: 0) {
            // Top Header: Select Mode header OR Search bar (clean uniform background, zero edge-tint artifact)
            if selectMode {
                HStack {
                    Text(loc == .enUS ? "\(validSelectedIds.count) selected" : "已选择 \(validSelectedIds.count) 个对话")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Spacer()
                    Button {
                        exitSelectMode()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .frame(width: 32, height: 32)
                            .background(Color.nuwaControlFill, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(NuwaTactileButtonStyle())
                    .accessibilityLabel("退出多选")
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                    TextField(L10n.t("searchPlaceholder", locale: loc), text: $searchText)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.nuwaLabelTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.nuwaDrawerCardFill, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }

            // Session list / Empty state
            if listStore.summaries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text(L10n.t("emptyTitle", locale: loc))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Text(L10n.t("emptySubtitle", locale: loc))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                        .multilineTextAlignment(.center)
                    Button {
                        onCreateNewSession()
                        onClose()
                    } label: {
                        Text(L10n.t("newChat", locale: loc))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .nuwaPillSurface()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(NuwaTactileButtonStyle())
                    .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if groups.isEmpty {
                VStack {
                    Spacer()
                    if !query.isEmpty && searchResult?.query != query {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.t("emptySearch", locale: loc))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.nuwaLabelTertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    sessionRow(session)
                                }
                            } header: {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .nuwaNoScrollEdgeEffect()
            }

            // Bottom bar: Batch select bar OR Direct Settings Card (100% responsive full-width hit target!)
            if selectMode {
                HStack(spacing: 0) {
                    Button {
                        onSetSessionsPinned(validSelectedIds, !allSelectedPinned)
                        exitSelectMode()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: allSelectedPinned ? "pin.slash" : "pin")
                                .font(.system(size: 14, weight: .medium))
                            Text(L10n.t(allSelectedPinned ? "unpin" : "pin", locale: loc))
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(validSelectedIds.isEmpty ? Color.nuwaLabelTertiary : Color.nuwaLabelPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NuwaTactileButtonStyle())
                    .disabled(validSelectedIds.isEmpty)

                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 0.75, height: 22)

                    Button {
                        showBatchDeleteConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .medium))
                            Text(L10n.t("delete", locale: loc))
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(validSelectedIds.isEmpty ? Color.nuwaLabelTertiary : .red)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NuwaTactileButtonStyle())
                    .disabled(validSelectedIds.isEmpty)
                }
                .background(Color.nuwaDrawerCardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: 10) {
                        Image("NuwaLogo")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.profileDisplayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .lineLimit(1)
                            if let balance = settings.deepSeekBalanceText {
                                Text(balance)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(settings.isBalanceLow ? .red : Color.nuwaBrandText)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.nuwaDrawerCardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.97))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .task(id: searchInput) {
            guard !searchInput.query.isEmpty else {
                searchResult = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let ids = await onSearch(searchInput.query)
            if !Task.isCancelled { searchResult = (searchInput.query, ids) }
        }
        .onChange(of: isOpen) { _, open in
            if open {
                Task { await settings.refreshBalance() }
            } else {
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
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.nuwaBrand : Color.nuwaLabelTertiary)
            } else if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.nuwaBrandText)
            }

            Text(session.title.isEmpty ? L10n.t("untitledChat", locale: loc) : session.title)
                .font(.system(size: 14, weight: isActive ? .medium : .regular))
                .foregroundStyle(Color.nuwaLabelPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isActive ? Color.nuwaSidebarActive : (selectMode && isSelected ? Color.nuwaSidebarActive.opacity(0.6) : Color.clear),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selectMode {
                toggleSelected(session.id)
            } else {
                onSelectSession(session.id)
                onClose()
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            if !selectMode {
                enterSelectMode(initialId: session.id)
            }
        }
        .contextMenu {
            if !selectMode {
                Button {
                    enterSelectMode(initialId: session.id)
                } label: {
                    Label(L10n.t("multiSelect", locale: loc), systemImage: "checkmark.circle")
                }
                Button {
                    onTogglePin(session.id)
                } label: {
                    Label(L10n.t(session.isPinned ? "unpin" : "pin", locale: loc), systemImage: session.isPinned ? "pin.slash" : "pin")
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
        }
    }

    private func enterSelectMode(initialId: UUID) {
        withAnimation(.easeInOut(duration: 0.16)) {
            selectMode = true
            selectedIds = [initialId]
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
