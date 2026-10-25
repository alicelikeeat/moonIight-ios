import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shown only when this device has no camera (the simulator). A real device presents
/// `UIImagePickerController` full screen from `AppModel` and never builds this view.
struct MoonCamera: View {
    var video: Bool
    var onImage: (UIImage) -> Void
    var onVideo: (URL) -> Void
    var onCancel: () -> Void
    @State private var library: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("这台设备没有相机")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                Text(video ? "可以从相册选一段视频。" : "可以从相册选一张照片。")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.75))
                PhotosPicker(selection: $library, matching: video ? .videos : .images) {
                    Text(video ? "从相册选视频" : "从相册选照片")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .moonCapsule(overMedia: true)
                }
                .accessibilityIdentifier("camera.library")
                .accessibilityLabel(video ? "从相册选视频" : "从相册选照片")
                Button("关闭") { onCancel() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .accessibilityIdentifier("camera.close")
            }
            .padding(28)
        }
        .accessibilityElement(children: .contain)
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 4, height: 4)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("camera.root")
                .accessibilityLabel("相机")
        }
        .moonOnChange(of: library) { item in
            guard let item else { return }
            Task {
                if let saved = await PickedMedia.load(item, folder: MediaStore.inbox),
                   let path = MediaStore.resolve(saved.name, folder: MediaStore.inbox) {
                    if saved.video {
                        onVideo(URL(fileURLWithPath: path))
                    } else if let image = UIImage(contentsOfFile: path) {
                        onImage(image)
                    }
                }
                library = nil
            }
        }
    }
}

/// System camera hosted by SwiftUI's full-screen cover. The delegate never calls dismiss;
/// clearing the cover binding is the only way the camera goes away.
struct SystemCameraPicker: UIViewControllerRepresentable {
    var video: Bool
    var onImage: (Data) -> Void
    var onVideo: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        let available = UIImagePickerController.availableMediaTypes(for: .camera) ?? []
        let types = [UTType.image.identifier, UTType.movie.identifier].filter { available.contains($0) }
        picker.mediaTypes = types.isEmpty ? [UTType.image.identifier] : types
        if video, picker.mediaTypes.contains(UTType.movie.identifier) {
            picker.cameraCaptureMode = .video
        } else {
            picker.cameraCaptureMode = .photo
        }
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        context.coordinator.onImage = onImage
        context.coordinator.onVideo = onVideo
        context.coordinator.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onVideo: onVideo, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onImage: (Data) -> Void
        var onVideo: (URL) -> Void
        var onCancel: () -> Void
        private var finished = false

        init(onImage: @escaping (Data) -> Void, onVideo: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onVideo = onVideo
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !finished else { return }
            finished = true
            onCancel()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard !finished else { return }
            finished = true
            if let url = info[.mediaURL] as? URL {
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                if let copied = MediaStore.copy(from: url, folder: MediaStore.inbox, ext: ext) {
                    onVideo(copied)
                } else {
                    onCancel()
                }
                return
            }
            let image = (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage)
            if let image, let data = image.jpegData(compressionQuality: 0.92) {
                onImage(data)
                return
            }
            onCancel()
        }
    }
}
