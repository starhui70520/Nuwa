import SwiftUI
import UIKit

/// Native iOS camera capture sheet wrapping `UIImagePickerController` (`.camera`).
struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (NuwaLegacyPickedImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView

        init(_ parent: CameraPickerView) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            parent.dismiss()
            guard let image else { return }
            Task.detached(priority: .userInitiated) {
                guard let data = image.jpegData(compressionQuality: 0.92), !data.isEmpty else { return }
                let fileName = "camera_\(Int(Date().timeIntervalSince1970)).jpg"
                await MainActor.run {
                    self.parent.onCapture(NuwaLegacyPickedImage(data: data, fileName: fileName))
                }
            }
        }
    }
}
