import Foundation
import SwiftUI

/// Isolated per-session draft store so typing in the composer NEVER invalidates
/// ChatView, MessageList, or SessionDrawerView (zero keystroke frame drops!).
@MainActor
final class DraftStore: ObservableObject {
    @Published var drafts: [String: DraftEntry] = [:]

    private func key(for sessionId: UUID?) -> String {
        sessionId?.uuidString ?? "new"
    }

    func draft(for sessionId: UUID?) -> DraftEntry {
        drafts[key(for: sessionId)] ?? DraftEntry()
    }

    func setText(_ text: String, for sessionId: UUID?) {
        let k = key(for: sessionId)
        var entry = drafts[k] ?? DraftEntry()
        if entry.text == text { return }
        entry.text = text
        drafts[k] = entry
    }

    func canSend(for sessionId: UUID?, isBusy: Bool) -> Bool {
        guard !isBusy else { return false }
        let d = draft(for: sessionId)
        let hasText = !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFiles = !d.attachments.isEmpty
        guard hasText || hasFiles else { return false }
        return d.attachments.allSatisfy { $0.status == .done }
    }

    func consumeDraft(for sessionId: UUID?) -> DraftEntry {
        let k = key(for: sessionId)
        let current = drafts[k] ?? DraftEntry()
        drafts[k] = DraftEntry()
        return current
    }

    func removeDraft(for sessionId: UUID?) {
        drafts.removeValue(forKey: key(for: sessionId))
    }

    func clearAll() {
        drafts.removeAll()
    }

