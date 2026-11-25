import SwiftUI

enum ContextPressureLevel {
    case green
    case yellow
    case orange
    case red

    init(pressure: Double) {
        if pressure >= 0.9 {
            self = .red
        } else if pressure >= 0.75 {
            self = .orange
        } else if pressure >= 0.5 {
            self = .yellow
        } else {
            self = .green
        }
    }

    var color: Color {
        switch self {
        case .green: return Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
        case .yellow: return Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255)
        case .orange: return Color(red: 249 / 255, green: 115 / 255, blue: 22 / 255)
        case .red: return Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
        }
    }
}

/// Compact 4-color circular ring trigger embedded in the top-right header capsule.
struct ContextStatusTriggerButton: View {
    let stats: ContextStats
    let compactProgress: CompactionProgress?
    let locale: AppLocale
    let onTap: () -> Void

    @State private var spinning = false
    @Environment(\.colorScheme) private var colorScheme

    private var isCompacting: Bool { compactProgress != nil }

    var body: some View {
        let level = ContextPressureLevel(pressure: stats.pressure)
        let trimFraction = isCompacting ? 0.35 : max(0.08, min(1.0, stats.pressure))

        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(
                        Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12),
                        lineWidth: 2.3
                    )
                    .frame(width: 17, height: 17)

                Circle()
                    .trim(from: 0, to: trimFraction)
                    .stroke(
                        level.color,
                        style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
                    )
                    .frame(width: 17, height: 17)
                    .animation(.easeOut(duration: 0.25), value: trimFraction)
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .animation(
                        spinning
                            ? .linear(duration: 0.95).repeatForever(autoreverses: false)
                            : .default,
                        value: spinning
                    )
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("contextStatusModalTitle", locale: locale))
        .onAppear {
            if isCompacting { spinning = true }
        }
        .nuwaOnChange(of: isCompacting) { active in
            spinning = active
        }
    }
}

