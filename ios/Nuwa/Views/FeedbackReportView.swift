import SwiftUI
import UIKit

/// 1:1 port of chat-demo/src/components/settings/FeedbackReportPage.tsx
struct FeedbackReportView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var logStore = AppLogStore.shared
    @Environment(\.nuwaFontScale) private var fontScale

    @State private var issueType = AppLogStore.issueTypeOptions[0]
    @State private var descriptionText = ""
    @State private var contactText = ""
    @State private var includeLogs = true
    @State private var showLogPreview = false
    @State private var submitting = false
    @State private var submitError: String?
    @State private var reportCode: String?
    @State private var copied = false

    let cardBg: Color
    let fieldBg: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reportCode {
                VStack(spacing: 14) {
                    Text("日志上报成功")
                        .font(NuwaFont.navTitle(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)

                    Text("请将下方记录码发给开发者，我们会根据记录码快速定位并修复您遇到的问题。")
                        .font(NuwaFont.caption(fontScale))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                        .multilineTextAlignment(.center)

                    Text(reportCode)
                        .font(NuwaFont.sized(22, weight: .bold, design: .monospaced, scale: fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(fieldBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 10) {
                        Button {
                            UIPasteboard.general.string = reportCode
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Text(copied ? "已复制记录码" : "复制记录码")
                                .font(NuwaFont.sized(14, weight: .semibold, scale: fontScale))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(Color.nuwaBrand, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            self.reportCode = nil
                            descriptionText = ""
                            submitError = nil
                        } label: {
                            Text("继续提交")
                                .font(NuwaFont.pill(fontScale))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .nuwaPillSurface()
                        }
                        .buttonStyle(NuwaTactileButtonStyle())
                    }
                }
                .padding(20)
                .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("遇到的问题")
                        .font(NuwaFont.captionMedium(fontScale))
                        .foregroundStyle(Color.nuwaLabelSecondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(AppLogStore.issueTypeOptions, id: \.self) { opt in
                            let selected = issueType == opt
                            Button {
                                issueType = opt
                            } label: {
                                Text(opt)
                                    .font(NuwaFont.sized(12, weight: selected ? .semibold : .regular, scale: fontScale))
                                    .foregroundStyle(selected ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity)
                                    .nuwaPillSurface(selected: selected)
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("详细描述")
                            .font(NuwaFont.captionMedium(fontScale))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                        if #available(iOS 16.0, *) {
                            TextField("请描述复现步骤或异常现象...", text: $descriptionText, axis: .vertical)
                                .lineLimit(3...6)
                                .font(NuwaFont.sublabel(fontScale))
                                .padding(12)
                                .background(fieldBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            NuwaLegacyMultilineTextField(
                                placeholder: "请描述复现步骤或异常现象...",
                                text: $descriptionText,
                                uiFont: UIFont.systemFont(ofSize: 14 * fontScale),
                                minLines: 3,
                                maxLines: 6
                            )
                            .padding(12)
                            .background(fieldBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("联系方式（可选）")
                            .font(NuwaFont.captionMedium(fontScale))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                        TextField("邮箱 / 微信 / GitHub ID", text: $contactText)
                            .font(NuwaFont.sublabel(fontScale))
                            .padding(.horizontal, 12)
                            .frame(minHeight: max(42, 28 + 14 * fontScale))
                            .background(fieldBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Toggle(isOn: $includeLogs) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("附带最近运行日志（\(logStore.logs.count) 条）")
                                .font(NuwaFont.sublabel(fontScale))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                            Text("已自动脱敏 API Key 与令牌")
                                .font(NuwaFont.badge(fontScale))
                                .foregroundStyle(Color.nuwaLabelTertiary)
                        }
                    }
                    .tint(Color.nuwaBrand)

                    if includeLogs && !logStore.logs.isEmpty {
                        Button {
                            withAnimation { showLogPreview.toggle() }
                        } label: {
                            HStack {
                                Text(showLogPreview ? "收起日志预览" : "查看即将上传的日志")
                                    .font(NuwaFont.badge(fontScale))
                                    .foregroundStyle(Color.nuwaBrandText)
                                Spacer()
                                Image(systemName: showLogPreview ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(Color.nuwaBrandText)
                            }
                        }
                        .buttonStyle(.plain)

                        if showLogPreview {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(logStore.logs.suffix(15)) { entry in
                                    Text("[\(entry.level.rawValue.uppercased())] \(entry.source): \(entry.message)")
                                        .font(NuwaFont.sized(11, design: .monospaced, scale: fontScale))
                                        .foregroundStyle(Color.nuwaLabelSecondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(fieldBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }

                    if let submitError {
                        Text(submitError)
                            .font(NuwaFont.caption(fontScale))
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            if submitting {
                                ProgressView().tint(.white).controlSize(.small)
                            }
                            Text(submitting ? "正在上报..." : "提交反馈并生成记录码")
                                .font(NuwaFont.sized(15, weight: .semibold, scale: fontScale))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(46, 30 + 16 * fontScale))
                        .background(
                            (submitting || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                ? Color.nuwaBrand.opacity(0.4)
                                : Color.nuwaBrand,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(submitting || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
                .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.top, 8)
    }

    private func submit() async {
        let trimmed = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            submitError = "请简要描述您遇到的问题"
            return
        }
        submitting = true
        submitError = nil
        defer { submitting = false }
        do {
            let result = try await logStore.submitReport(
                issueType: issueType,
                description: trimmed,
                contact: contactText,
                includeLogs: includeLogs,
                settings: settings
            )
            reportCode = result.code
            copied = false
        } catch {
            submitError = error.localizedDescription
        }
    }
}
