import CoreGraphics
import Foundation

/// Pure motion curves for 长按动画. Progress is linear 0…1; the resting pose is always full size.
enum RingMotion {
    static let starLand: Float = 0.72
    static let starSweep: Float = 400
    static let starSpin: Float = 540
    static let starOvershoot: Float = 1.16
    static let starFlightMs: Int64 = 900

    struct Pose: Equatable {
        var rf: Float = 1
        var ang: Float = 0
        var lift: Float = 0
        var sink: Float = 0
        var scale: Float = 1
        var alpha: Float = 1
        var label: Float = 1
        var fx: Float = 0
        var fx2: Float = 0
        var rot: Float = 0
        var fx3: Float = 0
        var isRest: Bool {
            rf == 1 && ang == 0 && lift == 0 && sink == 0 && scale == 1 && alpha == 1 && label == 1 && rot == 0
        }
    }

    static func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }

    static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = clamp01((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }

    static func easeOutCubic(_ x: Float) -> Float {
        let t = 1 - clamp01(x)
        return 1 - t * t * t
    }

    static func backOut(_ x: Float, _ s: Float = 1.2) -> Float {
        let t = clamp01(x) - 1
        return 1 + (s + 1) * t * t * t + s * t * t
    }

    static func fpow(_ a: Float, _ b: Float) -> Float {
        Float(Foundation.pow(Double(a), Double(b)))
    }

    static func starStaggerMs(_ n: Int) -> Int64 {
        if n <= 1 { return 0 }
        return min(70, 240 / Int64(n - 1))
    }

    /// 0 high in the sky … 1 in the slot. Drifts, then accelerates.
    static func starTravel(_ o: Float) -> Float {
        let x = clamp01(o / starLand)
        return 0.15 * x + 0.85 * fpow(x, 2.2)
    }

    /// Normalised speed along the fall. Zero after touchdown.
    static func starSpeed(_ o: Float) -> Float {
        if o >= starLand { return 0 }
        let x = clamp01(o / starLand)
        return (0.15 + 1.87 * fpow(x, 1.2)) / 2.02
    }

    static func starScale(_ o: Float) -> Float {
        if o < starLand {
            return 0.06 + (starOvershoot - 0.06) * fpow(starTravel(o), 0.9)
        }
        return starOvershoot - (starOvershoot - 1) * smooth(0, 1, (o - starLand) / (1 - starLand))
    }

    static func starLanding(_ o: Float) -> Float {
        if o <= starLand { return 0 }
        return clamp01((o - starLand) / (1 - starLand))
    }

    /// Parallax 0.8…1.2. Far buttons start smaller, dimmer, and higher. The resting pose ignores this.
    static func starDepth(_ i: Int) -> Float {
        let h = sin(Float(i) * 91.7 + 3.1) * 43758.547
        return 0.8 + 0.4 * (h - floor(h))
    }

    static func clampSpeed(_ v: Float) -> Float { min(2, max(0.5, v)) }

    static func lotusInner(_ b: Float) -> Float { unfurl(clamp01(b / 0.70)) }
    static func lotusOuter(_ b: Float) -> Float { unfurl(clamp01((b - 0.25) / 0.75)) }
    static func unfurl(_ x: Float) -> Float {
        let t = clamp01(x)
        return t * t * (3 - 2 * t) + 0.9 * t * t * (1 - t)
    }
    static func lotusReveal(_ b: Float) -> Float { smooth(0.34, 0.86, b) }
    static func lotusSpread(_ b: Float) -> Float { easeOutCubic(clamp01(b / 0.5)) }
    static func moonDark(_ scene: Float) -> Float { easeOutCubic(clamp01(scene * 1.8)) }
    static func moonGlow(_ scene: Float) -> Float { smooth(0.25, 1, scene) }

    static func pose(_ style: RingAnim, _ o0: Float, _ cl0: Float, _ closing: Bool, depth: Float = 1) -> Pose {
        let o = style == .spin ? min(1.25, max(0, o0)) : clamp01(o0)
        let cl: Float = closing ? clamp01(cl0) : 1
        var out = Pose()
        switch style {
        case .spin:
            // Bubbles rise into their slots. A short spring overshoot, then full size — not a long spin.
            if closing {
                let t = cl
                out.rf = 0.36 + 0.64 * t
                out.ang = -12 * (1 - t)
                out.sink = (1 - t) * (1 - t) * 0.85
                out.scale = 0.12 + 0.88 * t
                out.alpha = t
                out.label = t * t
            } else {
                let s = backOut(clamp01(o), 1.65)
                out.rf = 0.36 + 0.64 * s
                out.ang = -12 * (1 - min(1, s))
                out.sink = max(0, 1 - s) * 0.85
                out.scale = 0.12 + 0.88 * s
                out.alpha = clamp01(s * 1.15)
                out.label = clamp01(s) * clamp01(s)
            }
        case .lotus:
            let b: Float = closing ? cl : o
            out.rf = closing ? 1 : lotusSpread(b)
            out.sink = closing ? (1 - cl) * (1 - cl) : 0
            let rv = lotusReveal(b)
            out.scale = 0.42 + 0.58 * backOut(rv, 1.5)
            out.alpha = rv
            out.label = rv * rv
            out.fx = b
            out.fx2 = closing ? smooth(0, 0.6, cl) : 1
        case .star:
            if !closing {
                let u = starTravel(o)
                let land = starLanding(o)
                starOrbit(u, &out)
                if land > 0 {
                    out.rf = 1 - 0.07 * sin(land * Float.pi) * (1 - land)
                    out.rot = -14 * sin(land * Float.pi * 1.5) * (1 - land)
                } else {
                    out.rot = starSpin * fpow(1 - u, 1.5)
                }
                let near = clamp01(u)
                let depthMix = clamp01((depth - 0.8) / 0.4)
                out.scale = starScale(o) * (depth + (1 - depth) * near)
                out.lift *= (1.15 - 0.15 * depth)
                out.alpha = smooth(0, 0.10, o) * (0.55 + 0.45 * depthMix + (0.45 - 0.45 * depthMix) * near)
                out.label = smooth(0.80, 1, o)
                out.fx = smooth(0, 0.06, o) * (0.35 + 0.65 * starSpeed(o)) * (1 - smooth(0.92, 1, u))
                out.fx2 = land
                out.fx3 = land < 0.3 ? 0 : sin(clamp01((land - 0.3) / 0.7) * Float.pi)
            } else {
                let r = (1 - cl) * (1 - cl)
                starOrbit(1 - r, &out)
                out.rot = -starSpin * fpow(r, 1.2)
                out.scale = 0.06 + 0.94 * (1 - r) * (depth + (1 - depth) * (1 - r))
                out.alpha = smooth(0, 0.35, cl)
                out.label = cl * cl * cl
                out.fx = (1 - cl) * smooth(0, 0.3, cl)
            }
        case .moon:
            let lit = o * cl
            out.scale = 0.94 + 0.06 * easeOutCubic(lit)
            out.alpha = (0.14 + 0.86 * lit) * cl
            out.label = lit
            out.fx = lit
        case .fade:
            let t = o * cl
            out.scale = 1
            out.alpha = t
            out.label = t
        }
        if !closing && o0 >= 1 && (style != .spin || o0 == 1) {
            out.rf = 1
            out.ang = 0
            out.lift = 0
            out.sink = 0
            out.scale = 1
            out.alpha = 1
            out.label = 1
            out.rot = 0
            out.fx3 = 0
            if style == .star { out.fx2 = 0 }
        }
        return out
    }

    static func starOrbit(_ u: Float, _ out: inout Pose) {
        let r = 1 - clamp01(u)
        out.rf = 1 + 0.9 * fpow(r, 1.1)
        out.ang = starSweep * fpow(r, 1.15)
        out.lift = fpow(r, 2.6)
    }

    static let spinFlightMs: Int64 = 248
    static let spinStaggerMs: Int64 = 20

    static func openMs(_ style: RingAnim, _ n: Int, _ starSpeed: Float = 1) -> Int64 {
        switch style {
        case .spin:
            let rate = clampSpeed(starSpeed)
            let span = spinFlightMs + spinStaggerMs * Int64(max(0, n - 1))
            return Int64(Double(span) / Double(rate))
        case .lotus: return 520 + 38 * Int64(n)
        case .star:
            let rate = clampSpeed(starSpeed)
            let span = starFlightMs + starStaggerMs(n) * Int64(max(0, n - 1))
            return Int64(Double(span) / Double(rate))
        case .moon: return 150 + 360 + 60 * Int64(n)
        case .fade: return 150
        }
    }

    static func settleDeadlineMs(_ style: RingAnim, _ n: Int, _ animatorScale: Float, _ starSpeed: Float = 1) -> Int64 {
        let scale = min(10, max(0, animatorScale))
        let base = Float(openMs(style, n, starSpeed) + 250) * scale
        return Int64(base) + 120
    }
}

