import SwiftUI

private struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [ChatSession]
}

/// Exact 1:1 recreation of chat-demo/src/components/sider/Sider.tsx + SessionItem.tsx
/// including multi-select batch pin/delete, time-grouped list, bilingual labels,
/// low-balance highlight, empty state, and direct settings opening (without jumping back to chat first!).
struct SessionDrawerView: View {
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var settings: SettingsStore
    let isOpen: Bool
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var searchText = ""
    @State private var selectMode = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    @State private var deletingSession: ChatSession?
    @State private var renamingSession: ChatSession?
    @State private var renameDraft = ""

    private let topUpURL = URL(string: "https://platform.deepseek.com/top_up")!

    private var loc: AppLocale { settings.locale }

    private var filteredSessions: [ChatSession] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chatStore.sortedSessions }
        return chatStore.sortedSessions.filter { session in
            session.title.lowercased().contains(q) ||
            session.messages.contains { $0.fullTextContent.lowercased().contains(q) }
        }
    }

    private var groupedSessions: [SessionGroup] {
        let calendar = Calendar.current
        let now = Date()
        var pinned: [ChatSession] = []
        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var last7Days: [ChatSession] = []
        var last30Days: [ChatSession] = []
        var earlier: [ChatSession] = []

        for s in filteredSessions {
            if s.isPinned {
                pinned.append(s)
            } else if calendar.isDateInToday(s.updatedAt) {
                today.append(s)
            } else if calendar.isDateInYesterday(s.updatedAt) {
                yesterday.append(s)
            } else if let diff = calendar.dateComponents([.day], from: s.updatedAt, to: now).day {
                if diff <= 7 {
                    last7Days.append(s)
                } else if diff <= 30 {
                    last30Days.append(s)
                } else {
                    earlier.append(s)
                }
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
        let existing = Set(chatStore.sessions.map(\.id))
        return selectedIds.intersection(existing)
    }

    private var allSelectedPinned: Bool {
        guard !validSelectedIds.isEmpty else { return false }
        let byId = Dictionary(uniqueKeysWithValues: chatStore.sessions.map { ($0.id, $0) })
        return validSelectedIds.allSatisfy { byId[$0]?.isPinned == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Header: Select Mode header OR Search bar (matching Sider.tsx)
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
                            .nuwaGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
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
                .nuwaGlass(in: Capsule(), interactive: false)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }

            // Session list / Empty state
            if chatStore.sessions.isEmpty {
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
                        chatStore.createNewSession(silentIfAlreadyNew: true)
                        onClose()
                    } label: {
                        Text(L10n.t("newChat", locale: loc))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .nuwaGlass(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if filteredSessions.isEmpty {
                VStack {
                    Spacer()
                    Text(L10n.t("emptySearch", locale: loc))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groupedSessions) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 2)

                                ForEach(group.sessions) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }

            // Bottom bar: Batch select bar OR Account/Settings button (matching Sider.tsx lines 324-387)
            if selectMode {
                HStack(spacing: 0) {
                    Button {
                        chatStore.setSessionsPinned(validSelectedIds, pinned: !allSelectedPinned)
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
                    .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
                    .disabled(validSelectedIds.isEmpty)
                }
                .nuwaGlassCard(cornerRadius: 16, interactive: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                // Direct Settings trigger — does NOT close drawer back to chat first!
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
                                    .onTapGesture { openURL(topUpURL) }
                            }
                        }

                        Spacer()

                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .nuwaGlassCard(cornerRadius: 16, interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color.nuwaSidebarFill.ignoresSafeArea())
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
                    chatStore.renameSession(target.id, title: renameDraft)
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
                    chatStore.deleteSession(target.id)
                }
                deletingSession = nil
            }
        } message: {
            Text("删除后，该对话将不可恢复。确认删除吗？")
        }
        .alert("删除选中的 \(validSelectedIds.count) 个对话", isPresented: $showBatchDeleteConfirm) {
            Button(L10n.t("cancel", locale: loc), role: .cancel) {}
            Button(L10n.t("delete", locale: loc), role: .destructive) {
                chatStore.deleteSessions(validSelectedIds)
                exitSelectMode()
            }
        } message: {
            Text("删除后，选中的对话将不可恢复。确认删除吗？")
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: ChatSession) -> some View {
        let isActive = !selectMode && session.id == chatStore.activeSessionId
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
                chatStore.selectSession(session.id)
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
                    chatStore.togglePin(session.id)
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
        withAnimation(.easeInOut(duration: 0.18)) {
            selectMode = true
            selectedIds = [initialId]
        }
    }

    private func exitSelectMode() {
        withAnimation(.easeInOut(duration: 0.18)) {
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
