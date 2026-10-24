import AVFoundation
import Combine
import CoreVideo
import Network
import SwiftUI
import UIKit

/// One playback surface. Tap rules live in PlayToggle so ended / buffering / suppressed all resume.
final class PlayerSession: NSObject, ObservableObject, Playable {
    let player = AVPlayer()
    @Published private(set) var playWhenReady = false
    @Published private(set) var playbackState = PlayToggle.idle
    @Published private(set) var suppressed = false
    @Published private(set) var hasMedia = false
    @Published var isMuted = false
    @Published var speed: Float = 1
    @Published var loop = false
    @Published var naturalSize: CGSize = .zero
    @Published var errorText: String?
    @Published private(set) var generation = 0

    private var endedFlag = false
    private var resumeAfterBackground = false
    private var statusObs: NSKeyValueObservation?
    private var itemObs: NSKeyValueObservation?
    private var sizeObs: NSKeyValueObservation?

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        statusObs = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            DispatchQueue.main.async { self?.apply(status) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(itemEnded(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(self, selector: #selector(pauseFromBackground), name: .moonPauseAll, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var showsPlaying: Bool { PlayToggle.showsPlaying(self) }
    var hasError: Bool { errorText != nil }

    func load(url: URL?, autoplay: Bool, muted: Bool, rate: Float = 1) {
        errorText = nil
        endedFlag = false
        naturalSize = .zero
        isMuted = muted
        speed = rate
        player.isMuted = muted
        guard let url else {
            player.replaceCurrentItem(with: nil)
            hasMedia = false
            playbackState = PlayToggle.idle
            playWhenReady = false
            generation += 1
            return
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        hasMedia = true
        playbackState = PlayToggle.idle
        generation += 1
        itemObs = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            DispatchQueue.main.async {
                if failed { self?.errorText = message ?? "无法播放" }
            }
        }
        sizeObs = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            DispatchQueue.main.async {
                if size.width > 0 { self?.naturalSize = size }
            }
        }
        if autoplay { PlayToggle.resume(self) } else { pause() }
    }

    func play() {
        playWhenReady = true
        suppressed = false
        endedFlag = false
        player.isMuted = isMuted
        configureAudio()
        player.playImmediately(atRate: max(0.1, speed))
        generation += 1
    }

    func pause() {
        playWhenReady = false
        player.pause()
        generation += 1
    }

    func prepare() {
        if hasMedia && playbackState == PlayToggle.idle {
            playbackState = PlayToggle.buffering
        }
    }

    func seekToStart() {
        endedFlag = false
        playbackState = PlayToggle.ready
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pauseForBackground() {
        let playing = playWhenReady || player.timeControlStatus == .playing
        resumeAfterBackground = playing
        if playing { pause() }
    }

    /// Continues a clip that was paused only because the app left the foreground.
    func resumeAfterForeground() {
        guard resumeAfterBackground else { return }
        resumeAfterBackground = false
        play()
    }

    func toggle() { PlayToggle.toggle(self) }

    private func apply(_ status: AVPlayer.TimeControlStatus) {
        if endedFlag { playbackState = PlayToggle.ended; return }
        switch status {
        case .playing:
            playbackState = PlayToggle.ready
            suppressed = false
        case .waitingToPlayAtSpecifiedRate:
            playbackState = PlayToggle.buffering
        case .paused:
            playbackState = hasMedia ? PlayToggle.ready : PlayToggle.idle
        @unknown default:
            break
        }
        generation += 1
    }

    @objc private func itemEnded(_ note: Notification) {
        let item = note.object as? AVPlayerItem
        DispatchQueue.main.async { [weak self] in
            guard let self, item == self.player.currentItem else { return }
            if self.loop && self.playWhenReady {
                self.seekToStart()
                self.play()
                return
            }
            self.endedFlag = true
            self.playbackState = PlayToggle.ended
            self.generation += 1
        }
    }

    @objc private func interrupted(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let began = type == .began
        DispatchQueue.main.async { [weak self] in
            self?.suppressed = began
            self?.generation += 1
        }
    }

    @objc private func pauseFromBackground() {
        DispatchQueue.main.async { [weak self] in self?.pauseForBackground() }
    }

    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        if isMuted {
            try? session.setCategory(.ambient, mode: .moviePlayback, options: [.mixWithOthers])
        } else {
            try? session.setCategory(.playback, mode: .moviePlayback)
        }
        try? session.setActive(true)
    }
}

struct PlayerLayerView: UIViewRepresentable {
    var player: AVPlayer
    var gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerHost {
        let view = PlayerHost()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerHost, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = gravity
    }
}

final class PlayerHost: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

enum Gravity {
    static func choose(mode: VideoDisplay, video: CGSize, view: CGSize, override: Bool?) -> AVLayerVideoGravity {
        let fill = VideoFit.fill(
            mode: mode,
            videoW: Float(video.width),
            videoH: Float(video.height),
            viewW: Float(view.width),
            viewH: Float(view.height),
            override: override
        )
        return fill ? .resizeAspectFill : .resizeAspect
    }
}

/// Watches whether the current path is cellular. Unknown until the first callback, which does not block autoplay.
final class LinkMonitor {
    static let shared = LinkMonitor()
    private let monitor = NWPathMonitor()
    private(set) var expensive = false
    private(set) var known = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            DispatchQueue.main.async {
                self?.expensive = expensive
                self?.known = true
            }
        }
        monitor.start(queue: DispatchQueue(label: "moon.link"))
    }
}

/// A one-second silent clip so the immersive UI test can autoplay without a network asset.
enum TinyClip {
    static func write(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 10
        for i in 0..<12 {
            let deadline = Date().addingTimeInterval(1.5)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard input.isReadyForMoreMediaData else { break }
            var buffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            }
            if buffer == nil {
                let options: [String: Any] = [
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ]
                CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, options as CFDictionary, &buffer)
            }
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytes = CVPixelBufferGetDataSize(buffer)
                memset(base, 0, bytes)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(i), timescale: fps)
            if !adaptor.append(buffer, withPresentationTime: time) { break }
        }
        input.markAsFinished()
        let wait = DispatchSemaphore(value: 0)
        writer.finishWriting { wait.signal() }
        wait.wait()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}