enum PlayToggle {
    static let idle = 1
    static let buffering = 2
    static let ready = 3
    static let ended = 4

    static func showsPlaying(_ p: Playable) -> Bool {
        p.playWhenReady && !p.suppressed && (p.playbackState == ready || p.playbackState == buffering)
    }

    @discardableResult
    static func toggle(_ p: Playable) -> Bool {
        if showsPlaying(p) {
            p.pause()
            return false
        }
        resume(p)
        return true
    }

    static func resume(_ p: Playable) {
        switch p.playbackState {
        case idle:
            if p.hasMedia { p.prepare() }
        case ended:
            p.seekToStart()
        default:
            break
        }
        if p.playWhenReady && p.suppressed { p.pause() }
        p.play()
    }
}

protocol Playable: AnyObject {
    var playWhenReady: Bool { get }
    var playbackState: Int { get }
    var suppressed: Bool { get }
    var hasMedia: Bool { get }
    func play()
    func pause()
    func prepare()
    func seekToStart()
}

enum FeedTap { case togglePlay, toggleChrome, revealChrome }

enum FeedTapRule {
    /// A hidden feed reveals its buttons on the single tap. A visible video still toggles play.
    /// Double-tap like stays on its own recognizer; this only classifies the delayed single tap.
    static func onTap(isVideo: Bool, active: Bool, hasError: Bool = false, chromeVisible: Bool = true, autoHide: Bool = false) -> FeedTap {
        if isVideo && active && !hasError {
            if autoHide && !chromeVisible { return .revealChrome }
            return .togglePlay
        }
        return .toggleChrome
    }
}