    func addFile(
        data: Data,
        fileName: String,
        isImage: Bool,
        for sessionId: UUID?,
        settings: SettingsStore,
        onToast: @escaping (String) -> Void
    ) {
        let k = key(for: sessionId)
        var entry = drafts[k] ?? DraftEntry()
        guard entry.attachments.count < AttachmentStore.maxCount else {
            onToast("上传文件最多支持 \(AttachmentStore.maxCount) 个")
            return
        }
        let maxMB = AttachmentStore.uploadPurpose(fileName: fileName, isImage: isImage) == "user_data"
            ? AttachmentStore.maxUserDataSizeMB
            : AttachmentStore.maxSizeMB
        guard data.count <= maxMB * 1024 * 1024 else {
            onToast("单个文件大小超过限制（\(maxMB)MB）")
            return
        }

        Task.detached(priority: .userInitiated) {
            do {
                let (file, normalizedData) = try AttachmentStore.saveLocally(data: data, originalName: fileName, isImage: isImage)
                await MainActor.run {
                    var current = self.drafts[k] ?? DraftEntry()
                    current.attachments.append(DraftAttachment(id: file.id, file: file, status: .uploading))
                    self.drafts[k] = current
                    self.uploadAttachment(fileId: file.id, data: normalizedData, file: file, draftKey: k, settings: settings, onToast: onToast)
                }
            } catch {
                await MainActor.run {
                    AppLogStore.shared.record(.error, source: "attachment.save", message: error.localizedDescription)
                    onToast("读取附件失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func retryAttachment(
        fileId: String,
        for sessionId: UUID?,
        settings: SettingsStore,
        onToast: @escaping (String) -> Void
    ) {
        let k = key(for: sessionId)
        guard var entry = drafts[k],
              let idx = entry.attachments.firstIndex(where: { $0.id == fileId })
        else { return }
        let file = entry.attachments[idx].file
        guard let url = AttachmentStore.localURL(for: file),
              let data = try? Data(contentsOf: url)
        else { return }
        entry.attachments[idx].status = .uploading
        drafts[k] = entry
        uploadAttachment(fileId: fileId, data: data, file: file, draftKey: k, settings: settings, onToast: onToast)
    }

    func removeAttachment(fileId: String, for sessionId: UUID?) {
        let k = key(for: sessionId)
        guard var entry = drafts[k] else { return }
        entry.attachments.removeAll { $0.id == fileId }
        drafts[k] = entry
    }

    private func uploadAttachment(
        fileId: String,
        data: Data,
        file: FileAttachment,
        draftKey k: String,
        settings: SettingsStore,
        onToast: @escaping (String) -> Void
    ) {
        let secret = settings.activeSecret
        let useAccount = settings.isUsingDeepSeekAccount
        let baseUrl = settings.effectiveBaseUrl
        let purpose = AttachmentStore.uploadPurpose(fileName: file.name, isImage: file.isImage)

        Task {
            do {
                let serverId = try await AIClient.uploadFile(
                    data: data,
                    fileName: file.name,
                    mimeType: file.mimeType,
                    purpose: purpose,
                    secret: secret,
                    useAccount: useAccount,
                    baseUrl: baseUrl
                )
                guard var entry = drafts[k],
                      let idx = entry.attachments.firstIndex(where: { $0.id == fileId })
                else { return }
                entry.attachments[idx].file.serverId = serverId
                entry.attachments[idx].status = .done
                drafts[k] = entry
            } catch {
                guard var entry = drafts[k],
                      let idx = entry.attachments.firstIndex(where: { $0.id == fileId })
                else { return }
                entry.attachments[idx].status = .failed(error.localizedDescription)
                drafts[k] = entry
                AppLogStore.shared.record(.error, source: "attachment.upload", message: error.localizedDescription)
                onToast("附件上传失败：\(error.localizedDescription)")
            }
        }
    }
}

/// Lightweight sidebar metadata (mirrors Android SessionSummary) — NEVER changes during streaming deltas!
struct SessionSummaryItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let isPinned: Bool
    let pinnedAt: Date?
}

/// Isolated sidebar list store so streaming tokens NEVER trigger sidebar re-sorts or date grouping!
@MainActor
final class SessionListStore: ObservableObject {
    @Published private(set) var summaries: [SessionSummaryItem] = []

    func sync(from sessions: [ChatSession]) {
        let next = sessions.sorted { lhs, rhs in
            let pinA = lhs.isPinned ? (lhs.pinnedAt ?? lhs.updatedAt).timeIntervalSince1970 : 0
            let pinB = rhs.isPinned ? (rhs.pinnedAt ?? rhs.updatedAt).timeIntervalSince1970 : 0
            if pinA != pinB { return pinA > pinB }
            return lhs.updatedAt > rhs.updatedAt
        }.map { s in
            SessionSummaryItem(
                id: s.id,
                title: s.title,
                updatedAt: s.updatedAt,
                isPinned: s.isPinned,
                pinnedAt: s.pinnedAt
            )
        }
        if next != summaries {
            summaries = next
        }
    }
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var activeSessionId: UUID?
    @Published var isGenerating = false
    @Published var importingHistory = false
    @Published var toastMessage: String?

    /// Dedicated isolated sub-stores so typing and streaming NEVER cause whole-app redraws.
    let draftStore = DraftStore()
    let listStore = SessionListStore()

    private var activeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var saveWorkItem: DispatchWorkItem?
    private var lastIcloudBackupAt: Date?
    private var manuallyRenamedSessions: Set<UUID> = []
    private var rejectedHistoryImageIds: Set<String> = []
    private var consumingPendingMigration = false

    private static let persistenceQueue = DispatchQueue(label: "com.rankchord.nuwa.persistence", qos: .utility)

    private static var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Nuwa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    init() {
        loadAsync()
    }

    var activeSession: ChatSession? {
        guard let activeSessionId else { return nil }
        return sessions.first { $0.id == activeSessionId }
    }

    func sessionMatchesQuery(_ sessionId: UUID, query: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return false }
        if session.title.localizedCaseInsensitiveContains(query) { return true }
        return session.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Session CRUD

    @discardableResult
    func createNewSession(silentIfAlreadyNew: Bool = false) -> ChatSession? {
        stopGenerating()
        if activeSessionId == nil || (activeSession?.visibleMessages().isEmpty == true) {
            if !silentIfAlreadyNew {
                showToast("已在最新对话中")
            }
            activeSessionId = nil
            return nil
        }
        activeSessionId = nil
        return nil
    }

    func selectSession(_ id: UUID) {
        if activeSessionId != id {
            stopGenerating()
            activeSessionId = id
        }
    }

    func togglePin(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned.toggle()
        sessions[idx].pinnedAt = sessions[idx].isPinned ? Date() : nil
        listStore.sync(from: sessions)
        scheduleSave()
    }

    func setSessionsPinned(_ ids: Set<UUID>, pinned: Bool) {
        var changed = false
        let now = Date()
        for idx in sessions.indices where ids.contains(sessions[idx].id) {
            if sessions[idx].isPinned != pinned {
                sessions[idx].isPinned = pinned
                sessions[idx].pinnedAt = pinned ? now : nil
                changed = true
            }
        }
        if changed {
            listStore.sync(from: sessions)
            scheduleSave()
        }
    }

    func renameSession(_ id: UUID, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        manuallyRenamedSessions.insert(id)
        sessions[idx].title = clean
        sessions[idx].updatedAt = Date()
        listStore.sync(from: sessions)
        scheduleSave()
    }

    func deleteSession(_ id: UUID) {
        if activeSessionId == id {
            stopGenerating()
            activeSessionId = nil
        }
        sessions.removeAll { $0.id == id }
        draftStore.removeDraft(for: id)
        listStore.sync(from: sessions)
        scheduleSave()
    }

    func deleteSessions(_ ids: Set<UUID>) {
        if let active = activeSessionId, ids.contains(active) {
            stopGenerating()
            activeSessionId = nil
        }
        sessions.removeAll { ids.contains($0.id) }
        for id in ids { draftStore.removeDraft(for: id) }
        listStore.sync(from: sessions)
        scheduleSave()
    }

    func deleteAllSessions() {
        stopGenerating()
        sessions.removeAll()
        draftStore.clearAll()
        activeSessionId = nil
        listStore.sync(from: sessions)
        Task.detached(priority: .utility) {
            AttachmentStore.deleteAllLocalFiles()
        }
        scheduleSave(immediate: true)
    }

    func stopGenerating() {
        activeTask?.cancel()
        activeTask = nil
        isGenerating = false
        if let sIdx = sessions.firstIndex(where: { $0.id == activeSessionId }) {
            var modified = false
            for mIdx in sessions[sIdx].messages.indices where sessions[sIdx].messages[mIdx].isStreaming {
                sessions[sIdx].messages[mIdx].status = .stopped
                modified = true
            }
            if modified { scheduleSave() }
        }
    }

    // MARK: - Branching Chat Actions (Send / Edit / Regenerate / Continue / Switch Version)

    func sendCurrentDraft(settings: SettingsStore) {
        let targetId = activeSessionId
        guard draftStore.canSend(for: targetId, isBusy: importingHistory || isGenerating) else { return }
        let d = draftStore.consumeDraft(for: targetId)
        let trimmed = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = d.attachments.map(\.file)

        if activeSessionId == nil || !sessions.contains(where: { $0.id == activeSessionId }) {
            let fresh = ChatSession(title: "")
            sessions.insert(fresh, at: 0)
            activeSessionId = fresh.id
        }
        guard let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }

        let visible = sessions[sIdx].visibleMessages()
        let userMsg = ChatMessage(role: .user, content: trimmed, files: files)
        let assistantMsg = ChatMessage(
            role: .assistant,
            content: "",
            status: .pending,
            thinkingEnabled: settings.thinkingEnabled,
            searchEnabled: settings.searchEnabled,
            latestReminder: LocationCatalog.createLatestReminder(locale: settings.locale, location: settings.location)
        )

        sessions[sIdx].appendBranch(parentId: visible.last?.id, newMessages: [userMsg, assistantMsg])
        sessions[sIdx].updatedAt = Date()
        listStore.sync(from: sessions)
        scheduleSave()

        streamReply(
            sessionId: sessionId,
            assistantId: assistantMsg.id,
            history: visible,
            question: userMsg,
            prefixReply: nil,
            settings: settings
        )
    }

    func editUserMessage(messageId: UUID, newContent: String, settings: SettingsStore) {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating,
              let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }

        let path = sessions[sIdx].visibleMessages()
        guard let idx = path.firstIndex(where: { $0.id == messageId && $0.role == .user }) else { return }
        let original = path[idx]
        guard !trimmed.isEmpty || !original.files.isEmpty else { return }
        let history = Array(path.prefix(idx))

        let editedUser = ChatMessage(role: .user, content: trimmed, files: original.files)
        let assistantMsg = ChatMessage(
            role: .assistant,
            content: "",
            status: .pending,
            thinkingEnabled: settings.thinkingEnabled,
            searchEnabled: settings.searchEnabled,
            latestReminder: LocationCatalog.createLatestReminder(locale: settings.locale, location: settings.location)
        )

        sessions[sIdx].appendBranch(parentId: original.parentId, newMessages: [editedUser, assistantMsg])
        sessions[sIdx].updatedAt = Date()
        listStore.sync(from: sessions)
        scheduleSave()

        streamReply(
            sessionId: sessionId,
            assistantId: assistantMsg.id,
            history: history,
            question: editedUser,
            prefixReply: nil,
            settings: settings
        )
    }

    func regenerateReply(messageId: UUID? = nil, settings: SettingsStore) {
        guard !isGenerating,
              let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }

        let path = sessions[sIdx].visibleMessages()
        let targetIdx: Int
        if let messageId {
            guard let found = path.firstIndex(where: { $0.id == messageId }) else { return }
            targetIdx = found
        } else {
            targetIdx = path.count - 1
        }
        guard targetIdx >= 1,
              path[targetIdx].role == .assistant,
              path[targetIdx - 1].role == .user
        else { return }

        let question = path[targetIdx - 1]
        let history = Array(path.prefix(targetIdx - 1))
        let assistantMsg = ChatMessage(
            role: .assistant,
            content: "",
            status: .pending,
            thinkingEnabled: settings.thinkingEnabled,
            searchEnabled: settings.searchEnabled,
            latestReminder: LocationCatalog.createLatestReminder(locale: settings.locale, location: settings.location)
        )

        sessions[sIdx].appendBranch(parentId: question.id, newMessages: [assistantMsg])
        sessions[sIdx].updatedAt = Date()
        listStore.sync(from: sessions)
        scheduleSave()

        streamReply(
            sessionId: sessionId,
            assistantId: assistantMsg.id,
            history: history,
            question: question,
            prefixReply: nil,
            settings: settings
        )
    }

