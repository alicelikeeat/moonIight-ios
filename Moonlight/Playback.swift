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
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentSeconds: Double = 0

    private var endedFlag = false
    private var resumeAfterBackground = false
    private var cueSeconds: Double?
    private var tick: Any?
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
        tick = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            self.currentSeconds = seconds.isFinite ? seconds : 0
            let duration = self.player.currentItem?.duration.seconds ?? 0
            let total = duration.isFinite ? duration : 0
            self.progress = total > 0 ? min(1, max(0, self.currentSeconds / total)) : 0
        }
    }

    deinit {
        if let tick { player.removeTimeObserver(tick) }
        NotificationCenter.default.removeObserver(self)
    }

    var showsPlaying: Bool { PlayToggle.showsPlaying(self) }
    var hasError: Bool { errorText != nil }

    func load(url: URL?, autoplay: Bool, muted: Bool, rate: Float = 1) {
        errorText = nil
        endedFlag = false
        cueSeconds = nil
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
        player.actionAtItemEnd = loop ? .none : .pause
        player.replaceCurrentItem(with: item)
        hasMedia = true
        playbackState = PlayToggle.idle
        generation += 1
        itemObs = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            DispatchQueue.main.async {
                guard let self, item === self.player.currentItem else { return }
                if failed {
                    self.errorText = message ?? "无法播放"
                    self.generation += 1
                    return
                }
                if item.status == .readyToPlay { self.applyCue() }
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

    /// Restores a remembered playback time once the item is ready.
    func cue(_ seconds: Double) {
        guard seconds > 0.25 else { return }
        cueSeconds = seconds
        applyCue()
    }

    private func applyCue() {
        guard let cueSeconds, player.currentItem?.status == .readyToPlay else { return }
        let target = cueSeconds
        self.cueSeconds = nil
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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
                self.endedFlag = false
                let current = self.player.currentItem
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    DispatchQueue.main.async {
                        guard let self, finished, self.loop, self.playWhenReady, self.player.currentItem === current else { return }
                        self.play()
                    }
                }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

/// One still from a video, for previews. It does not keep a player running.
struct VideoPoster: View {
    var path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.black
            }
        }
        .task(id: path) {
            image = await Self.frame(path: path)
        }
    }

    static func frame(path: String) async -> UIImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let time = NSValue(time: CMTime(seconds: 0.05, preferredTimescale: 600))
        return await withCheckedContinuation { continuation in
            var resumed = false
            gen.generateCGImagesAsynchronously(forTimes: [time]) { _, cg, _, result, _ in
                guard !resumed else { return }
                switch result {
                case .succeeded, .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: cg.map { UIImage(cgImage: $0) })
                default:
                    break
                }
            }
        }
    }
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

/// A silent clip long enough for the immersive UI test to hide, reveal, and hide again.
enum TinyClip {
    /// The UI test needs the picture to keep playing for well over 15 seconds.
    static let seconds: Int32 = 36

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
        var written: Int32 = 0
        for i in 0..<seconds {
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
            let time = CMTime(value: CMTimeValue(i), timescale: 1)
            if !adaptor.append(buffer, withPresentationTime: time) { break }
            written += 1
        }
        guard written == seconds else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileWriteUnknown)
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
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
