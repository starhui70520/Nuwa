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

struct SessionImportOutcome: Equatable {
    let addedCount: Int
    let updatedCount: Int
    let branchedCount: Int
    let skippedCount: Int
    let focusSessionId: UUID?

    var importedCount: Int { addedCount + updatedCount + branchedCount }
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
    @Published var pendingIncomingFile: IncomingFileRequest?
    @Published var shareToChatFocusToken = 0
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
    private var pendingAutoImports: [IncomingFileRequest] = []
    private var consumedShareTokens = Set<String>()
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

    func session(byId id: UUID) -> ChatSession? {
        sessions.first { $0.id == id }
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
        ShareSuggestionDonor.donateUsage(mode: .chat)

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
        try await importFromFileWithOutcome(url).importedCount
    }

    func importFromFileWithOutcome(_ url: URL) async throws -> SessionImportOutcome {
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
            if DeepSeekZipImporter.isZipData(data) {
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
                let outcome = try await importFromFileWithOutcome(URL(fileURLWithPath: path))
                if UserDefaults.standard.string(forKey: MigrationWebViewController.keyPendingPath) == path {
                    UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingPath)
                    UserDefaults.standard.removeObject(forKey: MigrationWebViewController.keyPendingName)
                }
                showToast(Self.importSummaryToast(for: outcome, singleShare: false))
                succeeded = true
            } catch {
                AppLogStore.shared.record(.error, source: "migration.import", message: error.localizedDescription)
                showToast("导入失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Incoming External Files (Share Extension App Group, WeChat "Open In", iOS Proximity AirDrop .nuwa)

    /// Unified URL entrypoint for `NuwaApp.onOpenURL`: handles `nuwa://share?token=...` from the
    /// Share Extension (including Row 1 Siri Share Suggestions) as well as direct `.zip`/`.json`/`.nuwa` file URLs.
    func handleIncomingURL(_ url: URL, settings: SettingsStore) {
        if url.scheme?.lowercased() == NuwaShareGroup.urlScheme {
            if url.host?.lowercased() == "share",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
               !token.isEmpty {
                consumeAppGroupShare(token: token, settings: settings)
            } else {
                consumePendingAppGroupShares(settings: settings)
            }
            return
        }
        if url.isFileURL {
            handleIncomingFileURL(url)
        }
    }

    func consumePendingAppGroupShares(settings: SettingsStore) {
        NuwaShareGroup.cleanupStaleInboxEntries()
        guard let inbox = NuwaShareGroup.shareInboxURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return }
        let sorted = entries.sorted { lhs, rhs in
            let d1 = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let d2 = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d1 < d2
        }
        for folder in sorted {
            let manifestURL = NuwaShareGroup.manifestURL(in: folder)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            consumeAppGroupShare(token: folder.lastPathComponent, settings: settings)
        }
    }

    private func consumeAppGroupShare(token: String, settings: SettingsStore) {
        guard !consumedShareTokens.contains(token),
              let folder = NuwaShareGroup.folderURL(forToken: token)
        else { return }
        let manifestURL = NuwaShareGroup.manifestURL(in: folder)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(NuwaShareGroup.HandoffManifest.self, from: data)
        else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        consumedShareTokens.insert(token)
        ShareSuggestionDonor.donateUsage(mode: manifest.mode)

        let fileURLs = manifest.fileNames
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        switch manifest.mode {
        case .import:
            if !fileURLs.isEmpty {
                Task { [weak self] in
                    defer { try? FileManager.default.removeItem(at: folder) }
                    guard let self else { return }
                    if !self.historyLoaded {
                        for _ in 0..<40 where !self.historyLoaded {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    var totalAdded = 0
                    var totalUpdated = 0
                    var totalBranched = 0
                    var totalSkipped = 0
                    var lastFocus: UUID?
                    var lastError: Error?
                    for fileURL in fileURLs {
                        do {
                            let outcome = try await self.importFromFileWithOutcome(fileURL)
                            totalAdded += outcome.addedCount
                            totalUpdated += outcome.updatedCount
                            totalBranched += outcome.branchedCount
                            totalSkipped += outcome.skippedCount
                            if let focus = outcome.focusSessionId { lastFocus = focus }
                        } catch {
                            lastError = error
                            AppLogStore.shared.record(.error, source: "shareExt.import", message: error.localizedDescription)
                        }
                    }
                    let combined = SessionImportOutcome(
                        addedCount: totalAdded,
                        updatedCount: totalUpdated,
                        branchedCount: totalBranched,
                        skippedCount: totalSkipped,
                        focusSessionId: lastFocus
                    )
                    let singleNuwa = fileURLs.count == 1
                        && fileURLs[0].pathExtension.lowercased() == NuwaShareTypes.sessionExtension
                    if combined.importedCount > 0 || lastError == nil {
                        if (singleNuwa || combined.importedCount == 1), let focusId = combined.focusSessionId {
                            self.activeSessionId = focusId
                        }
                        self.showToast(Self.importSummaryToast(for: combined, singleShare: singleNuwa || combined.importedCount == 1))
                    } else if let lastError {
                        self.showToast("导入失败：\(lastError.localizedDescription)")
                    }
                }
            } else if let text = manifest.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                try? FileManager.default.removeItem(at: folder)
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.importFromShareLink(text)
                        self.showToast("已导入分享对话")
                    } catch {
                        self.showToast("导入失败：\(error.localizedDescription)")
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: folder)
                showToast("未找到可导入的对话备份文件")
            }

        case .chat:
            shareToChatFocusToken += 1
            guard settings.hasActiveCredential else {
                try? FileManager.default.removeItem(at: folder)
                showToast("请先登录 DeepSeek 账号或配置 API Key 后再添加到对话")
                return
            }
            let targetSession = activeSessionId
            if let text = manifest.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let existingText = draftStore.draft(for: targetSession).text
                let mergedText = existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? text
                    : "\(existingText)\n\(text)"
                draftStore.setText(mergedText, for: targetSession)
            }
            guard !fileURLs.isEmpty else {
                try? FileManager.default.removeItem(at: folder)
                if !(manifest.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    showToast("已添加到当前对话")
                }
                return
            }
            let currentCount = draftStore.draft(for: targetSession).attachments.count
            let remainingSlots = max(0, AttachmentStore.maxCount - currentCount)
            guard remainingSlots > 0 else {
                try? FileManager.default.removeItem(at: folder)
                showToast("上传文件最多支持 \(AttachmentStore.maxCount) 个")
                return
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                defer { try? FileManager.default.removeItem(at: folder) }
                var toAttach: [(name: String, data: Data, isImage: Bool)] = []
                var skipped = 0
                var hadZip = false
                for fileURL in fileURLs {
                    guard toAttach.count < remainingSlots else {
                        skipped += 1
                        continue
                    }
                    guard let fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe), !fileData.isEmpty else {
                        skipped += 1
                        continue
                    }
                    let name = fileURL.lastPathComponent
                    if name.lowercased().hasSuffix(".zip") || DeepSeekZipImporter.isZipData(fileData) {
                        hadZip = true
                        let slotsLeft = max(0, remainingSlots - toAttach.count)
                        if let extracted = try? DeepSeekZipImporter.extractFilesForChat(fileData, maxFiles: slotsLeft) {
                            for item in extracted.files {
                                toAttach.append((item.fileName, item.data, item.isImage))
                            }
                            skipped += extracted.skippedUnsupported + extracted.skippedOversized + extracted.truncatedByLimit
                        } else {
                            skipped += 1
                        }
                    } else {
                        toAttach.append((name, fileData, AttachmentStore.isImageName(name)))
                    }
                }
                let readyFiles = toAttach
                let skippedCount = skipped
                let extractedZip = hadZip
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard !readyFiles.isEmpty else {
                        self.showToast(extractedZip ? "压缩包内没有可直接用于对话的文档、代码或图片" : "无法读取分享的文件")
                        return
                    }
                    for item in readyFiles {
                        self.draftStore.addFile(
                            data: item.data,
                            fileName: item.name,
                            isImage: item.isImage,
                            for: targetSession,
                            settings: settings,
                            onToast: { self.showToast($0) }
                        )
                    }
                    if extractedZip {
                        if skippedCount > 0 {
                            self.showToast("已解压并添加 \(readyFiles.count) 个文件到对话（跳过 \(skippedCount) 个不支持或超限项）")
                        } else {
                            self.showToast("已解压并添加 \(readyFiles.count) 个文件到对话")
                        }
                    } else {
                        self.showToast(readyFiles.count == 1 ? "已将「\(readyFiles[0].name)」添加到对话" : "已添加 \(readyFiles.count) 个文件到对话")
                    }
                }
            }

