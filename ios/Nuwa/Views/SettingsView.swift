import SwiftUI
import UniformTypeIdentifiers

private enum SettingsSubpage {
    case root
    case account
    case data
    case location
    case changelog
    case feedback
}

private struct ZipBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ReleaseHistoryEntry: Identifiable {
    let id: String
    let version: String
    let changelog: String
    let createdAt: String
}

/// Complete 1:1 recreation of chat-demo/src/components/settings/SettingsDialog.tsx
/// (Account / Balance / Data + Share Link Import + DeepSeek ZIP Export + iCloud Auto Backup /
///  Language / Appearance / Font Size / Location / Voice & Engine / Version & App Store Check /
///  Release Notes / Feedback & Log Reporting / Docs / Sign Out).
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var chatStore: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var page: SettingsSubpage = .root
    @State private var showApiKey = false
    @State private var apiKeyDraft = ""
    @State private var verifyingKey = false
    @State private var keyVerifyError: String?

    @State private var showDeepSeekAuth = false
    @State private var migrationOptions: MigrationLaunchOptions?
    @State private var showMigrationChooser = false
    @State private var showShareLinkAlert = false
    @State private var shareLinkDraft = ""
    @State private var importingShareLink = false

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: ZipBackupDocument?
    @State private var showDeleteAllConfirm = false
    @State private var showSignOutConfirm = false

    @State private var isCheckingUpdate = false
    @State private var updateResult: AppUpdateResult?
    @State private var updateAlertPresented = false
    @State private var updateErrorText: String?

    @State private var changelogItems: [ReleaseHistoryEntry] = []
    @State private var changelogLoading = false
    @State private var changelogFailed = false

    private let docsURL = URL(string: "https://api-docs.deepseek.com/zh-cn/")!
    private let topUpURL = URL(string: "https://platform.deepseek.com/top_up")!

    private var sheetBg: Color {
        colorScheme == .dark
            ? Color(red: 18 / 255, green: 19 / 255, blue: 22 / 255)
            : Color(red: 245 / 255, green: 246 / 255, blue: 248 / 255)
    }

    private var cardBg: Color {
        colorScheme == .dark
            ? Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
            : Color.white
    }

    private var pageTitle: String {
        let loc = settings.locale
        switch page {
        case .root: return L10n.t("settings", locale: loc)
        case .account: return L10n.t("accountManage", locale: loc)
        case .data: return L10n.t("dataManage", locale: loc)
        case .location: return L10n.t("location", locale: loc)
        case .changelog: return L10n.t("releaseNotes", locale: loc)
        case .feedback: return L10n.t("feedbackReport", locale: loc)
        }
    }

    var body: some View {
        ZStack {
            sheetBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header matching SettingsDialog.tsx
                HStack {
                    if page == .root {
                        Color.clear.frame(width: 36, height: 36)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { page = .root }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .frame(width: 36, height: 36)
                                .nuwaGlass(in: Circle(), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(pageTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(maxWidth: .infinity)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .frame(width: 36, height: 36)
                            .nuwaGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch page {
                        case .root: rootPage
                        case .account: accountPage
                        case .data: dataPage
                        case .location: locationPage
                        case .changelog: changelogPage
                        case .feedback: FeedbackReportView(settings: settings, cardBg: cardBg, fieldBg: sheetBg)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
                .nuwaNoScrollEdgeEffect()
            }
        }
        .task {
            apiKeyDraft = settings.apiKey
            await settings.refreshBalance()
        }
        .sheet(isPresented: $showDeepSeekAuth) {
            DeepSeekAuthSheet { token, accountLabel, error in
                showDeepSeekAuth = false
                if let token, !token.isEmpty {
                    settings.signInDeepSeekAccount(token: token, label: accountLabel)
                    chatStore.showToast("已登录 DeepSeek API 账号")
                } else if let error, !error.isEmpty {
                    chatStore.showToast(error)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $migrationOptions) { opts in
            DeepSeekMigrationSheet(clearSession: opts.clearSession, forceReExport: opts.forceReExport) { filePath, _ in
                migrationOptions = nil
                if let filePath {
                    chatStore.importFromFilePath(filePath)
                }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("选择迁移方式", isPresented: $showMigrationChooser, titleVisibility: .visible) {
            Button("重新导出并更新（当前账号）") {
                launchMigration(clearSession: false, forceReExport: true)
            }
            Button("直接下载上次导出（当前账号）") {
                launchMigration(clearSession: false, forceReExport: false)
            }
            Button("切换其他账号（清除登录态）") {
                launchMigration(clearSession: true, forceReExport: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("检测到本地已有会话记录，请选择继续当前账号导出或切换账号。")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .zip,
            defaultFilename: DeepSeekZipExporter.defaultFileName()
        ) { result in
            switch result {
            case .success:
                chatStore.showToast("已导出历史对话 ZIP")
            case .failure(let error):
                chatStore.showToast("导出失败：\(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.zip, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    do {
                        let count = try await chatStore.importFromFile(url)
                        chatStore.showToast(count == 1 ? "已导入 1 个对话" : "已导入 \(count) 个对话")
                    } catch {
                        chatStore.showToast("导入失败：\(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                chatStore.showToast("选择文件失败：\(error.localizedDescription)")
            }
        }
        .alert("通过 DeepSeek 分享链接导入", isPresented: $showShareLinkAlert) {
            TextField("粘贴 chat.deepseek.com/share/... 链接或分享 ID", text: $shareLinkDraft)
            Button("取消", role: .cancel) { shareLinkDraft = "" }
            Button("导入") {
                let raw = shareLinkDraft
                shareLinkDraft = ""
                Task { await runShareLinkImport(raw) }
            }
        } message: {
            Text("支持直接粘贴官方 DeepSeek App 或网页版复制的完整分享文案。")
        }
        .alert("删除后，所有对话都将被清空且无法找回", isPresented: $showDeleteAllConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                chatStore.deleteAllSessions()
                chatStore.showToast("删除成功")
            }
        } message: {
            Text("本地保存的附件及未发送的草稿也将被删除，不会清除您的 API Key。")
        }
        .alert("退出登录", isPresented: $showSignOutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                settings.signOutAll()
                dismiss()
            }
        } message: {
            Text("将清除本地保存的 DeepSeek 账号与 API Key 凭据，历史对话仍保留在设备上。")
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
        .presentationDragIndicator(.visible)
    }

    // MARK: - Root Settings Page (1:1 SettingsDialog.tsx)

    @ViewBuilder
    private var rootPage: some View {
        let loc = settings.locale
        groupTitle(L10n.t("groupAccount", locale: loc))
        groupCard {
            navRow(
                icon: "person",
                label: L10n.t("accountManage", locale: loc),
                value: settings.profileDisplayName
            ) {
                apiKeyDraft = settings.apiKey
                keyVerifyError = nil
                withAnimation(.easeInOut(duration: 0.2)) { page = .account }
            }
            rowDivider
            navRow(
                icon: "creditcard",
                label: L10n.t("apiBalance", locale: loc),
                value: settings.deepSeekBalanceText ?? L10n.t("topUp", locale: loc),
                valueAccent: settings.deepSeekBalanceText != nil,
                valueDanger: settings.isBalanceLow
            ) {
                openURL(topUpURL)
            }
            rowDivider
            navRow(
                icon: "externaldrive",
                label: L10n.t("dataManage", locale: loc),
                value: "\(chatStore.sessions.count) 条对话"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { page = .data }
            }
        }

        groupTitle(L10n.t("groupApp", locale: loc))
        groupCard {
            pickerRow(icon: "globe", label: L10n.t("language", locale: loc)) {
                Picker("语言", selection: $settings.locale) {
                    ForEach(AppLocale.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            rowDivider
            pickerRow(icon: "sun.max", label: L10n.t("appearance", locale: loc)) {
                Picker("外观", selection: $settings.themePreference) {
                    ForEach(ThemePreference.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            rowDivider
            pickerRow(icon: "textformat.size", label: L10n.t("fontSize", locale: loc)) {
                Picker("字体大小", selection: $settings.chatFontSize) {
                    ForEach(SettingsStore.fontSizeOptions, id: \.self) { size in
                        Text(size == 16 ? "16px（默认）" : "\(Int(size))px").tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            rowDivider
            navRow(
                icon: "sparkles",
                label: L10n.t("location", locale: loc),
                value: LocationCatalog.displayName(for: settings.location, locale: loc)
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { page = .location }
            }
            if UIDevice.current.userInterfaceIdiom == .phone {
                let title = loc == .enUS ? "Haptic feedback" : "触感反馈"
                rowDivider
                pickerRow(icon: "waveform.path", label: title) {
                    Toggle(title, isOn: $settings.hapticFeedbackEnabled)
                        .labelsHidden()
                        .accessibilityIdentifier("hapticFeedback")
                }
            }
        }

        groupTitle(L10n.t("groupVoice", locale: loc))
        groupCard {
            pickerRow(icon: "speaker.wave.2", label: L10n.t("ttsVoice", locale: loc)) {
                Picker("朗读音色", selection: $settings.ttsVoice) {
                    ForEach(TtsVoiceOption.allCases) { v in
                        Text(v.displayName).tag(v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            rowDivider
            pickerRow(icon: "waveform", label: L10n.t("speechEngine", locale: loc)) {
                Picker("语音引擎", selection: $settings.speechEngine) {
                    ForEach(SpeechEngineOption.allCases) { eng in
                        Text(eng.displayName).tag(eng)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
        Text("自动模式在配置 API Key 时优先云端朗读，否则无缝使用 iOS 原生语音服务")
            .font(.system(size: 12))
            .foregroundStyle(Color.nuwaLabelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 6)

        groupTitle(L10n.t("groupAbout", locale: loc))
        groupCard {
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(width: 22)
                Text(L10n.t("version", locale: loc))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Spacer()
                Text("v\(AppUpdateService.currentVersion) (\(AppUpdateService.buildNumber))")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.nuwaLabelTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            rowDivider
            navRow(
                icon: "arrow.down.circle",
                label: isCheckingUpdate ? L10n.t("checkingUpdate", locale: loc) : L10n.t("checkUpdate", locale: loc),
                value: nil
            ) {
                if !isCheckingUpdate {
                    Task { await checkUpdates() }
                }
            }
            rowDivider
            navRow(
                icon: "doc.text",
                label: L10n.t("releaseNotes", locale: loc),
                value: nil
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { page = .changelog }
                Task { await loadChangelog() }
            }
            rowDivider
            navRow(
                icon: "exclamationmark.bubble",
                label: L10n.t("feedbackReport", locale: loc),
                value: nil
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { page = .feedback }
            }
            rowDivider
            navRow(
                icon: "book",
                label: L10n.t("docs", locale: loc),
                value: nil
            ) {
                openURL(docsURL)
            }
        }

        groupCard {
            Button {
                showSignOutConfirm = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                        .frame(width: 22)
                    Text(L10n.t("signOut", locale: loc))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
    }

    // MARK: - Subpage: 账号管理

    @ViewBuilder
    private var accountPage: some View {
        groupCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DeepSeek API 账号")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                        if !settings.dshToken.isEmpty {
                            Text(settings.isUsingDeepSeekAccount
                                 ? "当前生效：\(settings.dshAccountLabel.isEmpty ? "DeepSeek API 账号" : settings.dshAccountLabel)"
                                 : "已登录（当前使用自定义 API Key）")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.nuwaLabelTertiary)
                        } else {
                            Text("通过 DeepSeek 开放平台授权登录，免手动复制 API Key")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.nuwaLabelTertiary)
                        }
                    }
                    Spacer()
                    if settings.dshToken.isEmpty {
                        Button("账号登录") {
                            showDeepSeekAuth = true
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.nuwaBrand, in: Capsule())
                    } else {
                        HStack(spacing: 8) {
                            if !settings.isUsingDeepSeekAccount {
                                Button("切换使用") {
                                    settings.authMode = .deepseekAccount
                                    Task { await settings.refreshBalance(force: true) }
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.nuwaBrandText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .nuwaPillSurface(selected: true)
                                .buttonStyle(NuwaTactileButtonStyle())
                            }
                            Button("退出") {
                                settings.signOutDeepSeekAccount()
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .nuwaPillSurface(destructive: true)
                            .buttonStyle(NuwaTactileButtonStyle())
                        }
                    }
                }
            }
            .padding(16)
        }
        .padding(.top, 8)

        groupTitle("自定义 API 配置")
        groupCard {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ProviderPreset.presets) { preset in
                            let selected = settings.apiBaseUrl == preset.baseUrl && settings.apiProtocol == preset.apiProtocol
                            Button {
                                settings.applyPreset(preset)
                            } label: {
                                Text(preset.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(selected ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .nuwaPillSurface(selected: selected)
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        }
                    }
                }

                HStack {
                    Text("接口协议")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Spacer()
                    Picker("接口协议", selection: $settings.apiProtocol) {
                        ForEach(ApiProtocol.allCases) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                labeledInput("API 地址 (Base URL)", placeholder: "https://api.deepseek.com", text: $settings.apiBaseUrl)
                labeledInput("模型名称", placeholder: "deepseek-flash", text: $settings.apiModel)

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                    HStack {
                        Group {
                            if showApiKey {
                                TextField("sk-...", text: $apiKeyDraft)
                            } else {
                                SecureField("sk-...", text: $apiKeyDraft)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14))

                        Button {
                            showApiKey.toggle()
                        } label: {
                            Image(systemName: showApiKey ? "eye.slash" : "eye")
                                .foregroundStyle(Color.nuwaLabelTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(sheetBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let keyVerifyError {
                    Text(keyVerifyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await verifyAndSaveApiKey() }
                } label: {
                    HStack(spacing: 8) {
                        if verifyingKey {
                            ProgressView().tint(.white).controlSize(.small)
                        }
                        Text(verifyingKey ? "正在验证..." : "验证并保存 API Key")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(
                        (verifyingKey || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            ? Color.nuwaBrand.opacity(0.4)
                            : Color.nuwaBrand,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(verifyingKey || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
    }

    // MARK: - Subpage: 数据管理

    @ViewBuilder
    private var dataPage: some View {
        groupCard {
            actionCell(
                title: "一键迁移 DeepSeek 历史",
                subtitle: "登录官方网页端自动触发导出并合并到本机",
                buttonTitle: "一键导入",
                primary: true
            ) {
                if settings.hasUsedOneClickMigration || !chatStore.sessions.isEmpty {
                    showMigrationChooser = true
                } else {
                    launchMigration(clearSession: false, forceReExport: false)
                }
            }
            rowDivider
            actionCell(
                title: "通过分享链接导入",
                subtitle: "粘贴官方 DeepSeek 分享链接或分享 ID，将对话保存到本机",
                buttonTitle: importingShareLink ? "导入中..." : "链接导入"
            ) {
                if !importingShareLink {
                    showShareLinkAlert = true
                }
            }
            rowDivider
            actionCell(
                title: "导入历史对话",
                subtitle: "支持 DeepSeek 官方导出 ZIP 或 Nuwa JSON，按 ID 增量合并",
                buttonTitle: "导入"
            ) {
                isImporting = true
            }
            rowDivider
            actionCell(
                title: "导出所有历史对话",
                subtitle: "导出标准 DeepSeek 格式 ZIP，可备份到 iCloud Drive 或导入其他端",
                buttonTitle: "备份到 iCloud"
            ) {
                Task {
                    do {
                        let data = try await chatStore.exportDeepSeekZipDataAsync()
                        exportDocument = ZipBackupDocument(data: data)
                        isExporting = true
                    } catch {
                        chatStore.showToast("导出失败：\(error.localizedDescription)")
                    }
                }
            }
            rowDivider
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动备份到 iCloud")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Text("开启后每次进入应用自动将最新 ZIP 快照写入 iCloud Drive")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { settings.icloudAutoBackup },
                    set: { next in
                        if next && !DeepSeekZipExporter.isIcloudAvailable() {
                            chatStore.showToast("iCloud 暂不可用：请在系统设置登录 iCloud 并开启 iCloud 云盘")
                        }
                        settings.icloudAutoBackup = next
                        if next { chatStore.maybeAutoBackupToIcloud(settings: settings) }
                    }
                ))
                .labelsHidden()
                .tint(Color.nuwaBrand)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .padding(.top, 8)

        groupCard {
            actionCell(
                title: "删除所有对话",
                subtitle: "清空本机全部历史会话，保留 API Key 与设置",
                buttonTitle: "删除",
                destructive: true
            ) {
                showDeleteAllConfirm = true
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Subpage: 位置信息

    @ViewBuilder
    private var locationPage: some View {
        groupTitle("国家或地区")
        groupCard {
            VStack(spacing: 0) {
                HStack {
                    Text("国家 / 地区")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Spacer()
                    Picker("国家/地区", selection: Binding(
                        get: { settings.location?.region ?? "" },
                        set: { code in
                            if code.isEmpty {
                                settings.location = nil
                            } else if code == "CN" {
                                settings.location = UserLocation(region: "CN", province: "北京市", city: "北京市")
                            } else {
                                settings.location = UserLocation(region: code, province: nil, city: nil)
                            }
                        }
                    )) {
                        Text("不设置").tag("")
                        ForEach(LocationCatalog.regions, id: \.code) { r in
                            Text(settings.locale == .zhCN ? r.zh : r.en).tag(r.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)

                if settings.location?.region == "CN" {
                    rowDivider
                    HStack {
                        Text("省份 / 直辖市")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                        Spacer()
                        Picker("省份", selection: Binding(
                            get: { settings.location?.province ?? "北京市" },
                            set: { prov in
                                let firstCity = LocationCatalog.chinaProvinces.first(where: { $0.name == prov })?.cities.first
                                settings.location = UserLocation(region: "CN", province: prov, city: firstCity)
                            }
                        )) {
                            ForEach(LocationCatalog.chinaProvinces) { p in
                                Text(p.name).tag(p.name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)

                    if let prov = LocationCatalog.chinaProvinces.first(where: { $0.name == settings.location?.province }),
                       prov.cities.count > 1 {
                        rowDivider
                        HStack {
                            Text("城市")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                            Spacer()
                            Picker("城市", selection: Binding(
                                get: { settings.location?.city ?? prov.cities[0] },
                                set: { city in
                                    settings.location = UserLocation(region: "CN", province: prov.name, city: city)
                                }
                            )) {
                                ForEach(prov.cities, id: \.self) { c in
                                    Text(c).tag(c)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                    }
                }
            }
        }
        Text("位置信息仅在联网搜索与本地上下文提醒时随本轮请求发送，用于提供更准确的本地天气与资讯。")
            .font(.system(size: 12))
            .foregroundStyle(Color.nuwaLabelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
    }

    // MARK: - Subpage: 更新日志

    @ViewBuilder
    private var changelogPage: some View {
        if changelogLoading {
            HStack {
                Spacer()
                ProgressView("正在加载更新日志...")
                    .padding(.vertical, 40)
                Spacer()
            }
        } else if changelogFailed {
            VStack(spacing: 12) {
                Text("加载更新日志失败，请稍后重试")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                Button("重试") {
                    Task { await loadChangelog() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .nuwaPillSurface()
                .buttonStyle(NuwaTactileButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: 10) {
                ForEach(changelogItems) { item in
                    groupCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("v\(item.version)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.nuwaLabelPrimary)
                                Spacer()
                                Text(String(item.createdAt.prefix(10)))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                            }
                            Text(item.changelog.isEmpty ? "包含体验优化与问题修复。" : item.changelog)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.nuwaLabelSecondary)
                                .lineSpacing(3)
                        }
                        .padding(14)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.nuwaLabelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
            .frame(height: 0.75)
            .padding(.leading, 50)
    }

    private func navRow(
        icon: String,
        label: String,
        value: String?,
        valueAccent: Bool = false,
        valueDanger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(width: 22)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 14, weight: valueAccent ? .medium : .regular))
                        .foregroundStyle(valueDanger ? .red : (valueAccent ? Color.nuwaBrandText : Color.nuwaLabelTertiary))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.nuwaLabelTertiary.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.99))
    }

    private func pickerRow<Control: View>(icon: String, label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color.nuwaLabelSecondary)
                .frame(width: 22)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Color.nuwaLabelPrimary)
            Spacer()
            control()
                .tint(Color.nuwaLabelSecondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }

    private func actionCell(
        title: String,
        subtitle: String,
        buttonTitle: String,
        primary: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.nuwaLabelTertiary)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primary ? .white : (destructive ? .red : Color.nuwaLabelPrimary))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        if primary {
                            Capsule().fill(Color.nuwaBrand)
                        }
                    }
                    .modifier(OptionalGlassCapsule(enabled: !primary, tint: destructive ? .red : nil))
                    .contentShape(Capsule())
            }
            .buttonStyle(NuwaTactileButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func labeledInput(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.nuwaLabelSecondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(sheetBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func launchMigration(clearSession: Bool, forceReExport: Bool) {
        settings.hasUsedOneClickMigration = true
        migrationOptions = MigrationLaunchOptions(clearSession: clearSession, forceReExport: forceReExport)
    }

    private func verifyAndSaveApiKey() async {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        verifyingKey = true
        keyVerifyError = nil
        defer { verifyingKey = false }
        do {
            try await AIClient.verifyApiKey(
                apiKey: trimmed,
                apiProtocol: settings.apiProtocol,
                baseUrl: settings.apiBaseUrl
            )
            settings.apiKey = trimmed
            settings.authMode = .apiKey
            await settings.refreshBalance(force: true)
            chatStore.showToast("API Key 验证通过并已保存")
        } catch {
            keyVerifyError = "校验失败：\(error.localizedDescription)"
        }
    }

    private func runShareLinkImport(_ raw: String) async {
        importingShareLink = true
        defer { importingShareLink = false }
        do {
            let session = try await chatStore.importFromShareLink(raw)
            chatStore.showToast("已导入「\(session.title)」")
            dismiss()
        } catch {
            chatStore.showToast(error.localizedDescription)
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

    private func loadChangelog() async {
        guard changelogItems.isEmpty else { return }
        changelogLoading = true
        changelogFailed = false
        defer { changelogLoading = false }
        guard let url = URL(string: "https://dl.rankchord.com/api/releases") else {
            changelogFailed = true
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["releases"] as? [[String: Any]] {
                var seen = Set<String>()
                var entries: [ReleaseHistoryEntry] = []
                for item in list {
                    guard let ver = item["version"] as? String, !ver.isEmpty, !seen.contains(ver) else { continue }
                    seen.insert(ver)
                    entries.append(
                        ReleaseHistoryEntry(
                            id: (item["id"] as? String) ?? ver,
                            version: ver.replacingOccurrences(of: "^v", with: "", options: .regularExpression),
                            changelog: (item["changelog"] as? String) ?? "",
                            createdAt: (item["createdAt"] as? String) ?? ""
                        )
                    )
                }
                changelogItems = entries
            }
        } catch {
            changelogFailed = true
        }
    }
}

private struct OptionalGlassCapsule: ViewModifier {
    let enabled: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        if enabled {
            content.nuwaPillSurface(selected: false, destructive: tint == .red)
        } else {
            content
        }
    }
}
