import Foundation

/// Frame timing for animated GIF cells. Pure so it can be tested anywhere.
enum RPGGIFTiming {
    /// Browsers treat delays under 11 ms as 100 ms; match that so fast-flagged
    /// GIFs do not spin at the display rate.
    static func normalizedDelay(_ seconds: Double?) -> Double {
        guard let seconds, seconds.isFinite, seconds >= 0.011 else { return 0.1 }
        return min(seconds, 10)
    }

    /// The frame to show `elapsed` seconds after playback started. Without
    /// looping the last frame is held once the animation ends.
    static func frameIndex(elapsed: Double, delays: [Double], loop: Bool) -> Int {
        guard !delays.isEmpty else { return 0 }
        let total = delays.reduce(0, +)
        guard total > 0, elapsed.isFinite, elapsed > 0 else { return 0 }
        if !loop && elapsed >= total { return delays.count - 1 }
        var remaining = elapsed.truncatingRemainder(dividingBy: total)
        for (index, delay) in delays.enumerated() {
            if remaining < delay { return index }
            remaining -= delay
        }
        return delays.count - 1
    }

    /// Seconds from the start to the beginning of `index`, used to resume a
    /// paused animation from the frame it stopped on.
    static func offset(of index: Int, delays: [Double]) -> Double {
        delays.prefix(max(0, min(index, delays.count))).reduce(0, +)
    }
}
