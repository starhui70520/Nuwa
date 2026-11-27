import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct SettingsDropdownOption: Identifiable {
    let id: String
    let label: String
    let isSelected: Bool
    let onSelect: () -> Void
}

private struct ActiveSettingsDropdown {
    let id = UUID()
    let anchorFrame: CGRect
    let options: [SettingsDropdownOption]
}

private final class CoordinateAnchorBox {
    weak var view: UIView?
}

private struct CoordinateAnchorProbe: UIViewRepresentable {
    let box: CoordinateAnchorBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        box.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        box.view = uiView
    }
}

private struct SettingsSelectTrigger<Label: View>: View {
    let rootAnchorBox: CoordinateAnchorBox
    let onOpen: (CGRect) -> Void
    @ViewBuilder let label: () -> Label

    @State private var anchorBox = CoordinateAnchorBox()

    var body: some View {
        Button {
            let rect: CGRect
            if let src = anchorBox.view, let root = rootAnchorBox.view {
                rect = src.convert(src.bounds, to: root)
            } else {
                rect = CGRect(x: 16, y: 120, width: 220, height: 48)
            }
            onOpen(rect)
        } label: {
            label()
                .background(CoordinateAnchorProbe(box: anchorBox))
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.99))
    }
}

private enum SettingsSubpage {
    case root
    case account
    case data
    case location
    case changelog
    case feedback
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
    @State private var apiProtocolDraft: ApiProtocol = .anthropic
    @State private var apiBaseUrlDraft = ""
    @State private var apiModelDraft = ""
    @State private var apiKeyDraft = ""
    @State private var verifyingKey = false
    @State private var keyVerifyError: String?

    @State private var showDeepSeekAuth = false
    @State private var migrationOptions: MigrationLaunchOptions?
    @State private var showMigrationChooser = false
    @State private var showShareLinkAlert = false
    @State private var shareLinkDraft = ""
    @State private var importingShareLink = false
    @State private var shareImportStage = ""

    @State private var showExportSheet = false
    @State private var exportBusyMode: ExportDestination?
    @State private var isImporting = false
    @State private var showDeleteAllConfirm = false
    @State private var showSignOutConfirm = false

    @State private var isCheckingUpdate = false
    @State private var updateResult: AppUpdateResult?
    @State private var updateAlertPresented = false
    @State private var updateErrorText: String?

    @State private var changelogItems: [ReleaseHistoryEntry] = []
    @State private var changelogLoading = false
    @State private var changelogFailed = false
    @State private var activeDropdown: ActiveSettingsDropdown?
    @State private var rootAnchorBox = CoordinateAnchorBox()

    private let docsURL = URL(string: "https://api-docs.deepseek.com/zh-cn/")!
    private let topUpURL = URL(string: "https://platform.deepseek.com/top_up")!
    private let privacyPolicyURL = URL(string: "https://rankchord.com/nuwa/privacy")!

    private var fontScale: CGFloat {
        CGFloat(settings.chatFontSize / 16.0)
    }

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