        case .ask:
            if let first = fileURLs.first {
                handleIncomingFileURL(first)
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Handles files opened into Nuwa via iOS `onOpenURL` (e.g. WeChat "用其他应用打开" `.zip`/`.json`,
    /// or iOS proximity AirDrop / 碰一碰 `.nuwa` session share).
    func handleIncomingFileURL(_ url: URL) {
        guard url.isFileURL else { return }
        let fileName = url.lastPathComponent.isEmpty ? "file.zip" : url.lastPathComponent
        let ext = (fileName as NSString).pathExtension.lowercased()

        // Copy synchronously while iOS grants temporary security-scoped access.
        let accessed = url.startAccessingSecurityScopedResource()
        let tempDir = NuwaShareTypes.incomingTempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = tempDir.appendingPathComponent(fileName)
        let copySucceeded: Bool
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.removeItem(at: stagedURL)
            }
            try FileManager.default.copyItem(at: url, to: stagedURL)
            copySucceeded = true
        } catch {
            AppLogStore.shared.record(.error, source: "incoming.copy", message: error.localizedDescription)
            try? FileManager.default.removeItem(at: tempDir)
            copySucceeded = false
        }
        if accessed {
            url.stopAccessingSecurityScopedResource()
        }
        if copySucceeded && url.path.contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
        guard copySucceeded else {
            showToast("无法读取外部传入的文件")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let data = (try? Data(contentsOf: stagedURL, options: .mappedIfSafe)) ?? Data()
            let fileSize = data.count
            let isZipMagic = DeepSeekZipImporter.isZipData(data)

            let kind: IncomingFileRequest.Kind
            if ext == NuwaShareTypes.sessionExtension {
                kind = .nuwaSession
            } else if ext == "zip" || isZipMagic {
                kind = .zipArchive
            } else {
                kind = .jsonDocument
            }

            var isLikelyBackup = false
            var backupSessionCount = 0
            var extractableFileCount = 1

            if kind == .nuwaSession || kind == .zipArchive {
                let inspection = DeepSeekZipImporter.inspectZipData(data)
                isLikelyBackup = inspection.isNuwaOrDeepSeekBackup
                backupSessionCount = inspection.backupSessionCount
                extractableFileCount = inspection.extractableFileCount
            } else if kind == .jsonDocument {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let archive = try? decoder.decode(NuwaBackupArchive.self, from: data), !archive.sessions.isEmpty {
                    isLikelyBackup = true
                    backupSessionCount = archive.sessions.count
                }
            }

            let request = IncomingFileRequest(
                localURL: stagedURL,
                tempDirectory: tempDir,
                fileName: fileName,
                fileSize: fileSize,
                kind: kind,
                isLikelyBackup: isLikelyBackup,
                backupSessionCount: backupSessionCount,
                extractableFileCount: extractableFileCount
            )

            await MainActor.run { [weak self] in
                guard let self else {
                    request.cleanup()
                    return
                }
                if request.kind == .nuwaSession {
                    if self.historyLoaded {
                        self.runIncomingArchiveImport(request, autoSwitch: true)
                    } else {
                        self.pendingAutoImports.append(request)
                    }
                } else {
                    self.pendingIncomingFile?.cleanup()
                    self.pendingIncomingFile = request
                }
            }
        }
    }

