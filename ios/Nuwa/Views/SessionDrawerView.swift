import SwiftUI

struct SessionDrawerView: View {
    @ObservedObject var chatStore: ChatStore
    let onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSessions) { session in
                    Button {
                        chatStore.selectSession(session.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            if session.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.nuwaBrand)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                    .font(.body.weight(session.id == chatStore.activeSessionId ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.id == chatStore.activeSessionId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.nuwaBrand)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            chatStore.deleteSession(session.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            chatStore.togglePin(session.id)
                        } label: {
                            Label(session.isPinned ? "取消置顶" : "置顶", systemImage: session.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(Color.nuwaBrand)
                    }
                    .contextMenu {
                        Button {
                            chatStore.togglePin(session.id)
                        } label: {
                            Label(session.isPinned ? "取消置顶" : "置顶会话", systemImage: session.isPinned ? "pin.slash" : "pin")
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
                            Label("删除会话", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "搜索历史对话")
            .navigationTitle("历史会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onOpenSettings()
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        chatStore.createNewSession()
                        dismiss()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
