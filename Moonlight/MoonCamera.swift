import PhotosUI
import SwiftUI
import UIKit

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