    func consumePendingAutoImports() {
        guard historyLoaded, !pendingAutoImports.isEmpty else { return }
        let queued = pendingAutoImports
        pendingAutoImports.removeAll()
        Task {
            for request in queued {
                await executeIncomingArchiveImport(request, autoSwitch: true)
            }
        }
    }

    func dismissPendingIncomingFile() {
        pendingIncomingFile?.cleanup()
        pendingIncomingFile = nil
    }

    func importPendingIncomingFile(_ request: IncomingFileRequest) {
        if pendingIncomingFile?.id == request.id {
            pendingIncomingFile = nil
        }
        runIncomingArchiveImport(request, autoSwitch: request.backupSessionCount == 1)
    }

    /// Handles the "对话" choice on an incoming `.zip` or `.json` file (unpacking readable files from ZIP
    /// or attaching JSON directly into the current chat composer draft).
    func attachIncomingFileToChat(_ request: IncomingFileRequest, settings: SettingsStore) {
        if pendingIncomingFile?.id == request.id {
            pendingIncomingFile = nil
        }
        guard settings.hasActiveCredential else {
            request.cleanup()
            showToast("请先登录 DeepSeek 账号或配置 API Key 后再添加到对话")
            return
        }
        let targetSession = activeSessionId
        let currentCount = draftStore.draft(for: targetSession).attachments.count
        let remainingSlots = max(0, AttachmentStore.maxCount - currentCount)

        if request.kind == .jsonDocument {
            Task.detached(priority: .userInitiated) { [weak self] in
                defer { request.cleanup() }
                guard let data = try? Data(contentsOf: request.localURL), !data.isEmpty else {
                    await MainActor.run { [weak self] in
                        self?.showToast("无法读取文件：\(request.fileName)")
                    }
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.draftStore.addFile(
                        data: data,
                        fileName: request.fileName,
                        isImage: false,
                        for: targetSession,
                        settings: settings,
                        onToast: { self.showToast($0) }
                    )
                    self.showToast("已将「\(request.fileName)」添加到当前对话")
                }
            }
            return
        }

        guard remainingSlots > 0 else {
            request.cleanup()
            showToast("上传文件最多支持 \(AttachmentStore.maxCount) 个")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            defer { request.cleanup() }
            do {
                let data = try Data(contentsOf: request.localURL, options: .mappedIfSafe)
                let extracted = try DeepSeekZipImporter.extractFilesForChat(data, maxFiles: remainingSlots)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard !extracted.files.isEmpty else {
                        self.showToast("压缩包内没有可直接用于对话的文档、代码或图片")
                        return
                    }
                    for item in extracted.files {
                        self.draftStore.addFile(
                            data: item.data,
                            fileName: item.fileName,
                            isImage: item.isImage,
                            for: targetSession,
                            settings: settings,
                            onToast: { self.showToast($0) }
                        )
                    }
                    let skipped = extracted.skippedUnsupported + extracted.skippedOversized + extracted.truncatedByLimit
                    if skipped > 0 {
                        self.showToast("已解压并添加 \(extracted.files.count) 个文件到对话（跳过 \(skipped) 个不支持或超限项）")
                    } else {
                        self.showToast("已解压并添加 \(extracted.files.count) 个文件到对话")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    AppLogStore.shared.record(.error, source: "zip.chatExtract", message: error.localizedDescription)
                    self?.showToast("无法解压该压缩包（可能已加密或已损坏）")
                }
            }
        }
    }

