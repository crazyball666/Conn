import SwiftUI
import UIKit

/// 终端附件菜单的系统相机入口。相片只留在本机，随后走现有附件上传链路。
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onImage: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onImage(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
