import SwiftUI
import UniformTypeIdentifiers

private enum SettingsSubpage {
    case root
    case account
    case data
    case changelog
}

private struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ReleaseHistoryEntry: Identifiable, Decodable {
    let id: String
    let version: String
    let changelog: String
    let createdAt: String
}

/// Exact 1:1 recreation of chat-demo/src/components/settings/SettingsDialog.tsx
/// with native iOS 26 Liquid Glass header buttons & controls.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var chatStore: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var page: SettingsSubpage = .root
    @State private var showApiKey = false
    @State private var showDeepSeekAuth = false
    @State private var showMigrationWeb = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: BackupDocument?
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
        switch page {
        case .root: "设置"
        case .account: "账号管理"
        case .data: "数据管理"
        case .changelog: "更新日志"
        }
    }

    var body: some View {
        ZStack {
            sheetBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Sheet header matching SettingsDialog.tsx (Back + Title + Close Liquid Glass circles)
                HStack {
                    if page == .root {
                        Color.clear.frame(width: 36, height: 36)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                page = .root
                            }
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
                        case .root:
                            rootPage
                        case .account:
                            accountPage
                        case .data:
                            dataPage
                        case .changelog:
                            changelogPage
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
            }
        }
        .task {
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
        .sheet(isPresented: $showMigrationWeb) {
            DeepSeekMigrationSheet { filePath, _ in
                showMigrationWeb = false
                if let filePath {
                    chatStore.importFromFilePath(filePath)
                }
            }
            .ignoresSafeArea()
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
            allowedContentTypes: [.zip, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let count = try chatStore.importFromFileData(data)
                    chatStore.showToast(count == 1 ? "已导入 1 个对话" : "已导入 \(count) 个对话")
                } catch {
                    chatStore.showToast("导入失败：\(error.localizedDescription)")
                }
            case .failure(let error):
                chatStore.showToast("选择文件失败：\(error.localizedDescription)")
            }
        }
        .alert("删除后，所有对话都将被清空且无法找回", isPresented: $showDeleteAllConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                chatStore.deleteAllSessions()
                chatStore.showToast("删除成功")
            }
        } message: {
            Text("本地保存的会话记录将被全部清空，不会影响您的 API Key 和设置。")
        }
        .alert("退出登录", isPresented: $showSignOutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                settings.signOutAll()
                dismiss()
            }
        } message: {
            Text("将清除本地保存的 DeepSeek 账号与 API Key 凭据，历史对话会保留在设备上。")
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
        groupTitle("账户")
        groupCard {
            navRow(
                icon: "person",
                label: "账号管理",
                value: settings.profileDisplayName
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { page = .account }
            }
            rowDivider
            navRow(
                icon: "creditcard",
                label: "API 余额",
                value: settings.deepSeekBalanceText ?? "前往充值",
                valueAccent: settings.deepSeekBalanceText != nil
            ) {
                openURL(topUpURL)
            }
            rowDivider
            navRow(
                icon: "externaldrive",
                label: "数据管理",
                value: "\(chatStore.sessions.count) 条对话"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { page = .data }
            }
        }

        groupTitle("应用")
        groupCard {
            pickerRow(icon: "globe", label: "语言") {
                Picker("语言", selection: $settings.locale) {
                    ForEach(AppLocale.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            rowDivider
            pickerRow(icon: "sun.max", label: "外观") {
                Picker("外观", selection: $settings.themePreference) {
                    ForEach(ThemePreference.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            rowDivider
            pickerRow(icon: "textformat.size", label: "字体大小") {
                Picker("字体大小", selection: $settings.chatFontSize) {
                    ForEach(SettingsStore.fontSizeOptions, id: \.self) { size in
                        Text(size == 16 ? "16px（默认）" : "\(Int(size))px").tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }

        groupTitle("语音")
        groupCard {
            pickerRow(icon: "speaker.wave.2", label: "朗读音色") {
                Picker("朗读音色", selection: $settings.ttsVoice) {
                    ForEach(TtsVoiceOption.allCases) { v in
                        Text(v.displayName).tag(v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            rowDivider
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(width: 22)
                Text("语音引擎")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Spacer()
                Text("设备原生")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.nuwaLabelTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
        }
        Text("语音输入与回答朗读由 iOS 系统原生语音服务处理")
            .font(.system(size: 12))
            .foregroundStyle(Color.nuwaLabelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 6)

        groupTitle("关于")
        groupCard {
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(width: 22)
                Text("当前版本")
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
                label: isCheckingUpdate ? "检查中..." : "检查更新",
                value: nil
            ) {
                if !isCheckingUpdate {
                    Task { await checkUpdates() }
                }
            }
            rowDivider
            navRow(
                icon: "doc.text",
                label: "更新日志",
                value: nil
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { page = .changelog }
                Task { await loadChangelog() }
            }
            rowDivider
            navRow(
                icon: "book",
                label: "API 文档与帮助",
                value: nil
            ) {
                openURL(docsURL)
            }
        }

        // Standalone Sign Out card (matching signOutCard in SettingsDialog.tsx)
        groupCard {
            Button {
                showSignOutConfirm = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                        .frame(width: 22)
                    Text("退出登录")
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

    // MARK: - Subpage 1: 账号管理

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
                                    Task { await settings.refreshBalance() }
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.nuwaBrandText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .nuwaGlass(in: Capsule(), tint: .nuwaBrand, interactive: true)
                            }
                            Button("退出") {
                                settings.signOutDeepSeekAccount()
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .nuwaGlass(in: Capsule(), interactive: true)
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
                            Button {
                                settings.applyPreset(preset)
                            } label: {
                                Text(preset.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(settings.apiBaseUrl == preset.baseUrl ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .nuwaGlass(
                                        in: Capsule(),
                                        tint: settings.apiBaseUrl == preset.baseUrl ? .nuwaBrand : nil,
                                        interactive: true
                                    )
                            }
                            .buttonStyle(.plain)
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

                labeledInput("API 地址 (Base URL)", placeholder: "https://api.deepseek.com", text: $settings.apiBaseUrl, secure: false)
                labeledInput("模型名称", placeholder: "deepseek-chat", text: $settings.apiModel, secure: false)

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                    HStack {
                        Group {
                            if showApiKey {
                                TextField("sk-...", text: $settings.apiKey)
                            } else {
                                SecureField("sk-...", text: $settings.apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14))
                        .onChange(of: settings.apiKey) { _, newValue in
                            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                settings.authMode = .apiKey
                            }
                        }

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
            }
            .padding(16)
        }
    }

    // MARK: - Subpage 2: 数据管理

    @ViewBuilder
    private var dataPage: some View {
        groupCard {
            actionCell(
                title: "一键迁移 DeepSeek 历史",
                subtitle: "登录官方网页端自动触发导出并合并到本机",
                buttonTitle: "一键导入",
                primary: true
            ) {
                showMigrationWeb = true
            }
            rowDivider
            actionCell(
                title: "导入历史对话",
                subtitle: "支持 DeepSeek 导出的 ZIP 文件或 Nuwa JSON 备份，增量合并",
                buttonTitle: "导入"
            ) {
                isImporting = true
            }
            rowDivider
            actionCell(
                title: "导出所有历史对话",
                subtitle: "包含全部本地会话记录，可备份到 iCloud Drive 或本机（不含 API Key）",
                buttonTitle: "备份到 iCloud"
            ) {
                if let data = try? chatStore.exportBackupData() {
                    exportDocument = BackupDocument(data: data)
                    isExporting = true
                }
            }
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

    // MARK: - Subpage 3: 更新日志

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
                .nuwaGlass(in: Capsule(), interactive: true)
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

    // MARK: - Reusable Setting Components

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.nuwaLabelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
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
                        .foregroundStyle(valueAccent ? Color.nuwaBrandText : Color.nuwaLabelTertiary)
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
        .buttonStyle(.plain)
    }

    private func pickerRow<Control: View>(
        icon: String,
        label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
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
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func labeledInput(_ label: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
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
            content.nuwaGlass(in: Capsule(), tint: tint, interactive: true)
        } else {
            content
        }
    }
}
