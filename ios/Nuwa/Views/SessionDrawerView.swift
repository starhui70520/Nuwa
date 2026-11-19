import SwiftUI

private struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [ChatSession]
}

/// Exact 1:1 recreation of chat-demo/src/components/sider/Sider.tsx
/// rendered inside the left push-drawer on mobile.
struct SessionDrawerView: View {
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var settings: SettingsStore
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @State private var searchText = ""
    @State private var renamingSession: ChatSession?
    @State private var renameDraft = ""

    private var filteredSessions: [ChatSession] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chatStore.sortedSessions }
        return chatStore.sortedSessions.filter { session in
            session.title.lowercased().contains(q) ||
            session.messages.contains { $0.content.lowercased().contains(q) }
        }
    }

    private var groupedSessions: [SessionGroup] {
        let calendar = Calendar.current
        let now = Date()
        var pinned: [ChatSession] = []
        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var last7Days: [ChatSession] = []
        var earlier: [ChatSession] = []

        for s in filteredSessions {
            if s.isPinned {
                pinned.append(s)
            } else if calendar.isDateInToday(s.updatedAt) {
                today.append(s)
            } else if calendar.isDateInYesterday(s.updatedAt) {
                yesterday.append(s)
            } else if let diff = calendar.dateComponents([.day], from: s.updatedAt, to: now).day, diff <= 7 {
                last7Days.append(s)
            } else {
                earlier.append(s)
            }
        }

        var groups: [SessionGroup] = []
        if !pinned.isEmpty { groups.append(SessionGroup(id: "pinned", title: "置顶", sessions: pinned)) }
        if !today.isEmpty { groups.append(SessionGroup(id: "today", title: "今天", sessions: today)) }
        if !yesterday.isEmpty { groups.append(SessionGroup(id: "yesterday", title: "昨天", sessions: yesterday)) }
        if !last7Days.isEmpty { groups.append(SessionGroup(id: "7days", title: "7 天内", sessions: last7Days)) }
        if !earlier.isEmpty { groups.append(SessionGroup(id: "earlier", title: "更早", sessions: earlier)) }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top search bar (matching Sider.tsx)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                    TextField("搜索历史对话", text: $searchText)
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

                Button {
                    chatStore.createNewSession()
                    onClose()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(width: 36, height: 36)
                        .nuwaGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("开启新对话")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Time-grouped session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groupedSessions) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.nuwaLabelTertiary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 2)

                            ForEach(group.sessions) { session in
                                let isActive = session.id == chatStore.activeSessionId
                                Button {
                                    chatStore.selectSession(session.id)
                                    onClose()
                                } label: {
                                    HStack(spacing: 8) {
                                        if session.isPinned {
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color.nuwaBrandText)
                                        }
                                        Text(session.title)
                                            .font(.system(size: 14, weight: isActive ? .medium : .regular))
                                            .foregroundStyle(Color.nuwaLabelPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        isActive ? Color.nuwaSidebarActive : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        chatStore.togglePin(session.id)
                                    } label: {
                                        Label(session.isPinned ? "取消置顶" : "置顶", systemImage: session.isPinned ? "pin.slash" : "pin")
                                    }
                                    Button {
                                        renameDraft = session.title
                                        renamingSession = session
                                    } label: {
                                        Label("重命名", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        chatStore.deleteSession(session.id)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            // Bottom account & settings card (matching Sider.tsx footer)
            Button {
                onClose()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    onOpenSettings()
                }
            } label: {
                HStack(spacing: 10) {
                    Image("NuwaLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.isConfigured ? settings.effectiveModel : "未配置 API")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .lineLimit(1)
                        Text(settings.deepSeekBalanceText ?? (settings.isConfigured ? "点击管理 API 与设置" : "点击配置 API Key"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.nuwaLabelTertiary)
                            .lineLimit(1)
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
        .background(Color.nuwaSidebarFill.ignoresSafeArea())
        .alert("重命名会话", isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField("会话标题", text: $renameDraft)
            Button("取消", role: .cancel) { renamingSession = nil }
            Button("保存") {
                if let target = renamingSession {
                    chatStore.renameSession(target.id, title: renameDraft)
                }
                renamingSession = nil
            }
        }
    }
}