enum ChromeTiming {
    static let presets: [Float] = [1, 2, 3, 5, 10]

    static func clamp(_ seconds: Float) -> Float {
        min(30, max(0.5, seconds))
    }

    static func seconds(_ value: Float) -> TimeInterval {
        TimeInterval(clamp(value))
    }

    static func shouldHide(autoHide: Bool, playing: Bool, quiet: TimeInterval, limit: TimeInterval) -> Bool {
        autoHide && playing && quiet >= limit
    }
}

/// Home-feed autoplay gate. The feed itself uses one shared player and pauses off-screen.
enum FeedAutoplay {
    static func allowed(wifiOnly: Bool, pauseOnLowPower: Bool, expensive: Bool, lowPower: Bool, pathKnown: Bool) -> Bool {
        if pauseOnLowPower && lowPower { return false }
        if wifiOnly && pathKnown && expensive { return false }
        return true
    }

    static func allowedNow(_ settings: AppSettings) -> Bool {
        allowed(
            wifiOnly: settings.autoplayWifiOnly,
            pauseOnLowPower: settings.pauseOnLowPower,
            expensive: LinkMonitor.shared.expensive,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            pathKnown: LinkMonitor.shared.known
        )
    }
}

enum MediaInfo {
    static func tags(_ e: MediaEntry) -> [String] {
        var out: [String] = []
        switch e.kind {
        case .video: out.append("视频")
        case .image: out.append("图片")
        case .embed: out.append("在线播放")
        }
        out.append(e.localPath != nil ? "本地" : "在线")
        if let p = e.platform, !p.isEmpty, p != "local" { out.append(e.platformLabel()) }
        if e.favorite { out.append("已收藏") }
        if e.hidden { out.append("已隐藏") }
        if e.source == "camera" { out.append("拍摄") }
        return out
    }
}