/// Native sheet displaying context usage, compacted memory blocks (expand / keywords / edit / restore),
/// and manual batch compaction / stop controls (1:1 ContextStatus.tsx).
struct ContextMemorySheetView: View {
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var settings: SettingsStore
    let sessionId: UUID
    let onRequireCredential: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nuwaFontScale) private var fontScale

    private var loc: AppLocale { settings.locale }

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

    var body: some View {
        let session = chatStore.sessions.first(where: { $0.id == sessionId })
        let visible = session?.hasLoadedMessages == true ? (session?.visibleMessages() ?? []) : []
        let stats = ContextCompaction.inspectContextStats(visibleMessages: visible, compactions: session?.compactions)
        let compactProgress = chatStore.compactingProgress[sessionId]
        let compacting = compactProgress != nil
        let level = ContextPressureLevel(pressure: stats.pressure)
        let tailKept = min(stats.uncompactedCount, ContextCompaction.protectedTailRounds)

        ZStack {
            sheetBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Color.clear.frame(width: 36, height: 36)
                    Text(L10n.t("contextStatusModalTitle", locale: loc))
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
                    .accessibilityLabel(L10n.t("close", locale: loc))
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Overview Card
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                L10n.t("contextStatusCurrentTokens", locale: loc)
                                    .replacingOccurrences(of: "{tokens}", with: ContextCompaction.formatTokens(stats.effectiveTokens))
                            )
                            .font(NuwaFont.bodyMedium(fontScale))
                            .foregroundStyle(Color.nuwaLabelPrimary)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                                    Capsule()
                                        .fill(level.color)
                                        .frame(width: max(geo.size.width * 0.04, geo.size.width * CGFloat(stats.pressure)))
                                        .animation(.easeOut(duration: 0.25), value: stats.pressure)
                                }
                            }
                            .frame(height: 7)

                            Text(
                                L10n.t("contextStatusBreakdown", locale: loc)
                                    .replacingOccurrences(of: "{total}", with: String(stats.totalRounds))
                                    .replacingOccurrences(of: "{compacted}", with: String(stats.compactedRounds))
                                    .replacingOccurrences(of: "{tail}", with: String(tailKept))
                            )
                            .font(NuwaFont.caption(fontScale))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // Section Header
                        Text(
                            L10n.t("contextStatusMemoryListTitle", locale: loc)
                                .replacingOccurrences(of: "{count}", with: String(stats.activeCompactions.count))
                        )
                        .font(NuwaFont.sectionHeader(fontScale))
                        .foregroundStyle(Color.nuwaLabelTertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)

                        if stats.activeCompactions.isEmpty {
                            Text(L10n.t("contextStatusMemoryEmpty", locale: loc))
                                .font(NuwaFont.sublabel(fontScale))
                                .foregroundStyle(Color.nuwaLabelSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 28)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity)
                                .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            VStack(spacing: 10) {
                                ForEach(stats.activeCompactions, id: \.span.id) { item in
                                    MemoryListItemCard(
                                        span: item.span,
                                        locale: loc,
                                        cardBg: cardBg,
                                        editorBg: sheetBg,
                                        onSave: { updatedSummary in
                                            chatStore.updateCompactionSummary(
                                                sessionId: sessionId,
                                                spanId: item.span.id,
                                                summary: updatedSummary
                                            )
                                            chatStore.showToast(L10n.t("compactMemorySavedToast", locale: loc))
                                        },
                                        onRestore: {
                                            chatStore.deleteCompactionSpan(sessionId: sessionId, spanId: item.span.id)
                                            chatStore.showToast(L10n.t("compactMemoryRestoredToast", locale: loc))
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .nuwaNoScrollEdgeEffect()

                // Sticky Footer
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.nuwaControlBorder)
                        .frame(height: 0.75)

                    HStack(spacing: 12) {
                        Text(footerHint(progress: compactProgress, canManualCompact: stats.canManualCompact))
                            .font(NuwaFont.caption(fontScale))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        if compacting {
                            Button {
                                chatStore.stopCompaction(sessionId)
                            } label: {
                                Text(L10n.t("compactMemoryStopButton", locale: loc))
                                    .font(NuwaFont.pill(fontScale))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .nuwaPillSurface(destructive: true)
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        } else {
                            let disabled = chatStore.isGenerating || chatStore.importingHistory || !stats.canManualCompact
                            Button {
                                guard settings.hasActiveCredential else {
                                    dismiss()
                                    onRequireCredential()
                                    return
                                }
                                Task {
                                    let ok = await chatStore.compactSession(sessionId, source: .manual, settings: settings)
                                    chatStore.showToast(L10n.t(ok ? "compactMemorySuccess" : "compactMemoryEmpty", locale: loc))
                                }
                            } label: {
                                Text(L10n.t("compactMemoryNowButton", locale: loc))
                                    .font(NuwaFont.pill(fontScale))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        disabled ? Color.nuwaBrand.opacity(0.38) : Color.nuwaBrand,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                            .disabled(disabled)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(cardBg.ignoresSafeArea(edges: .bottom))
            }
        }
        .environment(\.nuwaFontScale, fontScale)
        .nuwaPresentationDragIndicatorVisible()
    }

    private func footerHint(progress: CompactionProgress?, canManualCompact: Bool) -> String {
        if let progress {
            if progress.total > 1 {
                return L10n.t("compactMemoryProgress", locale: loc)
                    .replacingOccurrences(of: "{done}", with: String(progress.done))
                    .replacingOccurrences(of: "{total}", with: String(progress.total))
            }
            return L10n.t("compactMemoryRunning", locale: loc)
        }
        return L10n.t(canManualCompact ? "contextStatusAutoHint" : "contextStatusUpToDate", locale: loc)
    }
}

private struct MemoryListItemCard: View {
    let span: CompactionSpan
    let locale: AppLocale
    let cardBg: Color
    let editorBg: Color
    let onSave: (String) -> Void
    let onRestore: () -> Void

    @State private var expanded = false
    @State private var editing = false
    @State private var draft = ""
    @Environment(\.nuwaFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                    if !expanded { editing = false }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(span.title)
                        .font(NuwaFont.controlMedium(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .lineLimit(1)

                    if span.editedByUser == true {
                        Circle()
                            .fill(Color.nuwaBrand)
                            .frame(width: 6, height: 6)
                    }

                    Spacer(minLength: 8)

                    Text(L10n.t(expanded ? "compactMemoryCollapse" : "compactMemoryExpand", locale: locale))
                        .font(NuwaFont.captionMedium(fontScale))
                        .foregroundStyle(Color.nuwaBrandText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Rectangle()
                    .fill(Color.nuwaControlBorder)
                    .frame(height: 0.75)
                    .padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 10) {
                    if let keywords = span.keywords, !keywords.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(keywords, id: \.self) { kw in
                                    Text(kw)
                                        .font(NuwaFont.badge(fontScale))
                                        .foregroundStyle(Color.nuwaBrandText)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Color.nuwaBrand.opacity(0.11), in: Capsule())
                                }
                            }
                        }
                    }

                    if editing {
                        CompactionSummaryEditor(text: $draft, background: editorBg)
                            .frame(minHeight: 160, maxHeight: 240)
                    } else {
                        Text(span.summary)
                            .font(NuwaFont.caption(fontScale))
                            .foregroundStyle(Color.nuwaLabelSecondary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

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
                                let cleaned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !cleaned.isEmpty else { return }
                                onSave(cleaned)
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
                .padding(14)
            }
        }
        .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// iOS 15–26 safe multiline summary editor shared by ContextMemorySheetView & CompactionCardView.
struct CompactionSummaryEditor: View {
    @Binding var text: String
    let background: Color
    @Environment(\.nuwaFontScale) private var fontScale

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .font(NuwaFont.caption(fontScale))
                    .foregroundStyle(Color.nuwaLabelPrimary)
            } else {
                TextEditor(text: $text)
                    .font(NuwaFont.caption(fontScale))
                    .foregroundStyle(Color.nuwaLabelPrimary)
            }
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75)
        )
    }
}
