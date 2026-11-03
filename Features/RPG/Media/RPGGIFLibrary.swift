import Foundation
import ImageIO
import SpriteKit

/// Decoded GIF frames, already reduced to cell size.
struct RPGGIFFrames: @unchecked Sendable {
    let images: [CGImage]
    let delays: [Double]
    let cost: Int
}

enum RPGGIFDecoder {
    /// Cells are small, so frames are decoded at most this many pixels wide.
    static let maxPixelSize = 160
    static let maxFrames = 120
    /// Per-GIF ceiling on decoded bytes; later frames are dropped beyond it.
    static let maxBytes = 6 * 1024 * 1024

    static func decode(_ url: URL) -> RPGGIFFrames? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source)
    }

    static func decode(_ source: CGImageSource) -> RPGGIFFrames? {
        let count = min(CGImageSourceGetCount(source), maxFrames)
        guard count > 0 else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        var images: [CGImage] = [], delays: [Double] = [], cost = 0
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            let bytes = image.bytesPerRow * image.height
            if cost + bytes > maxBytes { break }
            images.append(image); delays.append(delay(source, index)); cost += bytes
        }
        return images.isEmpty ? nil : RPGGIFFrames(images: images, delays: delays, cost: cost)
    }

    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        return RPGGIFTiming.normalizedDelay(unclamped.flatMap { $0 > 0 ? $0 : nil } ?? clamped)
    }
}

/// Shared, memory-bounded GIF frames keyed by library media ID. Every cell
/// showing the same GIF uses the same textures; decoding runs off the main
/// thread and least-recently-used GIFs are dropped past the byte limit.
@MainActor final class RPGGIFLibrary {
    struct Animation {
        let textures: [SKTexture]
        let delays: [Double]
        let cost: Int
    }
    private var animations: [String: Animation] = [:]
    private var order: [String] = []
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    private(set) var maxCost = 16 * 1024 * 1024
    var cost: Int { animations.values.reduce(0) { $0 + $1.cost } }
    var count: Int { animations.count }

    func animation(_ id: String) -> Animation? {
        guard let value = animations[id] else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return value
    }

    /// Lookup without touching recency; cheap enough to call every frame.
    func peek(_ id: String) -> Animation? { animations[id] }

    func isUnreadable(_ id: String) -> Bool { failed.contains(id) }

    /// Starts decoding if needed; `ready` runs on the main actor when done.
    func request(_ id: String, url: URL, ready: @escaping @MainActor () -> Void) {
        guard animations[id] == nil, !loading.contains(id), !failed.contains(id) else { return }
        loading.insert(id)
        Task { [weak self] in
            let frames = await Task.detached(priority: .utility) { RPGGIFDecoder.decode(url) }.value
            guard let self else { return }
            self.loading.remove(id)
            guard let frames else { self.failed.insert(id); ready(); return }
            let textures = frames.images.map { image -> SKTexture in
                let texture = SKTexture(cgImage: image); texture.filteringMode = .linear; return texture
            }
            self.animations[id] = Animation(textures: textures, delays: frames.delays, cost: frames.cost)
            self.order.removeAll { $0 == id }; self.order.append(id)
            self.trim(); ready()
        }
    }

    func trim(keeping wanted: Set<String> = []) {
        while cost > maxCost, let victim = order.first(where: { !wanted.contains($0) }) ?? order.first {
            order.removeAll { $0 == victim }; animations[victim] = nil
        }
    }

    func lowMemory() { maxCost = 2 * 1024 * 1024; trim() }
    func restoreBudget() { maxCost = 16 * 1024 * 1024 }
    func removeAll() { animations.removeAll(); order.removeAll(); failed.removeAll() }
}