    func continueReply(messageId: UUID, settings: SettingsStore) {
        guard !isGenerating,
              let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }

        let path = sessions[sIdx].visibleMessages()
        guard let idx = path.firstIndex(where: { $0.id == messageId }),
              idx == path.count - 1,
              idx >= 1,
              path[idx].canContinueReply,
              path[idx - 1].role == .user
        else { return }

        let prefixSnapshot = path[idx]
        let question = path[idx - 1]
        let history = Array(path.prefix(idx - 1))

        if let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId }) {
            sessions[sIdx].messages[mIdx].status = .streaming
            sessions[sIdx].messages[mIdx].errorMessage = nil
        }
        scheduleSave()

        streamReply(
            sessionId: sessionId,
            assistantId: messageId,
            history: history,
            question: question,
            prefixReply: prefixSnapshot,
            settings: settings
        )
    }

    func selectVersion(messageId: UUID) {
        guard !isGenerating,
              let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }
        sessions[sIdx].selectVersion(messageId: messageId)
        scheduleSave()
    }

    // MARK: - Attachment Preparation & Re-upload Recovery

    private func saveServerIds(sessionId: UUID, map: [String: String]) {
        guard !map.isEmpty,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }
        for mIdx in sessions[sIdx].messages.indices where sessions[sIdx].messages[mIdx].role == .user {
            for fIdx in sessions[sIdx].messages[mIdx].files.indices {
                let localId = sessions[sIdx].messages[mIdx].files[fIdx].id
                if let newServerId = map[localId] {
                    sessions[sIdx].messages[mIdx].files[fIdx].serverId = newServerId
                }
            }
        }
        scheduleSave()
    }

    private func prepareFilesForRequest(
        sessionId: UUID,
        history: [ChatMessage],
        question: ChatMessage,
        settings: SettingsStore
    ) async throws -> (history: [ChatMessage], question: ChatMessage) {
        let secret = settings.activeSecret
        let useAccount = settings.isUsingDeepSeekAccount
        let baseUrl = settings.effectiveBaseUrl
        guard useAccount || settings.effectiveProtocol == .anthropic else {
            return (history, question)
        }

        let liveById: [UUID: ChatMessage]
        if let s = sessions.first(where: { $0.id == sessionId }) {
            liveById = Dictionary(uniqueKeysWithValues: s.messages.map { ($0.id, $0) })
        } else {
            liveById = [:]
        }
        let liveQuestion = liveById[question.id] ?? question
        let liveHistory = history.map { liveById[$0.id] ?? $0 }

        var uploadedMap: [String: String] = [:]

        for file in liveQuestion.files where file.serverId == nil {
            try Task.checkCancellation()
            guard let url = AttachmentStore.localURL(for: file),
                  let data = try? Data(contentsOf: url)
            else { continue }
            let purpose = AttachmentStore.uploadPurpose(fileName: file.name, isImage: file.isImage)
            let serverId = try await AIClient.uploadFile(
                data: data,
                fileName: file.name,
                mimeType: file.mimeType,
                purpose: purpose,
                secret: secret,
                useAccount: useAccount,
                baseUrl: baseUrl
            )
            uploadedMap[file.id] = serverId
        }
        if !uploadedMap.isEmpty {
            saveServerIds(sessionId: sessionId, map: uploadedMap)
        }

        for msg in liveHistory.reversed() where msg.role == .user {
            for file in msg.files where file.serverId == nil && uploadedMap[file.id] == nil {
                try Task.checkCancellation()
                guard let url = AttachmentStore.localURL(for: file),
                      let data = try? Data(contentsOf: url)
                else { continue }
                let purpose = AttachmentStore.uploadPurpose(fileName: file.name, isImage: file.isImage)
                if let serverId = try? await AIClient.uploadFile(
                    data: data,
                    fileName: file.name,
                    mimeType: file.mimeType,
                    purpose: purpose,
                    secret: secret,
                    useAccount: useAccount,
                    baseUrl: baseUrl
                ) {
                    uploadedMap[file.id] = serverId
                    saveServerIds(sessionId: sessionId, map: [file.id: serverId])
                }
            }
        }

        guard let refreshedSession = sessions.first(where: { $0.id == sessionId }) else {
            return (liveHistory, liveQuestion)
        }
        let refreshedById = Dictionary(uniqueKeysWithValues: refreshedSession.messages.map { ($0.id, $0) })
        return (
            liveHistory.map { refreshedById[$0.id] ?? $0 },
            refreshedById[liveQuestion.id] ?? liveQuestion
        )
    }

    private func invalidateServerFileIds(sessionId: UUID, targetServerIds: Set<String>) -> Bool {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return false }
        var clearedAny = false
        for mIdx in sessions[sIdx].messages.indices where sessions[sIdx].messages[mIdx].role == .user {
            for fIdx in sessions[sIdx].messages[mIdx].files.indices {
                if let sid = sessions[sIdx].messages[mIdx].files[fIdx].serverId,
                   (targetServerIds.isEmpty || targetServerIds.contains(sid)),
                   AttachmentStore.localURL(for: sessions[sIdx].messages[mIdx].files[fIdx]) != nil {
                    sessions[sIdx].messages[mIdx].files[fIdx].serverId = nil
                    clearedAny = true
                }
            }
        }
        if clearedAny { scheduleSave() }
        return clearedAny
    }

    // MARK: - 30fps Coalesced Streaming Reducer (Zero UI Jank!)

    private func streamReply(
        sessionId: UUID,
        assistantId: UUID,
        history: [ChatMessage],
        question: ChatMessage,
        prefixReply: ChatMessage?,
        settings: SettingsStore
    ) {
        isGenerating = true
        manuallyRenamedSessions.remove(sessionId)

        let useAccount = settings.isUsingDeepSeekAccount
        let apiProtocol = settings.effectiveProtocol
        let baseUrl = settings.effectiveBaseUrl
        let secret = settings.activeSecret
        let model = settings.effectiveModel
        let customSystemPrompt = settings.systemPrompt
        let thinkingEnabled = settings.thinkingEnabled
        let searchEnabled = settings.searchEnabled
        let reminder = prefixReply?.latestReminder ?? LocationCatalog.createLatestReminder(locale: settings.locale, location: settings.location)
        let initialWantsTitle = sessions.first(where: { $0.id == sessionId })?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true

        activeTask = Task {
            var omitExtendedFor1M = false
            var fileRetryAttempt = 0
            var skippedBadImages = 0
            let maxFileRetries = 2
            let maxSkippedBadImages = 10

            for _ in 0..<15 {
                var receivedContent = false
                do {
                    let prepared = try await prepareFilesForRequest(
                        sessionId: sessionId,
                        history: history,
                        question: question,
                        settings: settings
                    )

                    let wantsTitle = initialWantsTitle && !manuallyRenamedSessions.contains(sessionId)
                    let params = AIClient.StreamParams(
                        history: prepared.history,
                        question: prepared.question,
                        prefixReply: prefixReply,
                        useAccount: useAccount,
                        apiProtocol: apiProtocol,
                        baseUrl: baseUrl,
                        secret: secret,
                        model: model,
                        customSystemPrompt: customSystemPrompt,
                        thinkingEnabled: thinkingEnabled,
                        searchEnabled: searchEnabled,
                        wantsTitle: wantsTitle,
                        latestReminder: reminder,
                        omitExtendedFor1M: omitExtendedFor1M,
                        rejectedFileIds: rejectedHistoryImageIds
                    )

                    // Local working copy to coalesce rapid SSE token chunks at ~30fps (33ms)
                    guard let initSIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                          let initMIdx = sessions[initSIdx].messages.firstIndex(where: { $0.id == assistantId })
                    else { break }
                    var working = sessions[initSIdx].messages[initMIdx]
                    var pendingTitle: String?
                    var blockIndexMap: [Int: Int] = [:]
                    var lastFlushTime = ContinuousClock.now
                    var hasDirtyDelta = false

                    func flushWorking(force: Bool = false) {
                        guard force || hasDirtyDelta else { return }
                        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == assistantId })
                        else { return }
                        sessions[sIdx].messages[mIdx] = working
                        sessions[sIdx].updatedAt = Date()
                        if let t = pendingTitle,
                           !manuallyRenamedSessions.contains(sessionId),
                           sessions[sIdx].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sessions[sIdx].title = t
                            pendingTitle = nil
                            listStore.sync(from: sessions)
                        }
                        lastFlushTime = ContinuousClock.now
                        hasDirtyDelta = false
                    }

                    for try await event in AIClient.streamChat(params) {
                        working.status = .streaming

                        switch event {
                        case .blockStart(let streamIdx, let block):
                            receivedContent = true
                            blockIndexMap[streamIdx] = working.blocks.count
                            working.blocks.append(block)
                            hasDirtyDelta = true
                            flushWorking(force: true)

                        case .textDelta(let streamIdx, let delta):
                            if let localIdx = blockIndexMap[streamIdx],
                               localIdx < working.blocks.count,
                               case .text(let id, let existing, let cites, let isTemplate) = working.blocks[localIdx] {
                                working.blocks[localIdx] = .text(id: id, text: existing + delta, citations: cites, isTemplate: isTemplate)
                            }
                            working.content += delta
                            hasDirtyDelta = true

                        case .thinkingDelta(let streamIdx, let delta):
                            if let localIdx = blockIndexMap[streamIdx],
                               localIdx < working.blocks.count,
                               case .thinking(let id, let existing, let sig, let start, let end, _) = working.blocks[localIdx] {
                                let elapsed = start.map { Date().timeIntervalSince($0) }
                                working.blocks[localIdx] = .thinking(id: id, text: existing + delta, signature: sig, startedAt: start, endedAt: end, elapsedSeconds: elapsed)
                                working.thinkingSeconds = elapsed
                            }
                            working.reasoning += delta
                            hasDirtyDelta = true

                        case .signatureDelta(let streamIdx, let sigDelta):
                            if let localIdx = blockIndexMap[streamIdx],
                               localIdx < working.blocks.count,
                               case .thinking(let id, let existing, let sig, let start, let end, let elapsed) = working.blocks[localIdx] {
                                working.blocks[localIdx] = .thinking(id: id, text: existing, signature: (sig ?? "") + sigDelta, startedAt: start, endedAt: end, elapsedSeconds: elapsed)
                            }

                        case .citationDelta(let streamIdx, let citation):
                            if let localIdx = blockIndexMap[streamIdx],
                               localIdx < working.blocks.count,
                               case .text(let id, let existing, var cites, let isTemplate) = working.blocks[localIdx] {
                                cites.append(citation)
                                working.blocks[localIdx] = .text(id: id, text: existing, citations: cites, isTemplate: isTemplate)
                                hasDirtyDelta = true
                            }

                        case .blockStop(let streamIdx):
                            if let localIdx = blockIndexMap.removeValue(forKey: streamIdx),
                               localIdx < working.blocks.count,
                               case .thinking(let id, let existing, let sig, let start, _, _) = working.blocks[localIdx] {
                                let now = Date()
                                let elapsed = start.map { now.timeIntervalSince($0) }
                                working.blocks[localIdx] = .thinking(id: id, text: existing, signature: sig, startedAt: start, endedAt: now, elapsedSeconds: elapsed)
                                working.thinkingSeconds = elapsed
                            }
                            hasDirtyDelta = true
                            flushWorking(force: true)

                        case .messageDelta(let stopReason, let autoTitle):
                            if let stopReason { working.stopReason = stopReason }
                            if let autoTitle, !autoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                pendingTitle = autoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            hasDirtyDelta = true
                            flushWorking(force: true)

                        case .disablePrefix:
                            working.prefixEnabled = false
                        }

                        if hasDirtyDelta && (ContinuousClock.now - lastFlushTime) >= .milliseconds(33) {
                            flushWorking()
                        }
                    }

                    // Settle final working state
                    if working.stopReason == "refusal" {
                        working.blocks.removeAll { block in
                            switch block {
                            case .thinking: return true
                            case .text(_, _, _, let isTemplate): return !isTemplate
                            default: return false
                            }
                        }
                        working.content = "你好，这个问题我暂时无法回答，让我们换个话题再聊聊吧。"
                        working.reasoning = ""
                    }
                    working.status = Task.isCancelled ? .stopped : .done
                    flushWorking(force: true)

                    if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                       sessions[sIdx].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !manuallyRenamedSessions.contains(sessionId) {
                        let fallbackTitle = question.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        sessions[sIdx].title = fallbackTitle.isEmpty ? "新对话" : String(fallbackTitle.prefix(24))
                        listStore.sync(from: sessions)
                    }
                    break
                } catch let err as AIClientError where !receivedContent && !omitExtendedFor1M && err.is32kInputLimit {
                    omitExtendedFor1M = true
                    continue
                } catch let err as AIClientError where !receivedContent && skippedBadImages < maxSkippedBadImages && err.unsupportedImageIndices() != nil {
                    let candidateIds: [String] = history.flatMap { msg in
                        msg.role == .user ? msg.files.compactMap { $0.isImage ? $0.serverId : nil } : []
                    }
                    if let badId = candidateIds.first(where: { !rejectedHistoryImageIds.contains($0) }) {
                        rejectedHistoryImageIds.insert(badId)
                        skippedBadImages += 1
                        continue
                    }
                    setStreamError(sessionId: sessionId, assistantId: assistantId, message: "暂不支持解析该图片，请更换 JPG / PNG / WebP 图片后重试。")
                    break
                } catch let err as AIClientError where !receivedContent && fileRetryAttempt < maxFileRetries && err.isFileInvalidated {
                    let mentioned = Set(err.mentionedFileIds())
                    if invalidateServerFileIds(sessionId: sessionId, targetServerIds: mentioned) {
                        let delayMs = 1000 * (1 << fileRetryAttempt)
                        fileRetryAttempt += 1
                        try? await Task.sleep(for: .milliseconds(delayMs))
                        if Task.isCancelled {
                            setStreamStopped(sessionId: sessionId, assistantId: assistantId)
                            break
                        }
                        continue
                    }
                    setStreamError(sessionId: sessionId, assistantId: assistantId, message: err.localizedDescription)
                    break
                } catch {
                    if Task.isCancelled {
                        setStreamStopped(sessionId: sessionId, assistantId: assistantId)
                    } else {
                        AppLogStore.shared.record(.error, source: "chatStore.stream", message: error.localizedDescription)
                        setStreamError(sessionId: sessionId, assistantId: assistantId, message: error.localizedDescription)
                    }
                    break
                }
            }

            isGenerating = false
            activeTask = nil
            listStore.sync(from: sessions)
            scheduleSave(immediate: true)
            settings.schedulePostReplyBalanceRefresh()
        }
    }

    private func setStreamStopped(sessionId: UUID, assistantId: UUID) {
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == assistantId }) {
            sessions[sIdx].messages[mIdx].status = .stopped
        }
    }

    private func setStreamError(sessionId: UUID, assistantId: UUID, message: String) {
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
           let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == assistantId }) {
            sessions[sIdx].messages[mIdx].status = .error
            sessions[sIdx].messages[mIdx].errorMessage = message
        }
    }

    // MARK: - Import / Export / Share Link / Pending Migration / iCloud Auto-Backup

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                toastMessage = nil
            }
        }
    }

    func checkPendingMigration() {
        guard !consumingPendingMigration, !importingHistory else { return }
        guard let pendingPath = UserDefaults.standard.string(forKey: MigrationWebViewController.keyPendingPath),
              !pendingPath.isEmpty
        else { return }

        consumingPendingMigration = true
        UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingPath)
        UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingName)

        guard FileManager.default.fileExists(atPath: pendingPath) else {
            consumingPendingMigration = false
            return
        }
        importFromFilePath(pendingPath) { [weak self] in
            try? FileManager.default.removeItem(atPath: pendingPath)
            self?.consumingPendingMigration = false
        }
    }

    func exportDeepSeekZipDataAsync() async throws -> Data {
        let snapshot = sessions
        return try await Task.detached(priority: .userInitiated) {
            try DeepSeekZipExporter.exportSessionsToZip(snapshot)
        }.value
    }

    func importFromFileDataAsync(_ data: Data) async throws -> Int {
        importingHistory = true
        defer { importingHistory = false }
        let parsed: [ChatSession] = try await Task.detached(priority: .userInitiated) {
            if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
                return try DeepSeekZipImporter.parseZipData(data)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(NuwaBackupArchive.self, from: data)
            return archive.sessions
        }.value
        return mergeSessions(parsed)
    }

    func importFromFilePath(_ path: String, onFinished: (() -> Void)? = nil) {
        importingHistory = true
        UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingPath)
        UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingName)
        Task {
            defer {
                importingHistory = false
                onFinished?()
            }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: URL(fileURLWithPath: path))
                }.value
                let count = try await importFromFileDataAsync(data)
                showToast(count == 1 ? "已导入 1 个对话" : "已导入 \(count) 个对话")
            } catch {
                AppLogStore.shared.record(.error, source: "migration.import", message: error.localizedDescription)
                showToast("导入失败：\(error.localizedDescription)")
            }
        }
    }

    func importFromShareLink(_ input: String) async throws -> ChatSession {
        do {
            let session = try await ShareLinkImporter.fetchSharedSession(input: input)
            sessions.insert(session, at: 0)
            activeSessionId = session.id
            listStore.sync(from: sessions)
            scheduleSave(immediate: true)
            return session
        } catch {
            AppLogStore.shared.record(.error, source: "shareLink.import", message: error.localizedDescription)
            throw error
        }
    }

    func maybeAutoBackupToIcloud(settings: SettingsStore) {
        guard settings.icloudAutoBackup, !sessions.isEmpty else { return }
        if let last = lastIcloudBackupAt, Date().timeIntervalSince(last) < 3600 {
            return
        }
        guard DeepSeekZipExporter.isIcloudAvailable() else { return }
        let snapshot = sessions
        lastIcloudBackupAt = Date()
        Task.detached(priority: .utility) {
            if let zip = try? DeepSeekZipExporter.exportSessionsToZip(snapshot) {
                _ = DeepSeekZipExporter.writeIcloudSnapshot(zipData: zip)
            }
        }
    }

    private func mergeSessions(_ incoming: [ChatSession]) -> Int {
        var existingById = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, $0) })
        var importedCount = 0
        for var item in incoming {
            item.ensureTreeNormalized()
            if let idx = existingById[item.id] {
                if item.updatedAt > sessions[idx].updatedAt || item.messages.count > sessions[idx].messages.count {
                    sessions[idx].title = item.title
                    sessions[idx].rootMessageId = item.rootMessageId
                    sessions[idx].messages = item.messages
                    sessions[idx].updatedAt = max(sessions[idx].updatedAt, item.updatedAt)
                    if item.isPinned {
                        sessions[idx].isPinned = true
                        sessions[idx].pinnedAt = sessions[idx].pinnedAt ?? item.pinnedAt ?? item.updatedAt
                    }
                }
            } else {
                existingById[item.id] = sessions.count
                sessions.append(item)
                importedCount += 1
            }
        }
        listStore.sync(from: sessions)
        scheduleSave(immediate: true)
        return importedCount
    }

    // MARK: - Background Serial Disk Persistence (Never Blocks Main Thread!)

    func flushPendingSave() {
        scheduleSave(immediate: true)
    }

    private func scheduleSave(immediate: Bool = false) {
        saveWorkItem?.cancel()
        let snapshot = sessions
        let targetURL = Self.storageURL
        let work = DispatchWorkItem {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: targetURL, options: [.atomic])
            } catch {
                Task { @MainActor in
                    AppLogStore.shared.record(.error, source: "chatStore.save", message: error.localizedDescription)
                }
            }
        }
        saveWorkItem = work
        if immediate {
            Self.persistenceQueue.async(execute: work)
        } else {
            Self.persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func loadAsync() {
        let targetURL = Self.storageURL
        Self.persistenceQueue.async { [weak self] in
            guard let data = try? Data(contentsOf: targetURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var decoded = try? decoder.decode([ChatSession].self, from: data) else { return }
            for i in decoded.indices {
                decoded[i].ensureTreeNormalized()
            }
            let readySessions = decoded
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.sessions.isEmpty {
                    self.sessions = readySessions
                } else {
                    _ = self.mergeSessions(readySessions)
                }
                self.listStore.sync(from: self.sessions)
            }
        }
    }
}