    private func runIncomingArchiveImport(_ request: IncomingFileRequest, autoSwitch: Bool) {
        Task {
            await executeIncomingArchiveImport(request, autoSwitch: autoSwitch)
        }
    }

    private func executeIncomingArchiveImport(_ request: IncomingFileRequest, autoSwitch: Bool) async {
        defer { request.cleanup() }
        if !historyLoaded {
            for _ in 0..<40 where !historyLoaded {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            let outcome = try await importFromFileWithOutcome(request.localURL)
            if autoSwitch, let focusId = outcome.focusSessionId {
                activeSessionId = focusId
            }
            showToast(Self.importSummaryToast(for: outcome, singleShare: request.kind == .nuwaSession || autoSwitch))
        } catch {
            AppLogStore.shared.record(.error, source: "incoming.import", message: error.localizedDescription)
            showToast("导入失败：\(error.localizedDescription)")
        }
    }

    func handlePickedAttachmentZipURL(_ url: URL, settings: SettingsStore) {
        let fileName = url.lastPathComponent.isEmpty ? "archive.zip" : url.lastPathComponent
        let accessed = url.startAccessingSecurityScopedResource()
        let tempDir = NuwaShareTypes.incomingTempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = tempDir.appendingPathComponent(fileName)
        let copied: Bool
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: stagedURL)
            copied = true
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            copied = false
        }
        if accessed { url.stopAccessingSecurityScopedResource() }
        guard copied else {
            showToast("无法读取压缩包：\(fileName)")
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = (try? Data(contentsOf: stagedURL, options: .mappedIfSafe)) ?? Data()
            let inspection = DeepSeekZipImporter.inspectZipData(data)
            let request = IncomingFileRequest(
                localURL: stagedURL,
                tempDirectory: tempDir,
                fileName: fileName,
                fileSize: data.count,
                kind: .zipArchive,
                isLikelyBackup: inspection.isNuwaOrDeepSeekBackup,
                backupSessionCount: inspection.backupSessionCount,
                extractableFileCount: inspection.extractableFileCount
            )
            await MainActor.run { [weak self] in
                guard let self else {
                    request.cleanup()
                    return
                }
                if request.isLikelyBackup {
                    self.pendingIncomingFile?.cleanup()
                    self.pendingIncomingFile = request
                } else {
                    self.attachIncomingFileToChat(request, settings: settings)
                }
            }
        }
    }

    static func importSummaryToast(for outcome: SessionImportOutcome, singleShare: Bool) -> String {
        if outcome.importedCount == 0 {
            return "本地已是最新记录，未覆盖任何对话"
        }
        if singleShare && outcome.importedCount == 1 {
            if outcome.branchedCount > 0 {
                return "存在历史分叉，已保留「N分支·」与「D分支·」"
            }
            if outcome.updatedCount > 0 {
                return "已同步更新该对话的新增记录"
            }
            return "已接收并导入分享对话"
        }
        if outcome.branchedCount > 0 {
            return "已导入 \(outcome.importedCount) 个对话（含 \(outcome.branchedCount) 个分叉分支）"
        }
        return outcome.importedCount == 1 ? "已导入 1 个对话" : "已导入 \(outcome.importedCount) 个对话"
    }

    func importFromShareLink(_ input: String) async throws -> ChatSession {
        guard historyLoaded else { throw HistoryUnavailable() }
        guard !importingHistory else { throw HistoryImportInProgress() }
        importingHistory = true
        defer { importingHistory = false }
        do {
            let session = try await ShareLinkImporter.fetchSharedSession(input: input)
            stopGenerating()
            let outcome = try await commitImportedSessions([session])
            activeSessionId = outcome.focusSessionId ?? session.id
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

    private func commitImportedSessions(_ incoming: [ChatSession]) async throws -> SessionImportOutcome {
        if isGenerating, incoming.contains(where: { $0.id == activeSessionId }) { stopGenerating() }
        let merged = mergeSessions(incoming)
        guard merged.changed else { return merged.outcome }

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
        ShareSuggestionDonor.donateUsage(mode: .import)
        return merged.outcome
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

    /// Dual 32-bit FNV-1a rolling hash matching Android `db.ts` (`hashStep`) bit-for-bit,
    /// compressing arbitrary-length histories into 16-hex-char digests in O(N) time & memory.
    private static func hashStep(seed: String, text: String) -> String {
        var h1: UInt32 = 0x811c9dc5
        var h2: UInt32 = 0x01000193
        for unit in seed.utf16 {
            let c = UInt32(unit)
            h1 = (h1 ^ c) &* 0x01000193
            h2 = (h2 ^ (c &+ 17)) &* 0x85ebca6b
        }
        h1 = (h1 ^ 0x3e) &* 0x01000193
        h2 = (h2 ^ 0x3e) &* 0x85ebca6b
        for unit in text.utf16 {
            let c = UInt32(unit)
            h1 = (h1 ^ c) &* 0x01000193
            h2 = (h2 ^ (c &+ 31)) &* 0x85ebca6b
        }
        return String(format: "%08x%08x", h1, h2)
    }

    /// Iterative O(N) root-to-node path hash set matching Android `db.ts` (`buildSessionPathSignatures`),
    /// avoiding recursion stack overflow and O(N^2) string memory on long conversations.
    private static func buildSessionPathSignatures(_ session: ChatSession) -> Set<String> {
        var normalized = session
        normalized.ensureTreeNormalized()
        let byId = Dictionary(uniqueKeysWithValues: normalized.messages.map { ($0.id, $0) })
        var memo = [UUID: String](minimumCapacity: normalized.messages.count)
        var paths = Set<String>()
        paths.reserveCapacity(normalized.messages.count)

        for start in normalized.messages {
            if memo[start.id] != nil { continue }
            var chain: [ChatMessage] = []
            var seen = Set<UUID>()
            var cur: ChatMessage? = start
            while let node = cur, memo[node.id] == nil, !seen.contains(node.id) {
                seen.insert(node.id)
                chain.append(node)
                cur = node.parentId.flatMap { byId[$0] }
            }
            var parentHash = cur.flatMap { memo[$0.id] } ?? ""
            for node in chain.reversed() {
                let digest = hashStep(seed: parentHash, text: messageSignature(node))
                memo[node.id] = digest
                paths.insert(digest)
                parentHash = digest
            }
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

    /// Preserves local attachment file references / serverIds on messages carried over when updating a session.
    private static func carryOverLocalAttachments(from existing: ChatSession, into incomingMessages: [ChatMessage]) -> [ChatMessage] {
        var localById: [String: FileAttachment] = [:]
        var localByNameSize: [String: FileAttachment] = [:]
        for msg in existing.messages where msg.role == .user {
            for file in msg.files where file.localFileName != nil || file.serverId != nil {
                localById[file.id] = file
                localByNameSize["\(file.name):\(file.size)"] = file
            }
        }
        guard !localById.isEmpty else { return incomingMessages }
        return incomingMessages.map { msg in
            guard msg.role == .user, !msg.files.isEmpty else { return msg }
            var updated = msg
            updated.files = msg.files.map { file in
                guard let prev = localById[file.id] ?? localByNameSize["\(file.name):\(file.size)"] else {
                    return file
                }
                var copy = file
                if copy.localFileName == nil { copy.localFileName = prev.localFileName }
                if copy.serverId == nil { copy.serverId = prev.serverId }
                if copy.mimeType.isEmpty { copy.mimeType = prev.mimeType }
                return copy
            }
            return updated
        }
    }

    /// Protected incremental merge with 1:1 parity to Android `db.ts` (`mergeStaging`):
    /// Given identical session ID:
    /// 1. Local == Incoming -> skip without overwriting.
    /// 2. Local newer than Incoming (local strictly ahead, incoming has no extra) -> skip without overwriting.
    /// 3. Local behind Incoming (incoming has extra and local has no unique branch) -> import the extra messages.
    /// 4. Partially overlapping / diverged (both sides have distinct messages) -> do NOT merge; preserve local as
    ///    `N分支·` and create independent incoming branch with new ID as `D分支·`.
    private func mergeSessions(_ incoming: [ChatSession]) -> (sessions: [ChatSession], outcome: SessionImportOutcome, changed: Bool) {
        var merged = sessions
        var existingById = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($1.id, $0) })
        var addedCount = 0
        var updatedCount = 0
        var branchedCount = 0
        var skippedCount = 0
        var focusSessionId: UUID?
        var changed = false

        for item in incoming {
            guard let idx = existingById[item.id] else {
                existingById[item.id] = merged.count
                merged.append(item)
                addedCount += 1
                focusSessionId = item.id
                changed = true
                continue
            }

            let existing = merged[idx]
            let localPaths = Self.buildSessionPathSignatures(existing)
            let incomingPaths = Self.buildSessionPathSignatures(item)
            let localHasExtra = localPaths.contains { !incomingPaths.contains($0) }
            let incomingHasExtra = incomingPaths.contains { !localPaths.contains($0) }

            if !incomingHasExtra {
                // Rules 1 & 2: Local is identical to or newer than imported data -> skip without overwriting.
                skippedCount += 1
                focusSessionId = focusSessionId ?? existing.id
                continue
            }

            if !localHasExtra {
                // Rule 3: Local is behind imported data -> update with incoming messages (preserving local attachments & pin).
                let nextTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existing.title : item.title
                merged[idx].title = nextTitle
                merged[idx].rootMessageId = item.rootMessageId
                merged[idx].messages = Self.carryOverLocalAttachments(from: existing, into: item.messages)
                merged[idx].updatedAt = max(existing.updatedAt, item.updatedAt)
                if existing.isPinned || item.isPinned {
                    merged[idx].isPinned = true
                    merged[idx].pinnedAt = existing.pinnedAt ?? item.pinnedAt ?? item.updatedAt
                }
                updatedCount += 1
                focusSessionId = existing.id
                changed = true
                continue
            }

            // Rule 4: Both sides diverged -> do NOT merge; preserve local (`N分支·`) and incoming (`D分支·`) as 2 branches.
            // Guard against accidental duplicate re-import of the exact same already-branched `D分支·` conversation.
            if let existingDuplicateBranch = merged.first(where: {
                $0.title.hasPrefix("D分支·") && Self.buildSessionPathSignatures($0) == incomingPaths
            }) {
                skippedCount += 1
                focusSessionId = focusSessionId ?? existingDuplicateBranch.id
                continue
            }

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
            branchedCount += 1
            focusSessionId = incomingBranched.id
            changed = true
        }
        let outcome = SessionImportOutcome(
            addedCount: addedCount,
            updatedCount: updatedCount,
            branchedCount: branchedCount,
            skippedCount: skippedCount,
            focusSessionId: focusSessionId
        )
        return (merged, outcome, changed)
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
                    self.consumePendingAutoImports()
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
