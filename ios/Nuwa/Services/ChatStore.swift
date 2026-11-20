import Foundation
import SwiftUI
import UIKit

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
        let entry = drafts[k] ?? DraftEntry()
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
final class LiveReplyStore: ObservableObject {
    @Published var message: ChatMessage?
    var revision: Int = 0
}

struct ImportProgress: Equatable {
    enum Phase: Equatable {
        case reading
        case merging
    }
    let phase: Phase
    let sessions: Int
    let images: Int
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var sessions: [ChatSession] = [] {
        didSet { activeTimelineCache = nil }
    }
    @Published private(set) var activeSessionId: UUID? {
        didSet { activeTimelineCache = nil }
    }
    @Published var isGenerating = false
    @Published private(set) var importingHistory = false
    @Published private(set) var importProgress: ImportProgress?
    @Published var toastMessage: String?
    @Published private(set) var historyLoaded = false
    @Published private(set) var historyLoadFailed = false

    /// Dedicated isolated sub-stores so typing and streaming NEVER cause whole-app redraws.
    let draftStore = DraftStore()
    let listStore = SessionListStore()
    let liveReply = LiveReplyStore()

    private var activeTask: Task<Void, Never>?
    private var generationID: UUID?
    private var toastTask: Task<Void, Never>?
    private var saveWorkItem: DispatchWorkItem?
    private var lastIcloudBackupAt: Date?
    private var manuallyRenamedSessions: Set<UUID> = []
    private var rejectedHistoryImageIds: Set<String> = []
    private var consumingPendingMigration = false
    private var committingImport = false
    private var saveDeferredByImport = false
    private var activeTimelineCache: ActiveTimeline?

    private static let persistenceQueue = DispatchQueue(label: "com.rankchord.nuwa.persistence", qos: .utility)
    nonisolated(unsafe) private static let persistence = ChatHistoryPersistence()

