import SwiftUI
import UniformTypeIdentifiers

private enum OnboardingStep {
    case home
    case deepseekKey
    case thirdParty
}

/// Exact 1:1 recreation of chat-demo/src/components/onboarding/OnboardingScreen.tsx
/// upgraded with native iOS 26 Liquid Glass pills and native DeepSeek OAuth sheet.
struct OnboardingScreenView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var chatStore: ChatStore
    @Environment(\.openURL) private var openURL

    @State private var step: OnboardingStep = .home
    @State private var keyDraft = ""
    @State private var errorText: String?
    @State private var showDeepSeekAuth = false

    private let docsURL = URL(string: "https://api-docs.deepseek.com/zh-cn/")!
    private let platformKeysURL = URL(string: "https://platform.deepseek.com/api_keys")!

    var body: some View {
        ZStack {
            Color.nuwaBgBase.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: Back (on sub-views) + Help
                HStack {
                    if step == .home {
                        Spacer().frame(width: 60)
                    } else {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                step = .home
                                errorText = nil
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("返回")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .nuwaGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button {
                        openURL(docsURL)
                    } label: {
                        Text("帮助")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .nuwaGlass(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)

                Spacer()

                // Center hero: Nuwa Logo + Title
                VStack(spacing: 16) {
                    Image("NuwaLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 6)

                    Text("Nuwa")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                }

                Spacer()

                // Bottom action group
                VStack(spacing: 12) {
                    if step == .home {
                        Button {
                            showDeepSeekAuth = true
                        } label: {
                            Text("DeepSeek API 账号登录")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.nuwaBrand, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            settings.apiProtocol = .openai
                            settings.apiBaseUrl = "https://api.deepseek.com"
                            settings.apiModel = "deepseek-chat"
                            keyDraft = settings.apiKey
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                step = .deepseekKey
                            }
                        } label: {
                            Text("使用 DeepSeek API Key")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .nuwaGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)

                        Button {
                            keyDraft = settings.apiKey
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                step = .thirdParty
                            }
                        } label: {
                            Text("配置第三方兼容 API")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .nuwaGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            if step == .thirdParty {
                                HStack {
                                    Text("接口协议")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.nuwaLabelSecondary)
                                    Spacer()
                                    Picker("接口协议", selection: $settings.apiProtocol) {
                                        ForEach(ApiProtocol.allCases) { p in
                                            Text(p.displayName).tag(p)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }

                                inputField(
                                    label: "API 地址 (Base URL)",
                                    placeholder: "https://api.deepseek.com",
                                    text: $settings.apiBaseUrl,
                                    secure: false
                                )

                                inputField(
                                    label: "模型名称",
                                    placeholder: "deepseek-chat",
                                    text: $settings.apiModel,
                                    secure: false
                                )
                            }

                            inputField(
                                label: "API Key",
                                placeholder: "请输入 API Key",
                                text: $keyDraft,
                                secure: true
                            )

                            if let errorText {
                                Text(errorText)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }

                            Button {
                                submitApiKey()
                            } label: {
                                Text("验证并继续")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(
                                        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            ? Color.nuwaBrand.opacity(0.4)
                                            : Color.nuwaBrand,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if step == .deepseekKey {
                                Button {
                                    openURL(platformKeysURL)
                                } label: {
                                    Text("前往开放平台获取 API Key")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(Color.nuwaBrandText)
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text("凭据与历史对话仅保存在本地设备")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showDeepSeekAuth) {
            DeepSeekAuthSheet { token, accountLabel, error in
                showDeepSeekAuth = false
                if let token, !token.isEmpty {
                    settings.signInDeepSeekAccount(token: token, label: accountLabel)
                    chatStore.showToast("已登录 DeepSeek API 账号")
                } else if let error, !error.isEmpty {
                    errorText = error
                }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func inputField(label: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.nuwaLabelSecondary)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 15))
            .padding(.horizontal, 16)
            .frame(height: 46)
            .nuwaGlass(in: Capsule(), interactive: false)
        }
    }

    private func submitApiKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "请输入 API Key"
            return
        }
        settings.apiKey = trimmed
        settings.authMode = .apiKey
        settings.completeAuthentication()
    }
}

/// Exact 1:1 recreation of chat-demo/src/components/onboarding/MigrationPromptModal.tsx
struct MigrationPromptModalView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var chatStore: ChatStore
    let onStartOneClickMigration: () -> Void
    let onStartZipImport: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture {
                    settings.dismissMigrationPrompt()
                }

            VStack(spacing: 16) {
                HStack {
                    Text("是否从官方 DeepSeek 迁移历史对话？")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Button {
                        settings.dismissMigrationPrompt()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .frame(width: 30, height: 30)
                            .nuwaGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                }

                Image("NuwaLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)

                Text("将官方网页或 App 的历史会话增量合并到本机永久保存，不受 72 小时限制；也可稍后在设置中随时操作。")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                VStack(spacing: 10) {
                    Button {
                        settings.dismissMigrationPrompt()
                        onStartOneClickMigration()
                    } label: {
                        Text("一键迁移")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color.nuwaBrand, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        settings.dismissMigrationPrompt()
                        onStartZipImport()
                    } label: {
                        Text("上传 ZIP 导出包")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .nuwaGlass(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)

                    Button {
                        settings.dismissMigrationPrompt()
                    } label: {
                        Text("以后再说")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .nuwaGlass(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(22)
            .nuwaGlassCard(cornerRadius: 26, interactive: false)
            .padding(.horizontal, 24)
        }
    }
}
