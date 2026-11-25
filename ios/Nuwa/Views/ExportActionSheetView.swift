import SwiftUI
import UIKit

enum ExportDestination: Equatable {
    case share
    case save
}

/// Native export destination choice sheet (1:1 chat-demo/src/components/base/ExportActionModal.tsx):
/// 1. Send to Another App (`UIActivityViewController`)
/// 2. Save to Device (`UIDocumentPickerViewController(forExporting:)`)
struct ExportActionSheetView: View {
    let title: String
    let subtitle: String?
    let locale: AppLocale
    let busyMode: ExportDestination?
    let onSelect: (ExportDestination) -> Void
    let onCancel: () -> Void

    @Environment(\.nuwaFontScale) private var fontScale

    private var isBusy: Bool { busyMode != nil }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(NuwaFont.navTitle(fontScale))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(NuwaFont.caption(fontScale))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            VStack(spacing: 10) {
                optionRow(
                    mode: .share,
                    title: L10n.t("exportOptionShare", locale: locale),
                    subtitle: L10n.t("exportOptionShareDesc", locale: locale),
                    icon: "square.and.arrow.up"
                )
                optionRow(
                    mode: .save,
                    title: L10n.t("exportOptionSave", locale: locale),
                    subtitle: L10n.t("exportOptionSaveDesc", locale: locale),
                    icon: "folder.badge.plus"
                )
            }

            Button(role: .cancel, action: onCancel) {
                Text(L10n.t("cancel", locale: locale))
                    .font(NuwaFont.controlMedium(fontScale))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .nuwaPresentationDetents(height: min(400, max(300, 224 + 78 * fontScale)), includeMedium: true)
        .nuwaPresentationDragIndicatorVisible()
    }

    @ViewBuilder
    private func optionRow(
        mode: ExportDestination,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let isActive = busyMode == mode
        Button {
            onSelect(mode)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.nuwaBrand.opacity(0.14))
                        .frame(width: 38, height: 38)
                    if isActive {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.nuwaBrand)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.nuwaBrand)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isActive ? L10n.t("exporting", locale: locale) : title)
                        .font(NuwaFont.bodyMedium(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Text(subtitle)
                        .font(NuwaFont.caption(fontScale))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.nuwaLabelTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.98))
        .disabled(isBusy)
    }
}

/// Presents native `UIActivityViewController` (share) or `UIDocumentPickerViewController` (save to Files)
/// reliably from any SwiftUI screen or sheet without nested SwiftUI presentation conflicts.
@MainActor
enum ExportPresenter {
    private static var activeDocumentDelegate: DocumentExportDelegate?

    static func present(
        fileURL: URL,
        destination: ExportDestination,
        onFinished: @escaping (_ completed: Bool) -> Void
    ) {
        guard let presenter = topMostViewController() else {
            onFinished(false)
            return
        }
        switch destination {
        case .share:
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, completed, _, _ in
                onFinished(completed)
            }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            presenter.present(activityVC, animated: true)

        case .save:
            let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            let delegate = DocumentExportDelegate { completed in
                activeDocumentDelegate = nil
                onFinished(completed)
            }
            activeDocumentDelegate = delegate
            picker.delegate = delegate
            if let popover = picker.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            presenter.present(picker, animated: true)
        }
    }

    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        var cursor = keyWindow?.rootViewController
        while let presented = cursor?.presentedViewController {
            cursor = presented
        }
        return cursor
    }

    private final class DocumentExportDelegate: NSObject, UIDocumentPickerDelegate {
        private let onFinished: (Bool) -> Void

        init(onFinished: @escaping (Bool) -> Void) {
            self.onFinished = onFinished
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinished(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinished(false)
        }
    }
}
