import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - onChange compatibility (iOS 15 - 26)

private struct LegacyOnChangeWithOldModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void
    @State private var previous: Value

    init(value: Value, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.action = action
        self._previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onChange(of: value) { newValue in
            let oldValue = previous
            previous = newValue
            action(oldValue, newValue)
        }
    }
}

extension View {
    @ViewBuilder
    func nuwaOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }

    @ViewBuilder
    func nuwaOnChange<V: Equatable>(of value: V, perform action: @escaping (V, V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { oldValue, newValue in
                action(oldValue, newValue)
            }
        } else {
            self.modifier(LegacyOnChangeWithOldModifier(value: value, action: action))
        }
    }

    @ViewBuilder
    func nuwaPresentationDetents(height: CGFloat, includeMedium: Bool = false) -> some View {
        if #available(iOS 16.0, *) {
            if includeMedium {
                self.presentationDetents([.height(height), .medium])
            } else {
                self.presentationDetents([.height(height)])
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func nuwaPresentationDragIndicatorVisible() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    @ViewBuilder
    func nuwaScrollDismissesKeyboardInteractively() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    @ViewBuilder
    func nuwaGeometryGroup() -> some View {
        if #available(iOS 17.0, *) {
            self.geometryGroup()
        } else {
            self
        }
    }
}

// MARK: - UnevenRoundedRectangle compatibility (iOS 15+)

struct NuwaUnevenRoundedRectangle: Shape {
    var topLeadingRadius: CGFloat = 0
    var bottomLeadingRadius: CGFloat = 0
    var bottomTrailingRadius: CGFloat = 0
    var topTrailingRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let tl = min(min(topLeadingRadius, h / 2), w / 2)
        let tr = min(min(topTrailingRadius, h / 2), w / 2)
        let bl = min(min(bottomLeadingRadius, h / 2), w / 2)
        let br = min(min(bottomTrailingRadius, h / 2), w / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
            radius: tr,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(
            center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
            radius: bl,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(
            center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
            radius: tl,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - iOS 15 Multi-line Auto-Growing TextView (fallback for TextField(..., axis: .vertical))

struct NuwaLegacyMultilineTextField: View {
    let placeholder: String
    @Binding var text: String
    var uiFont: UIFont
    var minLines: Int = 1
    var maxLines: Int = 6
    var isFocused: Binding<Bool>? = nil

    @State private var measuredHeight: CGFloat = 24

    private var lineHeight: CGFloat { max(18, ceil(uiFont.lineHeight)) }
    private var minHeight: CGFloat { max(24, CGFloat(minLines) * lineHeight + 4) }
    private var maxHeight: CGFloat { max(minHeight, CGFloat(maxLines) * lineHeight + 8) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(Font(uiFont))
                    .foregroundStyle(Color.nuwaLabelTertiary)
                    .padding(.top, 2)
                    .padding(.leading, 1)
                    .allowsHitTesting(false)
            }
            NuwaLegacyTextViewRepresentable(
                text: $text,
                measuredHeight: $measuredHeight,
                uiFont: uiFont,
                maxHeight: maxHeight,
                isFocused: isFocused
            )
            .frame(height: min(maxHeight, max(minHeight, measuredHeight)))
        }
    }
}

private struct NuwaLegacyTextViewRepresentable: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let uiFont: UIFont
    let maxHeight: CGFloat
    let isFocused: Binding<Bool>?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = uiFont
        tv.textColor = UIColor.label
        tv.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.font != uiFont {
            uiView.font = uiFont
        }
        if uiView.text != text {
            uiView.text = text
        }
        if let focusBinding = isFocused {
            let wantsFocus = focusBinding.wrappedValue
            if wantsFocus && !uiView.isFirstResponder && uiView.window != nil {
                DispatchQueue.main.async {
                    if !uiView.isFirstResponder {
                        uiView.becomeFirstResponder()
                    }
                }
            } else if !wantsFocus && uiView.isFirstResponder {
                DispatchQueue.main.async {
                    if uiView.isFirstResponder {
                        uiView.resignFirstResponder()
                    }
                }
            }
        }
        recalcHeight(uiView)
    }

    fileprivate func recalcHeight(_ tv: UITextView) {
        let width = tv.bounds.width
        guard width > 1 else { return }
        let fitted = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let clamped = min(maxHeight, max(24, ceil(fitted)))
        let shouldScroll = fitted > maxHeight + 1
        if tv.isScrollEnabled != shouldScroll {
            tv.isScrollEnabled = shouldScroll
        }
        if abs(measuredHeight - clamped) > 0.5 {
            DispatchQueue.main.async {
                self.measuredHeight = clamped
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NuwaLegacyTextViewRepresentable

        init(_ parent: NuwaLegacyTextViewRepresentable) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let newText = textView.text ?? ""
            if parent.text != newText {
                parent.text = newText
            }
            parent.recalcHeight(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if let focus = parent.isFocused, !focus.wrappedValue {
                DispatchQueue.main.async { focus.wrappedValue = true }
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if let focus = parent.isFocused, focus.wrappedValue {
                DispatchQueue.main.async { focus.wrappedValue = false }
            }
        }
    }
}

// MARK: - iOS 15 PHPickerViewController wrapper (fallback for PhotosPicker)

struct NuwaLegacyPickedImage: Sendable {
    let data: Data
    let fileName: String
}

struct NuwaLegacyPhotoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPicked: ([NuwaLegacyPickedImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = selectionLimit
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: NuwaLegacyPhotoPicker

        init(_ parent: NuwaLegacyPhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            let lock = NSLock()
            var loaded: [(Int, NuwaLegacyPickedImage)] = []

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                let suggested = provider.suggestedName ?? "photo_\(Int(Date().timeIntervalSince1970))_\(index)"
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    group.enter()
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        defer { group.leave() }
                        guard let data, !data.isEmpty else { return }
                        let ext = Self.guessExtension(data)
                        let fileName = suggested.contains(".") ? suggested : "\(suggested).\(ext)"
                        lock.lock()
                        loaded.append((index, NuwaLegacyPickedImage(data: data, fileName: fileName)))
                        lock.unlock()
                    }
                } else if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { obj, _ in
                        defer { group.leave() }
                        guard let image = obj as? UIImage,
                              let data = image.jpegData(compressionQuality: 0.9) else { return }
                        lock.lock()
                        loaded.append((index, NuwaLegacyPickedImage(data: data, fileName: "\(suggested).jpg")))
                        lock.unlock()
                    }
                }
            }

            group.notify(queue: .main) {
                let ordered = loaded.sorted { $0.0 < $1.0 }.map(\.1)
                if !ordered.isEmpty {
                    self.parent.onPicked(ordered)
                }
            }
        }

        private static func guessExtension(_ data: Data) -> String {
            let b = [UInt8](data.prefix(12))
            if b.count >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "png" }
            if b.count >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return "gif" }
            if b.count >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 { return "webp" }
            return "jpg"
        }
    }
}
