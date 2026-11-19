import SwiftUI
import UniformTypeIdentifiers

private struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var chatStore: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showApiKey = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: BackupDocument?

    @State private var isCheckingUpdate = false
    @State private var updateResult: AppUpdateResult?
    @State private var updateAlertPresented = false
    @State private var updateErrorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("快速预设") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ProviderPreset.presets) { preset in
                                Button {
                                    settings.applyPreset(preset)
                                } label: {
                                    Text(preset.name)
                                        .font(.footnote.weight(.medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .nuwaGlass(
                                            in: Capsule(),
                                            tint: settings.apiBaseUrl == preset.baseUrl ? .nuwaBrand : nil,
                                            interactive: true
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Picker("接口协议", selection: $settings.apiProtocol) {
                        ForEach(ApiProtocol.allCases) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }

                    TextField("API Base URL", text: $settings.apiBaseUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        if showApiKey {
                            TextField("API Key (sk-...)", text: $settings.apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("API Key (sk-...)", text: $settings.apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            showApiKey.toggle()
                        } label: {
                            Image(systemName: showApiKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField("模型名称（如 deepseek-chat）", text: $settings.apiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("模型与 API 配置")
                } footer: {
                    Text("API Key 仅加密保存在本机 iOS 钥匙串（Keychain）中，不会上传至第三方服务器。")
                }

                if settings.isDeepSeekOfficial && settings.isConfigured {
                    Section("DeepSeek 余额") {
                        HStack {
                            Text("当前可用余额")
                            Spacer()
                            if settings.isLoadingBalance {
                                ProgressView()
                            } else {
                                Text(settings.deepSeekBalanceText ?? "点击查询")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await settings.refreshBalance() }
                        }
                    }
                }

                Section("外观与阅读") {
                    Picker("主题模式", selection: $settings.themePreference) {
                        ForEach(ThemePreference.allCases) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("正文字号")
                            Spacer()
                            Text("\(Int(settings.chatFontSize)) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.chatFontSize, in: 12...22, step: 1)
                    }
                }

                Section("系统提示词（可选）") {
                    TextField("自定义 System Prompt...", text: $settings.systemPrompt, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("数据备份（本地 / iCloud 云盘）") {
                    Button {
                        if let data = try? chatStore.exportBackupData() {
                            exportDocument = BackupDocument(data: data)
                            isExporting = true
                        }
                    } label: {
                        Label("导出全部历史会话（JSON）", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isImporting = true
                    } label: {
                        Label("从文件 / iCloud 导入备份", systemImage: "square.and.arrow.down")
                    }
                }

                Section("关于与更新（iOS）") {
                    HStack {
                        Text("当前版本")
                        Spacer()
                        Text("v\(AppUpdateService.currentVersion) (\(AppUpdateService.buildNumber))")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await checkUpdates() }
                    } label: {
                        HStack {
                            Label("检查 App Store 更新", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isCheckingUpdate {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isCheckingUpdate)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "nuwa-backup-\(Int(Date().timeIntervalSince1970))"
            ) { result in
                switch result {
                case .success:
                    chatStore.showToast("备份已导出")
                case .failure(let error):
                    chatStore.showToast("导出失败：\(error.localizedDescription)")
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        let count = try chatStore.importBackupData(data)
                        chatStore.showToast("已导入 \(count) 条新会话")
                    } catch {
                        chatStore.showToast("导入失败：\(error.localizedDescription)")
                    }
                case .failure(let error):
                    chatStore.showToast("选择文件失败：\(error.localizedDescription)")
                }
            }
            .alert("版本检查", isPresented: $updateAlertPresented) {
                if let url = updateResult?.storeUrl, updateResult?.hasUpdate == true {
                    Button("前往 App Store") { openURL(url) }
                }
                Button("好的", role: .cancel) {}
            } message: {
                if let updateErrorText {
                    Text(updateErrorText)
                } else if let res = updateResult {
                    if res.hasUpdate {
                        Text("发现新版本 v\(res.latestVersion)（当前 v\(res.currentVersion)）。\n\(res.releaseNotes)")
                    } else {
                        Text("当前 v\(res.currentVersion) (\(res.buildNumber)) 已是最新版本。\n\(res.releaseNotes)")
                    }
                }
            }
        }
    }

    private func checkUpdates() async {
        isCheckingUpdate = true
        updateErrorText = nil
        defer { isCheckingUpdate = false }
        do {
            updateResult = try await AppUpdateService.checkAppStoreUpdate()
            updateAlertPresented = true
        } catch {
            updateErrorText = "检查更新失败：\(error.localizedDescription)"
            updateAlertPresented = true
        }
    }
}
