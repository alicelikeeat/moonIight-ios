import AVFoundation
import Foundation
import ReplayKit

/// In-app ReplayKit capture. This records the app, not the whole device, and needs no broadcast extension.
@MainActor
final class RecorderModel: ObservableObject {
    @Published var recording = false
    private let engine = RecordEngine()

    func toggle(onSaved: @escaping (URL) -> Void, onUnavailable: @escaping () -> Void, onEmpty: @escaping () -> Void) {
        if recording {
            recording = false
            engine.stop { url in
                DispatchQueue.main.async {
                    if let url { onSaved(url) } else { onEmpty() }
                }
            }
            return
        }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable, !recorder.isRecording else {
            onUnavailable()
            return
        }
        engine.start { ok in
            DispatchQueue.main.async {
                if ok {
                    self.recording = true
                } else {
                    self.recording = false
                    onUnavailable()
                }
            }
        }
    }
}

private final class RecordEngine: NSObject {
    private let queue = DispatchQueue(label: "moon.record")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var url: URL?

    func start(done: @escaping (Bool) -> Void) {
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = false
        Paths.ensureDirs()
        let output = Paths.media.appendingPathComponent("rec_\(IDs.new()).mp4")
        queue.async {
            self.url = output
            self.started = false
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
        }
        recorder.startCapture(handler: { [weak self] sample, kind, _ in
            self?.queue.async { self?.append(sample, kind: kind) }
        }, completionHandler: { error in
            done(error == nil)
        })
    }

    func stop(done: @escaping (URL?) -> Void) {
        RPScreenRecorder.shared().stopCapture { [weak self] _ in
            self?.queue.async {
                guard let self else { done(nil); return }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                guard let writer = self.writer, self.started else { done(nil); return }
                let url = self.url
                writer.finishWriting {
                    done(writer.status == .completed ? url : nil)
                }
            }
        }
    }

    private func append(_ sample: CMSampleBuffer, kind: RPSampleBufferType) {
        guard CMSampleBufferDataIsReady(sample) else { return }
        if writer == nil { openWriter(for: sample, kind: kind) }
        guard let writer, started else { return }
        switch kind {
        case .video:
            if videoInput?.isReadyForMoreMediaData == true { videoInput?.append(sample) }
        case .audioApp:
            if audioInput?.isReadyForMoreMediaData == true { audioInput?.append(sample) }
        default:
            break
        }
    }

    private func openWriter(for sample: CMSampleBuffer, kind: RPSampleBufferType) {
        guard kind == .video, let url else { return }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(sample))
            video.expectsMediaDataInRealTime = true
            if writer.canAdd(video) { writer.add(video) }
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings())
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) { writer.add(audio) }
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
            self.writer = writer
            self.videoInput = video
            self.audioInput = audio
            self.started = true
        } catch {
            writer = nil
        }
    }

    private func videoSettings(_ sample: CMSampleBuffer) -> [String: Any] {
        var width = 720
        var height = 1280
        if let format = CMSampleBufferGetFormatDescription(sample) {
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            if dims.width > 0 && dims.height > 0 {
                width = Int(dims.width)
                height = Int(dims.height)
            }
        }
        return [
            AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
    }

    private func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000,
        ]
    }
}
