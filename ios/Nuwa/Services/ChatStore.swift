import Foundation
import SwiftUI

@MainActor
final class ChatStore: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var activeSessionId: UUID?
    @Published var isGenerating = false
    @Published var importingHistory = false
    @Published var toastMessage: String?

    private var activeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    private var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Nuwa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    init() {
        load()
        if let first = sortedSessions.first {
            activeSessionId = first.id
        }
    }

    var sortedSessions: [ChatSession] {
        sessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var activeSession: ChatSession? {
        guard let activeSessionId else { return nil }
        return sessions.first { $0.id == activeSessionId }
    }

    @discardableResult
    func createNewSession(silentIfAlreadyNew: Bool = false) -> ChatSession? {
        stopGenerating()
        if activeSessionId == nil || (activeSession?.messages.isEmpty == true) {
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
        save()
    }

    func setSessionsPinned(_ ids: Set<UUID>, pinned: Bool) {
        var changed = false
        for idx in sessions.indices where ids.contains(sessions[idx].id) {
            if sessions[idx].isPinned != pinned {
                sessions[idx].isPinned = pinned
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    func renameSession(_ id: UUID, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = clean
        sessions[idx].updatedAt = Date()
        save()
    }

    func deleteSession(_ id: UUID) {
        if activeSessionId == id {
            stopGenerating()
            activeSessionId = nil
        }
        sessions.removeAll { $0.id == id }
        save()
    }

    func deleteSessions(_ ids: Set<UUID>) {
        if let active = activeSessionId, ids.contains(active) {
            stopGenerating()
            activeSessionId = nil
        }
        sessions.removeAll { ids.contains($0.id) }
        save()
    }

    func deleteAllSessions() {
        stopGenerating()
        sessions.removeAll()
        activeSessionId = nil
        save()
    }

    func stopGenerating() {
        activeTask?.cancel()
        activeTask = nil
        isGenerating = false
        if let sIdx = sessions.firstIndex(where: { $0.id == activeSessionId }) {
            for mIdx in sessions[sIdx].messages.indices where sessions[sIdx].messages[mIdx].isStreaming {
                sessions[sIdx].messages[mIdx].isStreaming = false
            }
            save()
        }
    }

    func send(prompt: String, settings: SettingsStore) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

        if activeSessionId == nil || !sessions.contains(where: { $0.id == activeSessionId }) {
            let fresh = ChatSession(title: String(trimmed.prefix(24)))
            sessions.insert(fresh, at: 0)
            activeSessionId = fresh.id
        }

        guard let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }

        let userMsg = ChatMessage(role: .user, content: trimmed)
        sessions[sIdx].messages.append(userMsg)
        if sessions[sIdx].title == "新对话" {
            sessions[sIdx].title = String(trimmed.prefix(24))
        }
        sessions[sIdx].updatedAt = Date()

        let historySnapshot = sessions[sIdx].messages
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        sessions[sIdx].messages.append(assistantMsg)
        save()

        streamReply(
            sessionId: sessionId,
            assistantId: assistantMsg.id,
            history: historySnapshot,
            settings: settings
        )
    }

    func regenerateLast(settings: SettingsStore) {
        guard !isGenerating,
              let sessionId = activeSessionId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }

        if sessions[sIdx].messages.last?.role == .assistant {
            sessions[sIdx].messages.removeLast()
        }
        guard sessions[sIdx].messages.last?.role == .user else { return }

        let historySnapshot = sessions[sIdx].messages
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        sessions[sIdx].messages.append(assistantMsg)
        save()

        streamReply(
            sessionId: sessionId,
            assistantId: assistantMsg.id,
            history: historySnapshot,
            settings: settings
        )
    }

    private func streamReply(
        sessionId: UUID,
        assistantId: UUID,
        history: [ChatMessage],
        settings: SettingsStore
    ) {
        isGenerating = true
        let startTime = Date()
        var thinkingFinishedAt: Date?

        let apiProtocol = settings.effectiveProtocol
        let baseUrl = settings.effectiveBaseUrl
        let apiKey = settings.activeSecret
        let model = settings.effectiveModel
        let systemPrompt = settings.systemPrompt
        let thinkingEnabled = settings.thinkingEnabled

        activeTask = Task {
            let stream = AIClient.streamChat(
                messages: history,
                apiProtocol: apiProtocol,
                baseUrl: baseUrl,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                thinkingEnabled: thinkingEnabled
            )
            do {
                for try await event in stream {
                    guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                          let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == assistantId })
                    else { break }

                    switch event {
                    case .reasoning(let chunk):
                        sessions[sIdx].messages[mIdx].reasoning += chunk
                        sessions[sIdx].messages[mIdx].thinkingSeconds = Date().timeIntervalSince(startTime)
                    case .content(let chunk):
                        if !sessions[sIdx].messages[mIdx].reasoning.isEmpty && thinkingFinishedAt == nil {
                            thinkingFinishedAt = Date()
                            sessions[sIdx].messages[mIdx].thinkingSeconds = thinkingFinishedAt!.timeIntervalSince(startTime)
                        }
                        sessions[sIdx].messages[mIdx].content += chunk
                    }
                    sessions[sIdx].updatedAt = Date()
                }
            } catch {
                if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                   let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == assistantId }) {
                    sessions[sIdx].messages[mIdx].errorMessage = error.localizedDescription
                }
            }

            if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
               let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == assistantId }) {
                sessions[sIdx].messages[mIdx].isStreaming = false
            }
            isGenerating = false
            activeTask = nil
            save()
        }
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            toastMessage = message
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                toastMessage = nil
            }
        }
    }

    func exportBackupData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(NuwaBackupArchive(sessions: sessions))
    }

    /// Supports importing both DeepSeek official `.zip` archives and Nuwa `.json` backups.
    func importFromFileData(_ data: Data) throws -> Int {
        // Check ZIP magic header PK\x03\x04
        if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
            let parsed = try DeepSeekZipImporter.parseZipData(data)
            return mergeSessions(parsed)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(NuwaBackupArchive.self, from: data)
        return mergeSessions(archive.sessions)
    }

    func importFromFilePath(_ path: String) {
        importingHistory = true
        Task {
            defer { importingHistory = false }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let count = try importFromFileData(data)
                showToast(count == 1 ? "已导入 1 个对话" : "已导入 \(count) 个对话")
            } catch {
                showToast("导入失败：\(error.localizedDescription)")
            }
        }
    }

    private func mergeSessions(_ incoming: [ChatSession]) -> Int {
        var existingById = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, $0) })
        var importedCount = 0
        for item in incoming {
            if let idx = existingById[item.id] {
                if item.updatedAt > sessions[idx].updatedAt || item.messages.count > sessions[idx].messages.count {
                    sessions[idx].title = item.title
                    sessions[idx].messages = item.messages
                    sessions[idx].updatedAt = max(sessions[idx].updatedAt, item.updatedAt)
                }
            } else {
                existingById[item.id] = sessions.count
                sessions.append(item)
                importedCount += 1
            }
        }
        save()
        return importedCount
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            // Keep running even if disk write fails
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ChatSession].self, from: data) {
            sessions = decoded
        }
    }
}
