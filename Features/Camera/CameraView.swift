import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var captureVideo = false
    @State private var capturedImage: UIImage?
    @State private var cameraError: String?
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                PageHeader(title: "拍摄", subtitle: "捕捉此刻", symbol: "camera")
                if let capturedImage {
                    Image(uiImage: capturedImage).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .frame(maxHeight: 420)
                    Button {
                        if let data = capturedImage.jpegData(compressionQuality: 0.92) {
                            model.mediaStore.importImage(data, title: "拍摄的照片")
                        }
                        self.capturedImage = nil
                    } label: {
                        Label("保存到库", systemImage: "square.and.arrow.down")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(MoonGlassButtonStyle(prominent: true)).tint(MoonStyle.accent)
                } else {
                    EmptyPanel(title: "准备好记录此刻了吗？", detail: "拍摄或从照片图库导入，内容会保存到库。", symbol: "camera")
                    Button {
                        captureVideo = false
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        else { cameraError = "当前设备没有可用的相机，请从照片图库导入。" }
                    } label: {
                        Label("打开相机", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(MoonGlassButtonStyle(prominent: true)).tint(MoonStyle.accent)
                    Button {
                        captureVideo = true
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        else { cameraError = "当前设备没有可用的相机，请从照片图库导入视频。" }
                    } label: {
                        Label("录制视频", systemImage: "video.fill")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(MoonGlassButtonStyle())
                    Button { showPicker = true } label: {
                        Label("从照片图库导入", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(MoonGlassButtonStyle())
                }
            }
            .padding(.horizontal, 18).padding(.top, 12)
            .alert("提示", isPresented: Binding(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })) {
                Button("好", role: .cancel) { cameraError = nil }
            } message: { Text(cameraError ?? "") }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView(captureVideo: captureVideo, onCapture: { image in
                    capturedImage = image
                }, onCaptureVideo: { url in
                    model.mediaStore.importVideoFile(url, title: "拍摄的视频")
                })
                    .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPicker, selection: $selectedPhoto, matching: .any(of: [.images, .videos]))
            .task(id: selectedPhoto) {
                guard let selectedPhoto,
                      let data = try? await selectedPhoto.loadTransferable(type: Data.self) else { return }
                if let image = UIImage(data: data) { capturedImage = image }
                else if let type = selectedPhoto.supportedContentTypes.first, type.conforms(to: .movie) {
                    model.mediaStore.importMedia(data, title: "导入的视频", kind: .video, fileExtension: type.preferredFilenameExtension ?? "mov")
                }
            }
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let captureVideo: Bool
    let onCapture: (UIImage) -> Void
    let onCaptureVideo: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCaptureVideo: onCaptureVideo, dismiss: dismiss) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [captureVideo ? UTType.movie.identifier : UTType.image.identifier]
        picker.cameraCaptureMode = captureVideo ? .video : .photo
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 300
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCaptureVideo: (URL) -> Void
        let dismiss: DismissAction
        init(onCapture: @escaping (UIImage) -> Void, onCaptureVideo: @escaping (URL) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture; self.onCaptureVideo = onCaptureVideo; self.dismiss = dismiss
        }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) }
            if let url = info[.mediaURL] as? URL { onCaptureVideo(url) }
            dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