enum FeedNav {
    static func nextSameSource(_ sources: [String], _ from: Int) -> Int? {
        guard sources.indices.contains(from) else { return nil }
        let src = sources[from]
        let n = sources.count
        if n <= 1 { return nil }
        for k in 1..<n {
            let i = (from + k) % n
            if sources[i] == src { return i }
        }
        return nil
    }
}

enum VideoFit {
    static let smartMaxCrop: Float = 0.08

    static func cropFraction(videoW: Float, videoH: Float, viewW: Float, viewH: Float) -> Float {
        if videoW <= 0 || videoH <= 0 || viewW <= 0 || viewH <= 0 { return 1 }
        let va = videoW / videoH
        let sa = viewW / viewH
        return 1 - min(va, sa) / max(va, sa)
    }

    static func fill(mode: VideoDisplay, videoW: Float, videoH: Float, viewW: Float, viewH: Float, override: Bool? = nil) -> Bool {
        if let override { return override }
        switch mode {
        case .fit: return false
        case .fill: return true
        case .smart: return cropFraction(videoW: videoW, videoH: videoH, viewW: viewW, viewH: viewH) <= smartMaxCrop
        }
    }

    static func of(_ name: String?) -> VideoDisplay {
        guard let name, let v = VideoDisplay(rawValue: name) else { return .smart }
        return v
    }
}

struct RadialResult: Equatable {
    var centerX: Double
    var centerY: Double
    var angles: [Double]
    var radius: Double
    var dir: Double

    func pos(_ i: Int, r: Double? = nil, extraDeg: Double = 0) -> (Double, Double) {
        let rad = (angles[i] + extraDeg) * .pi / 180
        let radius = r ?? self.radius
        return (centerX + radius * cos(rad), centerY + radius * sin(rad))
    }
}

enum RadialGeometry {
    static func stepDeg(_ n: Int) -> Double {
        switch n {
        case ...1: return 0
        case 2: return 56
        case 3, 4: return 110.0 / Double(n - 1)
        case 5: return 44
        case 6: return 40
        case 7: return 37
        default: return 35
        }
    }

    static func subArc(parentDeg: Double, k: Int, r: Double, chipGap: Double) -> [Double] {
        if k <= 0 || r <= 0 { return [] }
        let step = (chipGap / r) * 180 / .pi
        return (0..<k).map { j in parentDeg + (Double(j) - Double(k - 1) / 2) * step }
    }

    static func layout(originX: Double, originY: Double, n: Int, left: Double, top: Double, right: Double, bottom: Double, radius: Double, itemR: Double) -> RadialResult {
        let step = stepDeg(n)
        let span = step * Double(max(0, n - 1))
        func angles(for dir: Double) -> [Double] {
            (0..<n).map { i in dir - span / 2 + step * Double(i) }
        }
        func overflow(cx: Double, cy: Double, dir: Double) -> Double {
            angles(for: dir).reduce(0) { acc, a in
                let (x, y) = (cx + radius * cos(a * .pi / 180), cy + radius * sin(a * .pi / 180))
                return acc
                    + max(0, left + itemR - x)
                    + max(0, x - (right - itemR))
                    + max(0, top + itemR - y)
                    + max(0, y - (bottom - itemR))
            }
        }
        let scx = (left + right) / 2
        let scy = (top + bottom) / 2
        let dx = scx - originX
        let dy = scy - originY
        let width = right - left
        let preferred = hypot(dx, dy) < width * 0.12 ? -90.0 : atan2(dy, dx) * 180 / .pi
        var best = preferred
        var bestO = overflow(cx: originX, cy: originY, dir: preferred)
        if bestO > 0 {
            for k in 1...36 {
                for sgn in [1.0, -1.0] {
                    let d = preferred + sgn * Double(k) * 5
                    let o = overflow(cx: originX, cy: originY, dir: d)
                    if o < bestO - 0.5 { bestO = o; best = d }
                }
            }
        }
        var cx = originX
        var cy = originY
        if bestO > 0.5 {
            let m = radius + itemR
            cx = min(max(originX, left + m), right - m)
            cy = min(max(originY, top + m), bottom - m)
            let ddx = scx - cx
            let ddy = scy - cy
            best = hypot(ddx, ddy) < 1 ? -90 : atan2(ddy, ddx) * 180 / .pi
        }
        return RadialResult(centerX: cx, centerY: cy, angles: angles(for: best), radius: radius, dir: best)
    }