            GeometryReader { rootGeo in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        // Header matching SettingsDialog.tsx
                        HStack {
                            if page == .root {
                                Color.clear.frame(width: 36, height: 36)
                            } else {
                                Button {
                                    activeDropdown = nil
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
                                .font(NuwaFont.navTitle(fontScale))
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
                    .frame(width: rootGeo.size.width, height: rootGeo.size.height)
                    .accessibilityHidden(showMigrationChooser || activeDropdown != nil)

                    if let dropdown = activeDropdown {
                        settingsDropdownOverlay(dropdown, containerSize: rootGeo.size)
                            .zIndex(40)
                    }

                    if showMigrationChooser {
                        migrationChooser
                            .frame(width: rootGeo.size.width, height: rootGeo.size.height)
                            .zIndex(50)
                    }
                }
                .frame(width: rootGeo.size.width, height: rootGeo.size.height, alignment: .topLeading)
                .background(CoordinateAnchorProbe(box: rootAnchorBox))
            }
        }
        .environment(\.nuwaFontScale, fontScale)
        .nuwaOnChange(of: page) { _ in
            activeDropdown = nil
        }
        .task {
            syncAccountDrafts()
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
                    dismiss()
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showExportSheet) {
            ExportActionSheetView(
                title: L10n.t("exportHistory", locale: settings.locale),
                subtitle: settings.locale == .enUS
                    ? "DeepSeek / Nuwa standard ZIP backup (\(chatStore.sessions.count) chats)"
                    : "标准 DeepSeek / Nuwa ZIP 归档（共 \(chatStore.sessions.count) 条对话）",
                locale: settings.locale,
                busyMode: exportBusyMode,
                onSelect: { destination in
                    guard exportBusyMode == nil else { return }
                    exportBusyMode = destination
                    Task {
                        do {
                            let fileURL = try await chatStore.exportAllSessionsZipURL()
                            exportBusyMode = nil
                            showExportSheet = false
                            try? await Task.sleep(nanoseconds: 280_000_000)
                            ExportPresenter.present(fileURL: fileURL, destination: destination) { completed in
                                if completed {
                                    chatStore.showToast(
                                        settings.locale == .enUS ? "Exported chat history ZIP" : "已导出历史对话 ZIP"
                                    )
                                }
                            }
                        } catch {
                            exportBusyMode = nil
                            showExportSheet = false
                            chatStore.showToast("导出失败：\(error.localizedDescription)")
                        }
                    }
                },
                onCancel: {
                    if exportBusyMode == nil {
                        showExportSheet = false
                    }
                }
            )
            .environment(\.nuwaFontScale, fontScale)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.zip, .json, NuwaShareTypes.sessionUTType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    do {
                        let outcome = try await chatStore.importFromFileWithOutcome(url)
                        chatStore.showToast(ChatStore.importSummaryToast(for: outcome, singleShare: false))
                    } catch {
                        chatStore.showToast("导入失败：\(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                chatStore.showToast("选择文件失败：\(error.localizedDescription)")
            }
        }
        .alert("通过 DeepSeek 链接导入", isPresented: $showShareLinkAlert) {
            TextField("粘贴 DeepSeek 分享链接或官方数据导出 ZIP 链接", text: $shareLinkDraft)
            Button("取消", role: .cancel) { shareLinkDraft = "" }
            Button("导入") {
                let raw = shareLinkDraft
                shareLinkDraft = ""
                Task { await runShareLinkImport(raw) }
            }
        } message: {
            Text("支持直接粘贴 DeepSeek 分享链接（含完整分享文案）或官方数据导出 ZIP 下载链接。")
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
        .nuwaPresentationDragIndicatorVisible()
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
                syncAccountDrafts()
                withAnimation(.easeInOut(duration: 0.2)) { page = .account }
            }
            rowDivider
            navRow(
                icon: "creditcard",
                label: L10n.t("apiBalance", locale: loc),
                value: settings.isUsingRankAIFree
                    ? L10n.t("apiBalanceFree", locale: loc)
                    : (settings.deepSeekBalanceText ?? L10n.t("topUp", locale: loc)),
                valueAccent: settings.isUsingRankAIFree || settings.deepSeekBalanceText != nil,
                valueDanger: !settings.isUsingRankAIFree && settings.isBalanceLow
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
            selectRow(
                icon: "globe",
                label: L10n.t("language", locale: loc),
                value: settings.locale.displayName,
                options: AppLocale.allCases.map { item in
                    SettingsDropdownOption(
                        id: item.rawValue,
                        label: item.displayName,
                        isSelected: settings.locale == item
                    ) {
                        settings.locale = item
                    }
                }
            )
            rowDivider
            selectRow(
                icon: "sun.max",
                label: L10n.t("appearance", locale: loc),
                value: settings.themePreference.displayName,
                options: ThemePreference.allCases.map { item in
                    SettingsDropdownOption(
                        id: item.rawValue,
                        label: item.displayName,
                        isSelected: settings.themePreference == item
                    ) {
                        settings.themePreference = item
                    }
                }
            )
            rowDivider
            selectRow(
                icon: "textformat.size",
                label: L10n.t("fontSize", locale: loc),
                value: fontSizeLabel(settings.chatFontSize, locale: loc),
                options: SettingsStore.fontSizeOptions.map { size in
                    SettingsDropdownOption(
                        id: String(Int(size)),
                        label: fontSizeLabel(size, locale: loc),
                        isSelected: settings.chatFontSize == size
                    ) {
                        settings.chatFontSize = size
                    }
                }
            )
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
            selectRow(
                icon: "speaker.wave.2",
                label: L10n.t("ttsVoice", locale: loc),
                value: settings.ttsVoice.displayName,
                options: TtsVoiceOption.allCases.map { v in
                    SettingsDropdownOption(
                        id: v.rawValue,
                        label: v.displayName,
                        isSelected: settings.ttsVoice == v
                    ) {
                        settings.ttsVoice = v
                    }
                }
            )
            rowDivider
            selectRow(
                icon: "waveform",
                label: L10n.t("speechEngine", locale: loc),
                value: settings.speechEngine.displayName,
                options: SpeechEngineOption.allCases.map { eng in
                    SettingsDropdownOption(
                        id: eng.rawValue,
                        label: eng.displayName,
                        isSelected: settings.speechEngine == eng
                    ) {
                        settings.speechEngine = eng
                    }
                }
            )
        }
        Text("自动模式在配置 API Key 时优先云端朗读，否则无缝使用 iOS 原生语音服务")
            .font(NuwaFont.badge(fontScale))
            .foregroundStyle(Color.nuwaLabelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 6)

        groupTitle(L10n.t("groupAbout", locale: loc))
        groupCard {
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(NuwaFont.sized(16, scale: fontScale))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(width: 22)
                Text(L10n.t("version", locale: loc))
                    .font(NuwaFont.rowTitle(fontScale))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Spacer()
                Text("v\(AppUpdateService.currentVersion) (\(AppUpdateService.buildNumber))")
                    .font(NuwaFont.control(fontScale))
                    .foregroundStyle(Color.nuwaLabelTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: max(52, 36 + 16 * fontScale))
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
            rowDivider
            navRow(
                icon: "hand.raised",
                label: L10n.t("privacyPolicy", locale: loc),
                value: nil
            ) {
                openURL(privacyPolicyURL)
            }
        }

        groupCard {
            Button {
                showSignOutConfirm = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(NuwaFont.sized(16, scale: fontScale))
                        .foregroundStyle(.red)
                        .frame(width: 22)
                    Text(L10n.t("signOut", locale: loc))
                        .font(NuwaFont.rowTitleMedium(fontScale))
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: max(52, 36 + 16 * fontScale))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)

        VStack(spacing: 4) {
            Button {
                if let url = URL(string: "https://beian.miit.gov.cn/") {
                    openURL(url)
                }
            } label: {
                Text("粤ICP备2026010599号-2A")
                    .font(NuwaFont.badge(fontScale))
                    .foregroundStyle(Color.nuwaLabelTertiary)
            }
            .buttonStyle(.plain)

            Text(loc == .enUS
                 ? "AI-generated content. Please verify carefully and use lawfully."
                 : "内容由 AI 生成，请仔细甄别，并合法使用")
                .font(NuwaFont.badge(fontScale))
                .foregroundStyle(Color.nuwaLabelTertiary.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Subpage: 账号管理

    @ViewBuilder
    private var accountPage: some View {
        let loc = settings.locale
        groupCard {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DeepSeek API 账号")
                                .font(NuwaFont.controlMedium(fontScale))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                            if !settings.dshToken.isEmpty {
                                Text(settings.isUsingDeepSeekAccount
                                     ? "当前生效：\(settings.dshAccountLabel.isEmpty ? "DeepSeek API 账号" : settings.dshAccountLabel)"
                                     : (settings.isUsingRankAIFree
                                        ? "已登录（当前使用 RankAI 免费额度）"
                                        : "已登录（当前使用自定义 API Key）"))
                                    .font(NuwaFont.badge(fontScale))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                            } else {
                                Text("通过 DeepSeek 开放平台授权登录，免手动复制 API Key")
                                    .font(NuwaFont.badge(fontScale))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                            }
                        }
                        Spacer()
                        if settings.dshToken.isEmpty {
                            Button("账号登录") {
                                showDeepSeekAuth = true
                            }
                            .font(NuwaFont.sized(13, weight: .semibold, scale: fontScale))
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
                                    .font(NuwaFont.captionMedium(fontScale))
                                    .foregroundStyle(Color.nuwaBrandText)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .nuwaPillSurface(selected: true)
                                    .buttonStyle(NuwaTactileButtonStyle())
                                }
                                Button("退出") {
                                    settings.signOutDeepSeekAccount()
                                }
                                .font(NuwaFont.captionMedium(fontScale))
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

                rowDivider

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(L10n.t("rankaiFreeLabel", locale: loc))
                                .font(NuwaFont.controlMedium(fontScale))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                            Text(L10n.t("rankaiFreeLimitedBadge", locale: loc))
                                .font(NuwaFont.sized(11, weight: .semibold, scale: fontScale))
                                .foregroundStyle(colorScheme == .dark
                                    ? Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
                                    : Color(red: 217 / 255, green: 119 / 255, blue: 6 / 255))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
                                        .opacity(colorScheme == .dark ? 0.22 : 0.14),
                                    in: Capsule()
                                )
                        }
                        Text(L10n.t(settings.isUsingRankAIFree ? "rankaiFreeActiveDesc" : "rankaiFreeDesc", locale: loc))
                            .font(NuwaFont.badge(fontScale))
                            .foregroundStyle(Color.nuwaLabelTertiary)
                    }
                    Spacer()
                    if settings.isUsingRankAIFree {
                        Button(L10n.t("rankaiFreeDisableButton", locale: loc)) {
                            settings.disableRankAIFree()
                            chatStore.showToast(L10n.t("rankaiFreeDisabledToast", locale: loc))
                        }
                        .font(NuwaFont.captionMedium(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .nuwaPillSurface()
                        .buttonStyle(NuwaTactileButtonStyle())
                    } else {
                        Button(L10n.t("rankaiFreeEnableButton", locale: loc)) {
                            settings.enableRankAIFree()
                            chatStore.showToast(L10n.t("rankaiFreeEnabledToast", locale: loc))
                        }
                        .font(NuwaFont.sized(13, weight: .semibold, scale: fontScale))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.nuwaBrand, in: Capsule())
                        .buttonStyle(NuwaTactileButtonStyle())
                    }
                }
                .padding(16)
            }
        }
        .padding(.top, 8)

