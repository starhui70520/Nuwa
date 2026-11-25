import SwiftUI

/// Inline lightweight compaction divider rendered inside ChatTimeline right after a compacted span's end message
/// (1:1 chat-demo/src/components/messages/CompactionCard.tsx).
struct CompactionCardView: View {
    let span: CompactionSpan
    let locale: AppLocale
    let isExpanded: Bool
    let onToggleExpanded: (Bool) -> Void
    let onSave: (String) -> Void
    let onRestore: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @Environment(\.nuwaFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.nuwaControlBorder)
                    .frame(height: 0.75)

                Button {
                    if isExpanded { editing = false }
                    onToggleExpanded(!isExpanded)
                } label: {
                    HStack(spacing: 5) {
                        Text(span.title)
                            .font(NuwaFont.badge(fontScale))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .lineLimit(1)

                        Text("· \(L10n.t("compactMemorySavedTokens", locale: locale).replacingOccurrences(of: "{rounds}", with: String(span.coveredRounds)))")
                            .font(NuwaFont.badge(fontScale))
                            .foregroundStyle(Color.nuwaLabelTertiary)
                            .lineLimit(1)

                        if span.editedByUser == true {
                            Text(L10n.t("compactMemoryEditedBadge", locale: locale))
                                .font(NuwaFont.sized(10, weight: .medium, scale: fontScale))
                                .foregroundStyle(Color.nuwaBrandText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.nuwaBrand.opacity(0.12), in: Capsule())
                        }

                        Text(L10n.t(isExpanded ? "compactMemoryCollapse" : "compactMemoryExpand", locale: locale))
                            .font(NuwaFont.badge(fontScale))
                            .foregroundStyle(Color.nuwaBrandText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .nuwaPillSurface()
                }
                .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.97))

                Rectangle()
                    .fill(Color.nuwaControlBorder)
                    .frame(height: 0.75)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if editing {
                        CompactionSummaryEditor(text: $draft, background: Color(.secondarySystemBackground))
                            .frame(minHeight: 150, maxHeight: 240)
                    } else {
                        Text(span.summary)
                            .font(NuwaFont.caption(fontScale))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.t("compactMemoryRestoreHint", locale: locale))
                            .font(NuwaFont.sized(11.5, scale: fontScale))
                            .foregroundStyle(Color.nuwaLabelTertiary)

                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            if editing {
                                Button {
                                    editing = false
                                    draft = span.summary
                                } label: {
                                    Text(L10n.t("compactMemoryCancel", locale: locale))
                                        .font(NuwaFont.captionMedium(fontScale))
                                        .foregroundStyle(Color.nuwaLabelSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .nuwaPillSurface()
                                }
                                .buttonStyle(NuwaTactileButtonStyle())

                                let canSave = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                Button {
                                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    onSave(trimmed)
                                    editing = false
                                } label: {
                                    Text(L10n.t("compactMemorySave", locale: locale))
                                        .font(NuwaFont.captionMedium(fontScale))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(canSave ? Color.nuwaBrand : Color.nuwaBrand.opacity(0.4), in: Capsule())
                                }
                                .buttonStyle(NuwaTactileButtonStyle())
                                .disabled(!canSave)
                            } else {
                                Button(action: onRestore) {
                                    Text(L10n.t("compactMemoryRestore", locale: locale))
                                        .font(NuwaFont.captionMedium(fontScale))
                                        .foregroundStyle(.red)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .nuwaPillSurface(destructive: true)
                                }
                                .buttonStyle(NuwaTactileButtonStyle())

                                Button {
                                    draft = span.summary
                                    editing = true
                                } label: {
                                    Text(L10n.t("compactMemoryEdit", locale: locale))
                                        .font(NuwaFont.captionMedium(fontScale))
                                        .foregroundStyle(Color.nuwaLabelPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .nuwaPillSurface()
                                }
                                .buttonStyle(NuwaTactileButtonStyle())
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color.nuwaDrawerCardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75)
                )
            }
        }
        .padding(.top, 12)
        .nuwaOnChange(of: isExpanded) { expanded in
            if !expanded { editing = false }
        }
    }
}