    static func hit(_ r: RadialResult, x: Double, y: Double, hitR: Double) -> Int? {
        var best: Int?
        var bestD = Double.greatestFiniteMagnitude
        for i in r.angles.indices {
            let (px, py) = r.pos(i)
            let d = hypot(px - x, py - y)
            if d < hitR && d < bestD { bestD = d; best = i }
        }
        return best
    }
}

enum DownloadPolicy {
    static let streamHosts = ["bili", "youtube", "vimeo", "dailymotion", "twitch"]

    static func isStreamURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains(".m3u8") || lower.contains(".mpd")
    }

    /// Direct file links only. Official embeds and HLS/DASH are not downloadable.
    static func canDownload(_ e: MediaEntry) -> (ok: Bool, reason: String?) {
        if e.localPath != nil { return (true, nil) }
        let platform = e.resolvedPlatform
        if platform == PlatformID.youtube {
            return (false, "YouTube 只能用官方播放器，不能下载")
        }
        if platform == PlatformID.bili {
            return (false, "哔哩哔哩只能用官方播放器，不能下载")
        }
        if platform == PlatformID.peertube {
            if let file = e.downloadURL, !file.isEmpty, !isStreamURL(file) { return (true, nil) }
            return (false, "这个实例没有开放下载")
        }
        if streamHosts.contains(platform) || e.kind == .embed {
            return (false, "只有网页播放器，不能下载")
        }
        guard let url = e.remoteURL, !url.isEmpty else { return (false, "没有文件地址") }
        if isStreamURL(url) { return (false, "流媒体不能下载") }
        switch platform {
        case PlatformID.archive, PlatformID.nasa, PlatformID.commons, PlatformID.pexels, PlatformID.pixabay, PlatformID.peertube, PlatformID.url, PlatformID.web, PlatformID.local:
            return (true, nil)
        default:
            if e.kind == .video || e.kind == .image { return (true, nil) }
            return (false, "只有网页播放器，不能下载")
        }
    }
}

enum EmbedLinks {
    /// Official player pages only. This app never calls Bilibili playurl / WBI.
    static func youtube(_ id: String, mute: Bool) -> String {
        let m = mute ? "1" : "0"
        return "https://www.youtube.com/embed/\(id)?autoplay=1&playsinline=1&mute=\(m)&rel=0&modestbranding=1&enablejsapi=1&origin=https%3A%2F%2Fcom.moonlight.feed"
    }
    static func vimeo(_ id: String, mute: Bool) -> String {
        "https://player.vimeo.com/video/\(id)?autoplay=1&muted=\(mute ? "1" : "0")"
    }
    static func dailymotion(_ id: String, mute: Bool) -> String {
        "https://www.dailymotion.com/embed/video/\(id)?autoplay=1&mute=\(mute ? "true" : "false")"
    }
    static func bili(_ bvid: String, mute: Bool) -> String {
        "https://player.bilibili.com/player.html?bvid=\(bvid)&page=1&high_quality=1&autoplay=1&danmaku=0&mute=\(mute ? "1" : "0")"
    }
}

/// How close a ring button is to the finger. 1 is touching, 0 is outside the falloff.
enum BubbleMotion {
    static let falloff: Float = 156
    static let selectInfluence: Float = 0.42

    static func influence(distance: Float, radius: Float = falloff) -> Float {
        guard radius > 0 else { return 0 }
        let t = RingMotion.clamp01(1 - distance / radius)
        return t * t * (3 - 2 * t)
    }

    /// 1 at rest, 1.25 when the droplet is on the button.
    static func scaleBoost(_ influence: Float) -> Float {
        1 + 0.25 * RingMotion.clamp01(influence)
    }

    static func highlight(_ influence: Float) -> Float {
        let t = RingMotion.clamp01(influence)
        return t * t
    }

