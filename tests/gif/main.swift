import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// Builds a real GIF with ImageIO and decodes it the way RPG cells do.
// macOS only (ImageIO): swiftc Features/RPG/Media/RPGGIFTiming.swift Features/RPG/Media/RPGGIFLibrary.swift tests/gif/main.swift

var checks = 0
func check(_ condition: Bool, _ name: String) { precondition(condition, name); checks += 1 }

func frame(_ side: Int, red: CGFloat, transparent: Bool) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(transparent ? CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2) : CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()!
}
func gif(delays: [Double], side: Int = 400) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rpg-gif-\(UUID().uuidString).gif")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, delays.count, nil)!
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (index, delay) in delays.enumerated() {
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        CGImageDestinationAddImage(destination, frame(side, red: CGFloat(index) / CGFloat(max(1, delays.count - 1)), transparent: index == 0), properties)
    }
    precondition(CGImageDestinationFinalize(destination), "gif written")
    return url
}

let url = gif(delays: [0.05, 0.2, 0.005])
let frames = RPGGIFDecoder.decode(url)!
check(frames.images.count == 3, "all frames decoded")
check(frames.images.allSatisfy { max($0.width, $0.height) <= RPGGIFDecoder.maxPixelSize }, "frames reduced to cell size")
check(abs(frames.delays[0] - 0.05) < 0.011 && abs(frames.delays[1] - 0.2) < 0.011, "frame delays read")
check(frames.delays[2] == 0.1, "too-fast delay normalised")
let alpha = frames.images[0].alphaInfo
check(alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast, "transparency kept")
check(frames.cost == frames.images.reduce(0) { $0 + $1.bytesPerRow * $1.height }, "cost is decoded bytes")

let long = gif(delays: Array(repeating: 0.04, count: RPGGIFDecoder.maxFrames + 10), side: 64)
check(RPGGIFDecoder.decode(long)!.images.count == RPGGIFDecoder.maxFrames, "frame count capped")

let notGIF = FileManager.default.temporaryDirectory.appendingPathComponent("rpg-gif-bad-\(UUID().uuidString).gif")
try Data("not a gif".utf8).write(to: notGIF)
check(RPGGIFDecoder.decode(notGIF) == nil, "unreadable file rejected")
check(RPGGIFDecoder.decode(FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).gif")) == nil, "missing file rejected")
print("GIF decoding checks passed: \(checks)")