        HStack {
            Text("自定义 API 配置")
                .font(NuwaFont.sectionHeader(fontScale))
                .foregroundStyle(Color.nuwaLabelTertiary)
            Spacer()
            SettingsSelectTrigger(rootAnchorBox: rootAnchorBox) { frame in
                openDropdown(
                    anchorFrame: frame,
                    options: ProviderPreset.presets.map { preset in
                        SettingsDropdownOption(
                            id: preset.id,
                            label: preset.name,
                            isSelected: apiBaseUrlDraft == preset.baseUrl && apiProtocolDraft == preset.apiProtocol
                        ) {
                            apiProtocolDraft = preset.apiProtocol
                            apiBaseUrlDraft = preset.baseUrl
                            apiModelDraft = preset.defaultModel
                            keyVerifyError = nil
                        }
                    }
                )
            } label: {
                HStack(spacing: 4) {
                    Text("填充模板")
                        .font(NuwaFont.captionMedium(fontScale))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.nuwaBrandText)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)

        groupCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSelectTrigger(rootAnchorBox: rootAnchorBox) { frame in
                    openDropdown(
                        anchorFrame: frame,
                        options: ApiProtocol.allCases.map { proto in
                            SettingsDropdownOption(
                                id: proto.rawValue,
                                label: proto.displayName,
                                isSelected: apiProtocolDraft == proto
                            ) {
                                apiProtocolDraft = proto
                                let base = apiBaseUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                let model = apiModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                if proto == .anthropic &&
                                    (base.isEmpty || base.contains("api.deepseek.com")) &&
                                    (model.isEmpty || model == "deepseek-chat") {
                                    apiModelDraft = "deepseek-flash"
                                }
                            }
                        }
                    )
                } label: {
                    HStack {
                        Text("接口协议")
                            .font(NuwaFont.sublabel(fontScale))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                        Spacer()
                        HStack(spacing: 5) {
                            Text(apiProtocolDraft.displayName)
                                .font(NuwaFont.control(fontScale))
                                .foregroundStyle(Color.nuwaLabelSecondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.nuwaLabelTertiary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }

                labeledInput("API 地址 (Base URL)", placeholder: "https://api.deepseek.com", text: $apiBaseUrlDraft)
                labeledInput("模型名称", placeholder: "deepseek-flash / deepseek-v4-pro / gpt-4o", text: $apiModelDraft)

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(NuwaFont.captionMedium(fontScale))
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
                        .font(NuwaFont.sublabel(fontScale))

                        Button {
                            showApiKey.toggle()
                        } label: {
                            Image(systemName: showApiKey ? "eye.slash" : "eye")
                                .foregroundStyle(Color.nuwaLabelTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: max(42, 28 + 14 * fontScale))
                    .background(sheetBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let keyVerifyError {
                    Text(keyVerifyError)
                        .font(NuwaFont.caption(fontScale))
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
                            .font(NuwaFont.sized(14, weight: .semibold, scale: fontScale))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(42, 28 + 14 * fontScale))
                    .background(
                        (verifyingKey || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            ? Color.nuwaBrand.opacity(0.4)
                            : Color.nuwaBrand,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(verifyingKey || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && settings.authMode != .apiKey {
                    Button {
                        settings.authMode = .apiKey
                        Task { await settings.refreshBalance(force: true) }
                        chatStore.showToast("已切换为自定义 API Key")
                    } label: {
                        Text("切换为已保存的 API Key")
                            .font(NuwaFont.captionMedium(fontScale))
                            .foregroundStyle(Color.nuwaBrandText)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: max(38, 26 + 12 * fontScale))
                            .nuwaPillSurface(selected: true)
                    }
                    .buttonStyle(NuwaTactileButtonStyle())
                }
            }
            .padding(16)
        }
        Text("仅在点击「验证并保存 API Key」并通过校验后才会切换为自定义 API，查看或编辑草稿不会影响当前登录状态。")
            .font(NuwaFont.badge(fontScale))
            .foregroundStyle(Color.nuwaLabelTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
    }

    // MARK: - Subpage: 数据管理

    private var importProgressSubtitle: String {
        guard chatStore.importingHistory else {
            return "支持 DeepSeek 官方导出 ZIP 或 Nuwa JSON，按 ID 增量合并"
        }
        if let progress = chatStore.importProgress {
            if progress.phase == .merging {
                return "正在写入本地数据库（共 \(progress.sessions) 个会话）…"
            }
            if progress.sessions > 0 {
                let imgPart = progress.images > 0 ? "，\(progress.images) 个附件" : ""
                return "正在导入：已读取 \(progress.sessions) 个会话\(imgPart)…"
            }
        }
        return "正在解析归档文件，请稍候…"
    }

    @ViewBuilder
    private var dataPage: some View {
        let loc = settings.locale
        let historyBusy = chatStore.importingHistory
        groupCard {
            actionCell(
                title: L10n.t("oneClickMigrate", locale: loc),
                subtitle: "登录官方网页端自动触发导出并合并到本机",
                buttonTitle: "一键导入",
                primary: true,
                disabled: historyBusy
            ) {
                if settings.hasUsedOneClickMigration || !chatStore.sessions.isEmpty {
                    showMigrationChooser = true
                } else {
                    launchMigration(clearSession: false, forceReExport: false)
                }
            }
            rowDivider
            actionCell(
                title: L10n.t("shareLinkImport", locale: loc),
                subtitle: importingShareLink && !shareImportStage.isEmpty
                    ? shareImportStage
                    : "粘贴 DeepSeek 分享链接或官方数据导出 ZIP 下载链接，直接导入对话",
                buttonTitle: importingShareLink ? "导入中…" : "链接导入",
                disabled: historyBusy || importingShareLink
            ) {
                if !importingShareLink {
                    showShareLinkAlert = true
                }
            }
            rowDivider
            actionCell(
                title: L10n.t("importHistory", locale: loc),
                subtitle: importProgressSubtitle,
                buttonTitle: historyBusy ? "导入中…" : "导入",
                disabled: historyBusy
            ) {
                isImporting = true
            }
            rowDivider
            actionCell(
                title: L10n.t("exportHistory", locale: loc),
                subtitle: "导出标准 DeepSeek 格式 ZIP，可发送到其他软件或保存到「文件」与 iCloud Drive",
                buttonTitle: loc == .enUS ? "Export" : "导出",
                disabled: historyBusy
            ) {
                showExportSheet = true
            }
            rowDivider
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("icloudAutoBackup", locale: loc))
                        .font(NuwaFont.rowTitleMedium(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Text("开启后每次进入应用自动将最新 ZIP 快照写入 iCloud Drive")
                        .font(NuwaFont.caption(fontScale))
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
                title: L10n.t("deleteAll", locale: loc),
                subtitle: "清空本机全部历史会话，保留 API Key 与设置",
                buttonTitle: L10n.t("delete", locale: loc),
                destructive: true,
                disabled: historyBusy
            ) {
                showDeleteAllConfirm = true
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Subpage: 位置信息

    @ViewBuilder
    private var locationPage: some View {
        let currentRegionCode = settings.location?.region ?? ""
        let currentRegionLabel: String = {
            if currentRegionCode.isEmpty { return "不设置" }
            if let r = LocationCatalog.regions.first(where: { $0.code == currentRegionCode }) {
                return settings.locale == .zhCN ? r.zh : r.en
            }
            return currentRegionCode
        }()

        groupTitle("国家或地区")
        groupCard {
            VStack(spacing: 0) {
                plainSelectRow(
                    label: "国家 / 地区",
                    value: currentRegionLabel,
                    options: [
                        SettingsDropdownOption(
                            id: "",
                            label: "不设置",
                            isSelected: currentRegionCode.isEmpty
                        ) {
                            settings.location = nil
                        }
                    ] + LocationCatalog.regions.map { r in
                        SettingsDropdownOption(
                            id: r.code,
                            label: settings.locale == .zhCN ? r.zh : r.en,
                            isSelected: currentRegionCode == r.code
                        ) {
                            if r.code == "CN" {
                                settings.location = UserLocation(region: "CN", province: "北京市", city: "北京市")
                            } else {
                                settings.location = UserLocation(region: r.code, province: nil, city: nil)
                            }
                        }
                    }
                )

                if settings.location?.region == "CN" {
                    let currentProv = settings.location?.province ?? "北京市"
                    rowDivider
                    plainSelectRow(
                        label: "省份 / 直辖市",
                        value: currentProv,
                        options: LocationCatalog.chinaProvinces.map { p in
                            SettingsDropdownOption(
                                id: p.name,
                                label: p.name,
                                isSelected: currentProv == p.name
                            ) {
                                let firstCity = p.cities.first
                                settings.location = UserLocation(region: "CN", province: p.name, city: firstCity)
                            }
                        }
                    )

                    if let prov = LocationCatalog.chinaProvinces.first(where: { $0.name == currentProv }),
                       prov.cities.count > 1 {
                        let currentCity = settings.location?.city ?? prov.cities[0]
                        rowDivider
                        plainSelectRow(
                            label: "城市",
                            value: currentCity,
                            options: prov.cities.map { c in
                                SettingsDropdownOption(
                                    id: c,
                                    label: c,
                                    isSelected: currentCity == c
                                ) {
                                    settings.location = UserLocation(region: "CN", province: prov.name, city: c)
                                }
                            }
                        )
                    }
                }
            }
        }
        Text("位置信息仅在联网搜索与本地上下文提醒时随本轮请求发送，用于提供更准确的本地天气与资讯。")
            .font(NuwaFont.caption(fontScale))
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
                    .font(NuwaFont.sublabel(fontScale))
                    .padding(.vertical, 40)
                Spacer()
            }
        } else if changelogFailed {
            VStack(spacing: 12) {
                Text("加载更新日志失败，请稍后重试")
                    .font(NuwaFont.sublabel(fontScale))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                Button("重试") {
                    Task { await loadChangelog() }
                }
                .font(NuwaFont.pill(fontScale))
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
                                    .font(NuwaFont.sized(15, weight: .semibold, scale: fontScale))
                                    .foregroundStyle(Color.nuwaLabelPrimary)
                                Spacer()
                                Text(String(item.createdAt.prefix(10)))
                                    .font(NuwaFont.badge(fontScale))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                            }
                            Text(item.changelog.isEmpty ? "包含体验优化与问题修复。" : item.changelog)
                                .font(NuwaFont.caption(fontScale))
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
            .font(NuwaFont.sectionHeader(fontScale))
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
                    .font(NuwaFont.sized(16, scale: fontScale))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(width: 22)
                Text(label)
                    .font(NuwaFont.rowTitle(fontScale))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(valueAccent ? NuwaFont.controlMedium(fontScale) : NuwaFont.control(fontScale))
                        .foregroundStyle(valueDanger ? .red : (valueAccent ? Color.nuwaBrandText : Color.nuwaLabelTertiary))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.nuwaLabelTertiary.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: max(52, 36 + 16 * fontScale))
            .contentShape(Rectangle())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.99))
    }

    private func fontSizeLabel(_ size: Double, locale: AppLocale) -> String {
        size == 16
            ? (locale == .enUS ? "16px (Default)" : "16px（默认）")
            : "\(Int(size))px"
    }

    private func openDropdown(anchorFrame: CGRect, options: [SettingsDropdownOption]) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.easeOut(duration: 0.16)) {
            activeDropdown = ActiveSettingsDropdown(anchorFrame: anchorFrame, options: options)
        }
    }

    private func closeDropdown() {
        withAnimation(.easeOut(duration: 0.14)) {
            activeDropdown = nil
        }
    }

    private func selectRow(
        icon: String,
        label: String,
        value: String,
        options: [SettingsDropdownOption]
    ) -> some View {
        SettingsSelectTrigger(rootAnchorBox: rootAnchorBox) { frame in
            openDropdown(anchorFrame: frame, options: options)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(NuwaFont.sized(16, scale: fontScale))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(width: 22)
                Text(label)
                    .font(NuwaFont.rowTitle(fontScale))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Text(value)
                        .font(NuwaFont.control(fontScale))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: max(52, 36 + 16 * fontScale))
            .contentShape(Rectangle())
        }
    }

    private func plainSelectRow(
        label: String,
        value: String,
        options: [SettingsDropdownOption]
    ) -> some View {
        SettingsSelectTrigger(rootAnchorBox: rootAnchorBox) { frame in
            openDropdown(anchorFrame: frame, options: options)
        } label: {
            HStack(spacing: 12) {
                Text(label)
                    .font(NuwaFont.rowTitle(fontScale))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Text(value)
                        .font(NuwaFont.control(fontScale))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: max(50, 34 + 16 * fontScale))
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func settingsDropdownOverlay(
        _ dropdown: ActiveSettingsDropdown,
        containerSize: CGSize
    ) -> some View {
        let horizontalMargin: CGFloat = 16
        let verticalMargin: CGFloat = 16
        let menuWidth = min(max(200, 224 * min(1.25, max(1.0, fontScale))), max(160, containerSize.width - horizontalMargin * 2))
        let rowHeight = max(44, 28 + 16 * fontScale)
        let contentHeight = CGFloat(dropdown.options.count) * rowHeight + 12
        let maxHeight = min(300, max(160, containerSize.height - 96))
        let menuHeight = min(contentHeight, maxHeight)

        let spaceBelow = containerSize.height - dropdown.anchorFrame.maxY - verticalMargin
        let spaceAbove = dropdown.anchorFrame.minY - verticalMargin
        let openBelow = spaceBelow >= min(menuHeight, 160) || spaceBelow >= spaceAbove
        let rawTop = openBelow
            ? dropdown.anchorFrame.maxY + 6
            : dropdown.anchorFrame.minY - 6 - menuHeight
        let menuTop = min(max(verticalMargin, rawTop), max(verticalMargin, containerSize.height - menuHeight - verticalMargin))
        let rawLeft = dropdown.anchorFrame.maxX - menuWidth
        let menuLeft = min(max(horizontalMargin, rawLeft), max(horizontalMargin, containerSize.width - menuWidth - horizontalMargin))

        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(Rectangle())
                .onTapGesture {
                    closeDropdown()
                }
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { _ in
                            closeDropdown()
                        }
                )

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: contentHeight > maxHeight) {
                    VStack(spacing: 0) {
                        ForEach(Array(dropdown.options.enumerated()), id: \.element.id) { idx, opt in
                            if idx > 0 {
                                Rectangle()
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                                    .frame(height: 0.5)
                                    .padding(.horizontal, 12)
                            }
                            Button {
                                opt.onSelect()
                                closeDropdown()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(opt.label)
                                        .font(opt.isSelected ? NuwaFont.controlMedium(fontScale) : NuwaFont.control(fontScale))
                                        .foregroundStyle(opt.isSelected ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    if opt.isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.nuwaBrandText)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.99))
                            .id(opt.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear {
                    if let selected = dropdown.options.first(where: { $0.isSelected }) {
                        proxy.scrollTo(selected.id, anchor: .center)
                    }
                }
            }
            .frame(width: menuWidth, height: menuHeight)
            .nuwaGlassCard(
                cornerRadius: 18,
                tint: colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.38)
            )
            .offset(x: menuLeft, y: menuTop)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: openBelow ? .topTrailing : .bottomTrailing)))
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
    }