    /// Toward the finger, plus a little extra lift so the button floats up.
    static func offset(from button: CGPoint, to finger: CGPoint, influence: Float) -> CGSize {
        let dx = Float(finger.x - button.x)
        let dy = Float(finger.y - button.y)
        let len = max(1, hypot(dx, dy))
        let pull = 16 * influence
        let lift = 12 * influence
        return CGSize(width: CGFloat(dx / len * pull), height: CGFloat(dy / len * pull - lift))
    }

    static func wobbleDegrees(influence: Float, time: Float, index: Int) -> Float {
        let phase = time * 9 + Float(index) * 1.3
        return sin(phase) * 3.4 * influence * influence
    }

    static func bob(influence: Float, time: Float, index: Int) -> CGFloat {
        CGFloat(sin(time * 9 + Float(index) * 0.7) * 2.5 * influence * influence)
    }
}

/// Smooths the droplet and each button's lift. One step per frame; never snaps to the new target.
final class BubbleField {
    private(set) var finger = CGPoint.zero
    private var inf: [Int: Float] = [:]
    private var ready = false
    private var last = 0.0
    private(set) var nearest: Int?
    private(set) var lastCenters: [CGPoint] = []
    var onNearest: ((Int) -> Void)?

    func influence(_ index: Int) -> Float { inf[index] ?? 0 }
    var live: Bool { inf.values.contains { $0 > 0.02 } }

    func reset() {
        ready = false
        inf.removeAll()
        nearest = nil
        lastCenters = []
        finger = .zero
    }

    func step(target: CGPoint, centers: [CGPoint], now: TimeInterval, tracking: Bool, force: Bool = false) {
        let dt: Float
        if !ready {
            finger = target
            ready = true
            last = now
            dt = 1 / 60
        } else {
            let raw = now - last
            if !force && raw < 0.0005 { return }
            dt = Float(min(0.05, max(1 / 120, raw)))
            last = now
        }
        if tracking {
            let blend = CGFloat(1 - exp(-dt * 16))
            finger.x += (target.x - finger.x) * blend
            finger.y += (target.y - finger.y) * blend
        }
        lastCenters = centers
        let blend = 1 - exp(-dt * 18)
        var best: Int?
        var bestValue: Float = -1
        var seen = Set<Int>()
        for i in centers.indices {
            seen.insert(i)
            let c = centers[i]
            let dist = hypot(Float(c.x - finger.x), Float(c.y - finger.y))
            let goal: Float = tracking ? BubbleMotion.influence(distance: dist) : 0
            let next = (inf[i] ?? 0) + (goal - (inf[i] ?? 0)) * blend
            inf[i] = next
            if tracking, next > bestValue {
                bestValue = next
                best = i
            }
        }
        for key in Array(inf.keys) where !seen.contains(key) {
            inf[key] = (inf[key] ?? 0) * (1 - blend)
        }
        let pick = (tracking && bestValue >= BubbleMotion.selectInfluence) ? best : nil
        if pick != nearest {
            nearest = pick
            if let pick { onNearest?(pick) }
        }
    }
}

enum DropDecision: Equatable {
    case fire(Int)
    case cancel
    case stay
}

enum DropAim {
    static let moveThreshold: Double = 18

    /// A destructive hit only fires when the action already has undo. Empty space cancels after a real drag.
    static func decide(hit: Int?, destructive: Bool, hasUndo: Bool, moved: Double) -> DropDecision {
        if let hit {
            if destructive && !hasUndo { return .stay }
            return .fire(hit)
        }
        return moved >= moveThreshold ? .cancel : .stay
    }
}

enum PinchRule {
    /// Fingers apart fills this item. Fingers together restores the global 视频显示 setting.
    static func override(scale: CGFloat, current: Bool?) -> Bool? {
        if scale >= 1.12 { return true }
        if scale <= 0.88 { return nil }
        return current
    }
}

enum SwipeInfo {
    static func opensInfo(translationX: CGFloat, translationY: CGFloat) -> Bool {
        translationX <= -48 && abs(translationX) > abs(translationY) * 1.35
    }
}
