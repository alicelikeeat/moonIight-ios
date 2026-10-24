import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// AVFoundation camera. The system picker is not used. A machine without a camera keeps the sheet open and offers the library.
struct MoonCamera: View {
    var video: Bool
    var onImage: (UIImage) -> Void
    var onVideo: (URL) -> Void
    var onCancel: () -> Void
    @StateObject private var rig = CameraRig()
    @State private var library: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if rig.missing {
                fallback("这台设备没有相机", "可以从相册选一张，拍摄按钮不会什么都不做。")
            } else if rig.denied {
                fallback("需要相机权限才能拍摄", "到系统设置里允许月光使用相机，或改从相册选择。")
            } else {
                CameraPreview(session: rig.session)
                    .ignoresSafeArea()
                VStack {
                    HStack {
                        Button("关闭") { onCancel() }
                            .accessibilityIdentifier("camera.close")
                        Spacer()
                        if video {
                            Button(rig.usingFront ? "后置" : "前置") { rig.flip() }
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding()
                    Spacer()
                    Button(video ? (rig.recording ? "停止" : "开始录像") : "快门") {
                        if video { rig.toggleRecord { onVideo($0) } }
                        else { rig.takePhoto { onImage($0) } }
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .moonCapsule(overMedia: true)
                    .padding(.bottom, 28)
                    .accessibilityIdentifier("camera.shutter")
                }
            }
        }
        .accessibilityIdentifier("camera.root")
        .onAppear { rig.prepare(record: video) }
        .onDisappear { rig.stop() }
    }

    private func fallback(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(detail).font(.system(size: 14)).multilineTextAlignment(.center).foregroundColor(.white.opacity(0.75))
            PhotosPicker(selection: $library, matching: video ? .videos : .images) {
                Text(video ? "从相册选视频" : "从相册选照片")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .moonCapsule(overMedia: true)
                    .accessibilityIdentifier("camera.library")
            }
            .accessibilityIdentifier("camera.library")
            .accessibilityLabel(video ? "从相册选视频" : "从相册选照片")
            Button("关闭") { onCancel() }
                .accessibilityIdentifier("camera.close")
        }
        .foregroundColor(.white)
        .padding(28)
        .moonOnChange(of: library) { item in
            guard let item else { return }
            Task {
                if video, let movie = try? await item.loadTransferable(type: MovieFile.self) {
                    onVideo(movie.url)
                } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    onImage(image)
                }
                library = nil
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    var session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewHost, context: Context) {
        uiView.preview.session = session
    }
}

final class PreviewHost: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

final class CameraRig: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    @Published var missing = false
    @Published var denied = false
    @Published var recording = false
    @Published var usingFront = false
    private let photo = AVCapturePhotoOutput()
    private let movie = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "moon.camera")
    private var recordVideo = false
    private var onPhoto: ((UIImage) -> Void)?
    private var onMovie: ((URL) -> Void)?

    override init() {
        super.init()
        missing = AVCaptureDevice.default(for: .video) == nil
    }

    func prepare(record: Bool) {
        recordVideo = record
        guard AVCaptureDevice.default(for: .video) != nil else {
            missing = true
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.denied = !granted
                if granted { self.configure() }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func flip() {
        usingFront.toggle()
        configure()
    }

    func takePhoto(_ done: @escaping (UIImage) -> Void) {
        onPhoto = done
        photo.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func toggleRecord(_ done: @escaping (URL) -> Void) {
        if movie.isRecording {
            movie.stopRecording()
            return
        }
        onMovie = done
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(IDs.new()).mov")
        movie.startRecording(to: url, recordingDelegate: self)
        recording = true
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        DispatchQueue.main.async { [weak self] in self?.onPhoto?(image) }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.recording = false
            if error == nil { self?.onMovie?(outputFileURL) }
        }
    }

    private func configure() {
        let front = usingFront
        let record = recordVideo
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            let position: AVCaptureDevice.Position = front ? .front : .back
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video)
            if let device, let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if record {
                if self.session.canAddOutput(self.movie) { self.session.addOutput(self.movie) }
                if let mic = AVCaptureDevice.default(for: .audio),
                   let audio = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(audio) {
                    self.session.addInput(audio)
                }
            } else if self.session.canAddOutput(self.photo) {
                self.session.addOutput(self.photo)
            }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }
}