    private func pickerRow<Control: View>(icon: String, label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(NuwaFont.sized(16, scale: fontScale))
                .foregroundStyle(Color.nuwaLabelSecondary)
                .frame(width: 22)
            Text(label)
                .font(NuwaFont.rowTitle(fontScale))
                .foregroundStyle(Color.nuwaLabelPrimary)
            Spacer()
            control()
                .font(NuwaFont.control(fontScale))
                .tint(Color.nuwaLabelSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: max(52, 36 + 16 * fontScale))
    }

    private func actionCell(
        title: String,
        subtitle: String,
        buttonTitle: String,
        primary: Bool = false,
        destructive: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(NuwaFont.rowTitleMedium(fontScale))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Text(subtitle)
                    .font(NuwaFont.caption(fontScale))
                    .foregroundStyle(Color.nuwaLabelTertiary)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Text(buttonTitle)
                    .font(NuwaFont.pill(fontScale))
                    .foregroundStyle(primary ? .white : (destructive ? .red : Color.nuwaLabelPrimary))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        if primary {
                            Capsule().fill(Color.nuwaBrand)
                        }
                    }
                    .modifier(OptionalGlassCapsule(enabled: !primary, tint: destructive ? .red : nil))
                    .opacity(disabled ? 0.5 : 1)
                    .contentShape(Capsule())
            }
            .buttonStyle(NuwaTactileButtonStyle())
            .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func labeledInput(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(NuwaFont.captionMedium(fontScale))
                .foregroundStyle(Color.nuwaLabelSecondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(NuwaFont.sublabel(fontScale))
                .padding(.horizontal, 12)
                .frame(minHeight: max(42, 28 + 14 * fontScale))
                .background(sheetBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var migrationChooser: some View {
        let english = settings.locale == .enUS
        let content = VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(english ? "Choose Migration Method" : "选择迁移方式")
                    .font(NuwaFont.navTitle(fontScale))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    showMigrationChooser = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NuwaTactileButtonStyle())
                .accessibilityLabel(L10n.t("cancel", locale: settings.locale))
            }

            Text(english
                ? "You already have local conversations. Continue with the current account or switch accounts."
                : "检测到本地已有会话记录，请选择继续当前账号导出或切换账号。")
                .font(NuwaFont.sublabel(fontScale))
                .foregroundStyle(Color.nuwaLabelSecondary)
                .padding(.bottom, 4)

            migrationChoice(english ? "Re-export & Update (Recommended)" : "重新导出并更新（推荐）", primary: true) {
                launchMigration(clearSession: false, forceReExport: true)
            }
            migrationChoice(english ? "Download Previous Export" : "直接下载上次导出（当前账号）") {
                launchMigration(clearSession: false, forceReExport: false)
            }
            migrationChoice(english ? "Switch Account" : "切换其他账号") {
                launchMigration(clearSession: true, forceReExport: false)
            }
        }
        .foregroundStyle(Color.nuwaLabelPrimary)
        .padding(20)

        return ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture { showMigrationChooser = false }
                .accessibilityHidden(true)

            Group {
                if #available(iOS 16.0, *) {
                    ViewThatFits(in: .vertical) {
                        content.fixedSize(horizontal: false, vertical: true)
                        ScrollView { content }
                    }
                } else {
                    ScrollView { content }
                        .frame(maxHeight: 420)
                }
            }
            .frame(maxWidth: 380)
            .background(cardBg, in: RoundedRectangle(cornerRadius: 24))
            .padding(20)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { showMigrationChooser = false }
        }
    }

    private func migrationChoice(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return Button(action: action) {
            Text(title)
                .font(NuwaFont.sized(15, weight: primary ? .semibold : .medium, scale: fontScale))
                .foregroundStyle(primary ? .white : Color.nuwaLabelPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: max(46, 30 + 16 * fontScale))
                .background(primary ? Color.nuwaBrand : Color.clear, in: shape)
                .overlay(shape.strokeBorder(primary ? .clear : Color.nuwaControlBorder))
                .contentShape(shape)
        }
        .buttonStyle(NuwaTactileButtonStyle())
    }

    private func launchMigration(clearSession: Bool, forceReExport: Bool) {
        showMigrationChooser = false
        settings.hasUsedOneClickMigration = true
        migrationOptions = MigrationLaunchOptions(clearSession: clearSession, forceReExport: forceReExport)
    }

    private func syncAccountDrafts() {
        apiProtocolDraft = settings.apiProtocol
        apiBaseUrlDraft = settings.apiBaseUrl
        apiModelDraft = settings.apiModel
        apiKeyDraft = settings.apiKey
        keyVerifyError = nil
    }

    private func verifyAndSaveApiKey() async {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trimmedBase = apiBaseUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBase = trimmedBase.isEmpty ? "https://api.deepseek.com" : trimmedBase
        let trimmedModel = apiModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        verifyingKey = true
        keyVerifyError = nil
        defer { verifyingKey = false }
        do {
            try await AIClient.verifyApiKey(
                apiKey: trimmed,
                apiProtocol: apiProtocolDraft,
                baseUrl: effectiveBase
            )
            settings.apiProtocol = apiProtocolDraft
            settings.apiBaseUrl = effectiveBase
            settings.apiModel = trimmedModel
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
        shareImportStage = "正在识别链接…"
        defer {
            importingShareLink = false
            shareImportStage = ""
        }
        do {
            let result = try await chatStore.importFromLink(raw) { stage in
                shareImportStage = stage
            }
            switch result {
            case .share(let session):
                chatStore.showToast("已导入「\(session.title)」")
            case .archive(let outcome):
                chatStore.showToast(ChatStore.importSummaryToast(for: outcome, singleShare: false))
            }
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