    private static var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Nuwa", isDirectory: true)
        return dir.appendingPathComponent("sessions.json")
    }

    init() {
        loadAsync()
    }

    var activeSession: ChatSession? {
        guard let activeSessionId else { return nil }
        return sessions.first { $0.id == activeSessionId }
    }

    struct ActiveTimeline {
        let messages: [ChatMessage]
        let versions: [UUID: MessageVersionInfo]
    }

    var activeTimeline: ActiveTimeline? {
        if let activeTimelineCache { return activeTimelineCache }
        guard let session = activeSession else { return nil }
        let timeline = ActiveTimeline(messages: session.visibleMessages(), versions: session.messageVersions())
        activeTimelineCache = timeline
        return timeline
    }

    func matchingSessionIDs(query: String) async -> Set<UUID> {
        let snapshot = sessions
        let lookup = Task.detached(priority: .userInitiated) {
            var matches = Set<UUID>()
            for session in snapshot {
                if Task.isCancelled { break }
                if session.title.localizedCaseInsensitiveContains(query)
                    || session.messages.contains(where: {
                        $0.content.localizedCaseInsensitiveContains(query)
                        || $0.reasoning.localizedCaseInsensitiveContains(query)
                    }) {
                    matches.insert(session.id)
                }
            }
            return matches
        }
        return await withTaskCancellationHandler {
            await lookup.value
        } onCancel: {
            lookup.cancel()
        }
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
        guard !committingImport else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned.toggle()
        sessions[idx].pinnedAt = sessions[idx].isPinned ? Date() : nil
        listStore.sync(from: sessions)
        scheduleSave()
    }

    func setSessionsPinned(_ ids: Set<UUID>, pinned: Bool) {
        guard !committingImport else { return }
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
        guard !committingImport else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        manuallyRenamedSessions.insert(id)
        sessions[idx].title = clean
        sessions[idx].updatedAt = Date()
        listStore.sync(from: sessions)
        scheduleSave()
    }

    func deleteSession(_ id: UUID) {
        guard !committingImport else { return }
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
        guard !committingImport else { return }
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
        guard historyLoaded, !importingHistory else { return }
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
        guard isGenerating else { return }
        generationID = nil
        activeTask?.cancel()
        activeTask = nil
        isGenerating = false
        if let sIdx = sessions.firstIndex(where: { $0.id == activeSessionId }) {
            var session = sessions[sIdx]
            let streamingIndices = session.messages.indices.filter { session.messages[$0].isStreaming }
            for mIdx in streamingIndices {
                if let message = liveReply.message, message.id == session.messages[mIdx].id {
                    session.messages[mIdx] = message
                }
                session.messages[mIdx].status = .stopped
            }
            if !streamingIndices.isEmpty {
                session.updatedAt = Date()
                sessions[sIdx] = session
                listStore.sync(from: sessions)
                scheduleSave(immediate: true)
            }
        }
        if liveReply.message != nil { liveReply.message = nil }
    }

    // MARK: - Branching Chat Actions (Send / Edit / Regenerate / Continue / Switch Version)

    func sendCurrentDraft(settings: SettingsStore) {
        guard historyLoaded else { return }
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
            latestReminder: assistantMsg.latestReminder,
            settings: settings
        )
    }

    func editUserMessage(messageId: UUID, newContent: String, settings: SettingsStore) {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !importingHistory, !isGenerating,
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
            latestReminder: assistantMsg.latestReminder,
            settings: settings
        )
    }

    func regenerateReply(messageId: UUID? = nil, settings: SettingsStore) {
        guard !importingHistory, !isGenerating,
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
            latestReminder: assistantMsg.latestReminder,
            settings: settings
        )
    }

    func continueReply(messageId: UUID, settings: SettingsStore) {
        guard !importingHistory, !isGenerating,
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
            sessions[sIdx].messages[mIdx].stopReason = nil
            sessions[sIdx].messages[mIdx].errorMessage = nil
        }
        scheduleSave()

        streamReply(
            sessionId: sessionId,
            assistantId: messageId,
            history: history,
            question: question,
            prefixReply: prefixSnapshot,
            latestReminder: prefixSnapshot.latestReminder,
            settings: settings
        )
    }

    func selectVersion(messageId: UUID) {
        guard !committingImport, !isGenerating,
              let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }
        sessions[sIdx].selectVersion(messageId: messageId)
        scheduleSave()
    }

    // MARK: - Attachment Preparation & Re-upload Recovery

    private func saveServerIds(sessionId: UUID, map: [String: String]) {
        guard !Task.isCancelled, !map.isEmpty,
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
                  let rawData = try? Data(contentsOf: url)
            else { continue }
            let normalized = file.isImage
                ? AttachmentStore.normalizeImageForUpload(data: rawData, fileName: file.name)
                : (data: rawData, fileName: file.name, mimeType: file.mimeType)
            let purpose = AttachmentStore.uploadPurpose(fileName: normalized.fileName, isImage: file.isImage)
            let serverId = try await AIClient.uploadFile(
                data: normalized.data,
                fileName: normalized.fileName,
                mimeType: normalized.mimeType,
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

        for (msg, _) in AIClient.contextRounds(liveHistory).reversed() {
            for file in msg.files where file.serverId == nil && uploadedMap[file.id] == nil {
                try Task.checkCancellation()
                guard let url = AttachmentStore.localURL(for: file),
                      let rawData = try? Data(contentsOf: url)
                else { continue }
                let normalized = file.isImage
                    ? AttachmentStore.normalizeImageForUpload(data: rawData, fileName: file.name)
                    : (data: rawData, fileName: file.name, mimeType: file.mimeType)
                let purpose = AttachmentStore.uploadPurpose(fileName: normalized.fileName, isImage: file.isImage)
                if let serverId = try? await AIClient.uploadFile(
                    data: normalized.data,
                    fileName: normalized.fileName,
                    mimeType: normalized.mimeType,
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
                   targetServerIds.contains(sid),
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
        latestReminder: String?,
        settings: SettingsStore
    ) {
        let generation = UUID()
        generationID = generation
        isGenerating = true
        manuallyRenamedSessions.remove(sessionId)

        let useAccount = settings.isUsingDeepSeekAccount
        let apiProtocol = settings.effectiveProtocol
        let baseUrl = settings.effectiveBaseUrl
        let secret = settings.activeSecret
        let model = settings.effectiveModel
        let customSystemPrompt = settings.systemPrompt
        let thinkingEnabled = prefixReply?.thinkingEnabled ?? settings.thinkingEnabled
        let searchEnabled = prefixReply?.searchEnabled ?? settings.searchEnabled
        let initialWantsTitle = sessions.first(where: { $0.id == sessionId })?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true

        activeTask = Task {
            let supportsReplyHaptics = UIDevice.current.userInterfaceIdiom == .phone
            let hapticClock = ContinuousClock()
            var lastReplyHaptic: ContinuousClock.Instant?
            var replyHaptics: UIImpactFeedbackGenerator?
            var omitExtendedFor1M = false
            var fileRetryAttempt = 0
            var skippedBadImages = 0
            let maxFileRetries = 2
            let maxSkippedBadImages = 10

            for _ in 0..<15 {
                guard generationID == generation else { return }
                var receivedContent = false
                var working: ChatMessage?
                do {
                    let prepared = try await prepareFilesForRequest(
                        sessionId: sessionId,
                        history: history,
                        question: question,
                        settings: settings
                    )
                    guard generationID == generation else { return }

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
                        latestReminder: latestReminder,
                        omitExtendedFor1M: omitExtendedFor1M,
                        rejectedFileIds: rejectedHistoryImageIds
                    )

                    guard let initSIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                          let initMIdx = sessions[initSIdx].messages.firstIndex(where: { $0.id == assistantId })
                    else { break }
                    var draft = sessions[initSIdx].messages[initMIdx]
                    var pendingTitle: String?
                    var blockIndexMap: [Int: Int] = [:]
                    var pendingFlush: Task<Void, Never>?
                    defer { pendingFlush?.cancel() }

                    @MainActor
                    func publishDraft() {
                        guard generationID == generation else { return }
                        liveReply.revision &+= 1
                        liveReply.message = draft
                    }

                    do {
                        for try await event in AIClient.streamChat(params) {
                            guard generationID == generation else { return }
                            draft.status = .streaming

                            switch event {
                            case .blockStart(let streamIdx, let block):
                                receivedContent = true
                                blockIndexMap[streamIdx] = draft.blocks.count
                                draft.blocks.append(block)

                            case .textDelta(let streamIdx, let delta):
                                receivedContent = true
                                if supportsReplyHaptics, settings.hapticFeedbackEnabled, !delta.isEmpty,
                                   activeSessionId == sessionId, UIApplication.shared.applicationState == .active {
                                    let now = hapticClock.now
                                    if lastReplyHaptic.map({ $0.duration(to: now) >= .milliseconds(300) }) ?? true {
                                        if replyHaptics == nil { replyHaptics = UIImpactFeedbackGenerator(style: .medium) }
                                        replyHaptics?.impactOccurred()
                                        lastReplyHaptic = now
                                    }
                                }
                                if let localIdx = blockIndexMap[streamIdx],
                                   localIdx < draft.blocks.count,
                                   case .text(let id, let existing, let cites, let isTemplate) = draft.blocks[localIdx] {
                                    draft.blocks[localIdx] = .text(id: id, text: existing + delta, citations: cites, isTemplate: isTemplate)
                                }
                                draft.content += delta

                            case .thinkingDelta(let streamIdx, let delta):
                                receivedContent = true
                                if let localIdx = blockIndexMap[streamIdx],
                                   localIdx < draft.blocks.count,
                                   case .thinking(let id, let existing, let sig, let start, let end, _) = draft.blocks[localIdx] {
                                    let elapsed = start.map { Date().timeIntervalSince($0) }
                                    draft.blocks[localIdx] = .thinking(id: id, text: existing + delta, signature: sig, startedAt: start, endedAt: end, elapsedSeconds: elapsed)
                                    draft.thinkingSeconds = elapsed
                                }
                                draft.reasoning += delta

                            case .signatureDelta(let streamIdx, let sigDelta):
                                if let localIdx = blockIndexMap[streamIdx],
                                   localIdx < draft.blocks.count,
                                   case .thinking(let id, let existing, let sig, let start, let end, let elapsed) = draft.blocks[localIdx] {
                                    draft.blocks[localIdx] = .thinking(id: id, text: existing, signature: (sig ?? "") + sigDelta, startedAt: start, endedAt: end, elapsedSeconds: elapsed)
                                }

                            case .citationDelta(let streamIdx, let citation):
                                if let localIdx = blockIndexMap[streamIdx],
                                   localIdx < draft.blocks.count,
                                   case .text(let id, let existing, var cites, let isTemplate) = draft.blocks[localIdx] {
                                    cites.append(citation)
                                    draft.blocks[localIdx] = .text(id: id, text: existing, citations: cites, isTemplate: isTemplate)
                                }

                            case .blockStop(let streamIdx):
                                if let localIdx = blockIndexMap.removeValue(forKey: streamIdx),
                                   localIdx < draft.blocks.count,
                                   case .thinking(let id, let existing, let sig, let start, _, _) = draft.blocks[localIdx] {
                                    let now = Date()
                                    let elapsed = start.map { now.timeIntervalSince($0) }
                                    draft.blocks[localIdx] = .thinking(id: id, text: existing, signature: sig, startedAt: start, endedAt: now, elapsedSeconds: elapsed)
                                    draft.thinkingSeconds = elapsed
                                }

                            case .messageDelta(let stopReason, let autoTitle):
                                if let stopReason { draft.stopReason = stopReason }
                                if wantsTitle, stopReason == "end_turn" || stopReason == "max_tokens",
                                   let autoTitle, !autoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    pendingTitle = autoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                                }

                            case .disablePrefix:
                                receivedContent = true
                                draft.prefixEnabled = false
                            }

                            if liveReply.message == nil {
                                publishDraft()
                            } else if pendingFlush == nil {
                                pendingFlush = Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(60))
                                    guard !Task.isCancelled else { return }
                                    pendingFlush = nil
                                    publishDraft()
                                }
                            }
                        }
                    } catch {
                        working = draft
                        throw error
                    }

                    guard generationID == generation else { return }
                    if draft.stopReason == "refusal" {
                        draft.blocks.removeAll { block in
                            switch block {
                            case .thinking: return true
                            case .text(_, _, _, let isTemplate): return !isTemplate
                            default: return false
                            }
                        }
                        draft.content = "你好，这个问题我暂时无法回答，让我们换个话题再聊聊吧。"
                        draft.reasoning = ""
                    }
                    draft.status = .done
                    let fallbackTitle = question.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    commitReply(draft, sessionId: sessionId, title: pendingTitle ?? (fallbackTitle.isEmpty ? "新对话" : String(fallbackTitle.prefix(24))))
                    break
                } catch let err as AIClientError where !receivedContent && !omitExtendedFor1M && err.is32kInputLimit {
                    omitExtendedFor1M = true
                    continue
                } catch AIClientError.unsupportedImage(let historyFileId) where !receivedContent {
                    if let historyFileId, skippedBadImages < maxSkippedBadImages,
                       rejectedHistoryImageIds.insert(historyFileId).inserted {
                        skippedBadImages += 1
                        continue
                    }
                    let error = AIClientError.unsupportedImage(historyFileId: historyFileId)
                    setStreamError(sessionId: sessionId, assistantId: assistantId, message: error.localizedDescription)
                    break
                } catch AIClientError.invalidatedFiles(let targetIds, let message) where !receivedContent {
                    guard generationID == generation else { return }
                    if fileRetryAttempt < maxFileRetries,
                       invalidateServerFileIds(sessionId: sessionId, targetServerIds: targetIds) {
                        let delayMs = 1000 * (1 << fileRetryAttempt)
                        fileRetryAttempt += 1
                        try? await Task.sleep(for: .milliseconds(delayMs))
                        guard generationID == generation else { return }
                        continue
                    }
                    let error = AIClientError.invalidatedFiles(targetIds, message: message)
                    setStreamError(sessionId: sessionId, assistantId: assistantId, message: error.localizedDescription)
                    break
                } catch {
                    guard generationID == generation else { return }
                    if var partial = working, receivedContent {
                        partial.status = .error
                        partial.errorMessage = error.localizedDescription
                        commitReply(partial, sessionId: sessionId)
                    } else {
                        AppLogStore.shared.record(.error, source: "chatStore.stream", message: error.localizedDescription)
                        setStreamError(sessionId: sessionId, assistantId: assistantId, message: error.localizedDescription)
                    }
                    break
                }
            }

            guard generationID == generation else { return }
            generationID = nil
            liveReply.message = nil
            isGenerating = false
            activeTask = nil
            listStore.sync(from: sessions)
            scheduleSave(immediate: true)
            settings.schedulePostReplyBalanceRefresh()
        }
    }

    private func commitReply(_ reply: ChatMessage, sessionId: UUID, title: String? = nil) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == reply.id })
        else { return }
        var session = sessions[sIdx]
        session.messages[mIdx] = reply
        session.updatedAt = Date()
        if let title, !manuallyRenamedSessions.contains(sessionId),
           session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.title = title
        }
        sessions[sIdx] = session
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
        guard historyLoaded, !consumingPendingMigration, !importingHistory else { return }
        guard let pendingPath = UserDefaults.standard.string(forKey: MigrationWebViewController.keyPendingPath),
              !pendingPath.isEmpty
        else { return }

        consumingPendingMigration = true
        guard FileManager.default.fileExists(atPath: pendingPath) else {
            UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingPath)
            UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingName)
            consumingPendingMigration = false
            return
        }
        importFromFilePath(pendingPath) { [weak self] succeeded in
            if succeeded { try? FileManager.default.removeItem(atPath: pendingPath) }
            self?.consumingPendingMigration = false
        }
    }

    func exportDeepSeekZipDataAsync() async throws -> Data {
        guard historyLoaded else { throw HistoryUnavailable() }
        let snapshot = sessions
        return try await Task.detached(priority: .userInitiated) {
            try DeepSeekZipExporter.exportSessionsToZip(snapshot)
        }.value
    }

    func importFromFile(_ url: URL) async throws -> Int {
        guard historyLoaded else { throw HistoryUnavailable() }
        guard !importingHistory else { throw HistoryImportInProgress() }
        importingHistory = true
        importProgress = ImportProgress(phase: .reading, sessions: 0, images: 0)
        defer {
            importingHistory = false
            importProgress = nil
        }
        let parsed: [ChatSession] = try await Task.detached(priority: .userInitiated) { [weak self] in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
                return try DeepSeekZipImporter.parseZipData(data) { sessionsCount, imagesCount in
                    Task { @MainActor [weak self] in
                        self?.importProgress = ImportProgress(phase: .reading, sessions: sessionsCount, images: imagesCount)
                    }
                }
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(NuwaBackupArchive.self, from: data)
            return archive.sessions.map { session in
                var normalized = session
                normalized.ensureTreeNormalized()
                return normalized
            }
        }.value
        let current = importProgress
        importProgress = ImportProgress(
            phase: .merging,
            sessions: max(parsed.count, current?.sessions ?? 0),
            images: current?.images ?? 0
        )
        return try await commitImportedSessions(parsed)
    }

    func importFromFilePath(_ path: String, onFinished: ((Bool) -> Void)? = nil) {
        Task {
            var succeeded = false
            defer { onFinished?(succeeded) }
            do {
                let count = try await importFromFile(URL(fileURLWithPath: path))
                if UserDefaults.standard.string(forKey: MigrationWebViewController.keyPendingPath) == path {
                    UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingPath)
                    UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingName)
                }
                if count == 0 {
                    showToast("本地已是最新记录，未覆盖任何对话")
                } else {
                    showToast(count == 1 ? "已导入 1 个对话" : "已导入 \(count) 个对话")
                }
                succeeded = true
            } catch {
                AppLogStore.shared.record(.error, source: "migration.import", message: error.localizedDescription)
                showToast("导入失败：\(error.localizedDescription)")
            }
        }
    }

    func importFromShareLink(_ input: String) async throws -> ChatSession {
        guard historyLoaded else { throw HistoryUnavailable() }
        guard !importingHistory else { throw HistoryImportInProgress() }
        importingHistory = true
        defer { importingHistory = false }
        do {
            let session = try await ShareLinkImporter.fetchSharedSession(input: input)
            stopGenerating()
            _ = try await commitImportedSessions([session])
            activeSessionId = session.id
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

    private func commitImportedSessions(_ incoming: [ChatSession]) async throws -> Int {
        if isGenerating, incoming.contains(where: { $0.id == activeSessionId }) { stopGenerating() }
        let merged = mergeSessions(incoming)
        guard merged.changed else { return merged.count }

        // Keep delayed snapshots from overwriting the import while SQLite commits it.
        committingImport = true
        saveWorkItem?.cancel()
        let targetURL = Self.storageURL
        let snapshot = merged.sessions
        defer {
            committingImport = false
            if saveDeferredByImport {
                saveDeferredByImport = false
                scheduleSave(immediate: true, checkpoint: true)
            }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Self.persistenceQueue.async {
                    continuation.resume(with: Result { try Self.persistence.save(snapshot, legacyURL: targetURL) })
                }
            }
        } catch {
            saveDeferredByImport = true
            throw error
        }
        // An unrelated reply can finish while the disk write runs.
        sessions = saveDeferredByImport ? mergeSessions(incoming).sessions : snapshot
        listStore.sync(from: sessions)
        return merged.count
    }

    private static func messageSignature(_ message: ChatMessage) -> String {
        if message.role == .user {
            let files = message.files.map { "\($0.name):\($0.size)" }.joined(separator: ",")
            return "U:\(message.content)|\(files)"
        }
        let textFromBlocks = message.blocks.compactMap { block -> String? in
            if case .text(_, let text, _, _) = block { return text }
            return nil
        }.joined(separator: "\n")
        let text = textFromBlocks.isEmpty ? message.content : textFromBlocks
        return "A:\(text)"
    }

    /// Computes root-to-node path signatures for every message in a session tree (`7d41c2b`),
    /// accurately detecting whether local and imported sessions diverged.
    private static func buildSessionPathSignatures(_ session: ChatSession) -> Set<String> {
        var normalized = session
        normalized.ensureTreeNormalized()
        let byId = Dictionary(uniqueKeysWithValues: normalized.messages.map { ($0.id, $0) })
        var memo: [UUID: String] = [:]
        let maxDepth = normalized.messages.count

        func resolve(_ message: ChatMessage, depth: Int) -> String {
            if let cached = memo[message.id] { return cached }
            let parentPath: String
            if let pid = message.parentId, depth < maxDepth, let parent = byId[pid] {
                parentPath = resolve(parent, depth: depth + 1)
            } else {
                parentPath = ""
            }
            let path = "\(parentPath)>\(messageSignature(message))"
            memo[message.id] = path
            return path
        }

        var paths = Set<String>()
        paths.reserveCapacity(normalized.messages.count)
        for message in normalized.messages {
            paths.insert(resolve(message, depth: 0))
        }
        return paths
    }

    private static func withBranchPrefix(_ title: String, prefix: String) -> String {
        var base = title
        if base.hasPrefix("N分支·") || base.hasPrefix("D分支·") {
            base = String(base.dropFirst(4))
        }
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)\(clean.isEmpty ? "未命名对话" : clean)"
    }

    /// Protected incremental merge matching Android `v0.1.21` (`7d41c2b`):
    /// 1. Incoming behind or equal to local -> skip without overwriting local.
    /// 2. Incoming strictly ahead and local has no unique messages -> overwrite with incoming (preserving pin).
    /// 3. Both local and incoming added distinct messages -> branch into `N分支·` (local) and `D分支·` (new ID).
    private func mergeSessions(_ incoming: [ChatSession]) -> (sessions: [ChatSession], count: Int, changed: Bool) {
        var merged = sessions
        var existingById = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($1.id, $0) })
        var importedCount = 0
        var changed = false

        for item in incoming {
            guard let idx = existingById[item.id] else {
                existingById[item.id] = merged.count
                merged.append(item)
                importedCount += 1
                changed = true
                continue
            }

            let existing = merged[idx]
            let localPaths = Self.buildSessionPathSignatures(existing)
            let incomingPaths = Self.buildSessionPathSignatures(item)
            let localHasExtra = localPaths.contains { !incomingPaths.contains($0) }
            let incomingHasExtra = incomingPaths.contains { !localPaths.contains($0) }

            if !incomingHasExtra {
                // Rule 1: Imported record is behind or equal to local -> skip.
                continue
            }

            if !localHasExtra {
                // Rule 2: Imported record strictly has more than local -> overwrite cleanly, preserving pin state.
                merged[idx].title = item.title
                merged[idx].rootMessageId = item.rootMessageId
                merged[idx].messages = item.messages
                merged[idx].updatedAt = max(existing.updatedAt, item.updatedAt)
                if existing.isPinned || item.isPinned {
                    merged[idx].isPinned = true
                    merged[idx].pinnedAt = existing.pinnedAt ?? item.pinnedAt ?? item.updatedAt
                }
                importedCount += 1
                changed = true
                continue
            }

            // Rule 3: Diverged -> preserve both as independent N/D branches.
            merged[idx].title = Self.withBranchPrefix(existing.title, prefix: "N分支·")
            let incomingBranched = ChatSession(
                id: UUID(),
                title: Self.withBranchPrefix(item.title, prefix: "D分支·"),
                rootMessageId: item.rootMessageId,
                messages: item.messages,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                isPinned: item.isPinned,
                pinnedAt: item.pinnedAt
            )
            existingById[incomingBranched.id] = merged.count
            merged.append(incomingBranched)
            importedCount += 1
            changed = true
        }
        return (merged, importedCount, changed)
    }

    // MARK: - Background Serial Disk Persistence (Never Blocks Main Thread!)

    func flushPendingSave() {
        scheduleSave(immediate: true, checkpoint: true)
    }

    private func scheduleSave(immediate: Bool = false, checkpoint: Bool = false) {
        guard historyLoaded else { return }
        if committingImport {
            saveDeferredByImport = true
            return
        }
        saveWorkItem?.cancel()
        var sessionsToSave = sessions
        if checkpoint, let reply = liveReply.message, let activeSessionId,
           let sIdx = sessionsToSave.firstIndex(where: { $0.id == activeSessionId }),
           let mIdx = sessionsToSave[sIdx].messages.firstIndex(where: { $0.id == reply.id }) {
            sessionsToSave[sIdx].messages[mIdx] = reply
        }
        let snapshot = sessionsToSave
        let targetURL = Self.storageURL
        let work = DispatchWorkItem {
            do {
                try Self.persistence.save(snapshot, legacyURL: targetURL)
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
            let history = Result { try Self.persistence.load(legacyURL: targetURL) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch history {
                case .success(let readySessions):
                    self.sessions = readySessions
                    self.listStore.sync(from: readySessions)
                    self.historyLoaded = true
                case .failure(let error):
                    AppLogStore.shared.record(.error, source: "chatStore.load", message: error.localizedDescription)
                    self.historyLoadFailed = true
                }
            }
        }
    }
}

private struct HistoryUnavailable: LocalizedError {
    var errorDescription: String? { "本地对话记录尚不可用，请稍后重试。" }
}

private struct HistoryImportInProgress: LocalizedError {
    var errorDescription: String? { "正在导入历史对话，请稍候。" }
}
