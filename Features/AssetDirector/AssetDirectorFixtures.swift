#if DEBUG
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// DEBUG only: synthetic test assets for the Asset Director UI test (the
/// 月光水晶城 scenario). They are drawn by code, not real photos, so they
/// test the pipeline end to end, not classification accuracy (the starter
/// pack evaluation measures that on real CC0 files).
enum AssetDirectorFixtures {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("AssetDirectorFixtures", isDirectory: true) }

    static func write() -> [URL] {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        if let u = png("castle-reference.png", side: 512, draw: castle) { urls.append(u) }
        if let u = png("glass-material.png", side: 256, draw: glassTile) { urls.append(u) }
        if let u = fountainVideo() { urls.append(u) }
        urls.append(obj("house-model.obj", house()))
        urls.append(obj("person-model.obj", person()))
        return urls
    }

    // MARK: Pictures

    private static func png(_ name: String, side: Int, draw: (CGContext, CGFloat) -> Void) -> URL? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx, CGFloat(side))
        guard let image = ctx.makeImage() else { return nil }
        let url = folder.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    /// Sky, hills and a white castle with blue spires.
    private static func castle(_ c: CGContext, _ s: CGFloat) {
        for y in 0..<Int(s) {
            let t = CGFloat(y) / s
            c.setFillColor(red: 0.55 + 0.35 * t, green: 0.72 + 0.2 * t, blue: 0.95, alpha: 1)
            c.fill(CGRect(x: 0, y: CGFloat(y), width: s, height: 1))
        }
        c.setFillColor(red: 0.35, green: 0.6, blue: 0.35, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.25))
        c.setFillColor(red: 0.94, green: 0.93, blue: 0.9, alpha: 1)
        c.fill(CGRect(x: s * 0.2, y: s * 0.25, width: s * 0.6, height: s * 0.3))
        for x in [0.18, 0.44, 0.7] { c.fill(CGRect(x: s * CGFloat(x), y: s * 0.25, width: s * 0.12, height: s * 0.45)) }
        c.setFillColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 1)
        for x in [0.18, 0.44, 0.7] {
            c.move(to: CGPoint(x: s * CGFloat(x) - 6, y: s * 0.7)); c.addLine(to: CGPoint(x: s * CGFloat(x + 0.06), y: s * 0.85))
            c.addLine(to: CGPoint(x: s * CGFloat(x + 0.12) + 6, y: s * 0.7)); c.closePath(); c.fillPath()
        }
        c.setFillColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 1)
        c.fill(CGRect(x: s * 0.46, y: s * 0.25, width: s * 0.08, height: s * 0.12))
    }

    /// Seamless pale-blue glass tiles with lighter grout.
    private static func glassTile(_ c: CGContext, _ s: CGFloat) {
        let cell = s / 4
        for i in 0..<4 { for j in 0..<4 {
            let shade = CGFloat((i + j) % 2) * 0.05
            c.setFillColor(red: 0.6 + shade, green: 0.82 + shade, blue: 0.94, alpha: 1)
            c.fill(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell))
        } }
        c.setStrokeColor(red: 0.9, green: 0.96, blue: 1, alpha: 1); c.setLineWidth(3)
        for k in 0...4 {
            c.stroke(CGRect(x: CGFloat(k) * cell - 1.5, y: -2, width: 0.01, height: s + 4))
            c.stroke(CGRect(x: -2, y: CGFloat(k) * cell - 1.5, width: s + 4, height: 0.01))
        }
    }

    // MARK: Video

    /// Two seconds of rippling blue water around a white fountain.
    private static func fountainVideo() -> URL? {
        let url = folder.appendingPathComponent("fountain.mp4")
        let size = 192
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
        guard writer.canAdd(input) else { return nil }
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for f in 0..<48 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let row = CVPixelBufferGetBytesPerRow(buffer)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<size { for x in 0..<size {
                    let dx = Double(x - size / 2), dy = Double(y - size / 2), r = (dx * dx + dy * dy).squareRoot()
                    let wave = 0.5 + 0.5 * sin(r / 6 - Double(f) / 3)
                    let o = y * row + x * 4
                    if r < 18 { p[o] = 240; p[o + 1] = 240; p[o + 2] = 245 } else {
                        p[o] = UInt8(170 + 60 * wave); p[o + 1] = UInt8(110 + 60 * wave); p[o + 2] = UInt8(40 + 30 * wave)
                    }
                    p[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 24))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed ? url : nil
    }

    // MARK: Models (OBJ text)

    private static func obj(_ name: String, _ boxes: [(min: [Double], max: [Double])]) -> URL {
        var text = "# Moonlight test model\n", base = 0
        for b in boxes {
            let (a, z) = (b.min, b.max)
            for v in [[a[0], a[1], a[2]], [z[0], a[1], a[2]], [z[0], z[1], a[2]], [a[0], z[1], a[2]], [a[0], a[1], z[2]], [z[0], a[1], z[2]], [z[0], z[1], z[2]], [a[0], z[1], z[2]]] {
                text += "v \(v[0]) \(v[1]) \(v[2])\n"
            }
            for f in [[1, 3, 2], [1, 4, 3], [5, 6, 7], [5, 7, 8], [1, 2, 6], [1, 6, 5], [4, 8, 7], [4, 7, 3], [1, 5, 8], [1, 8, 4], [2, 3, 7], [2, 7, 6]] {
                text += "f \(base + f[0]) \(base + f[1]) \(base + f[2])\n"
            }
            base += 8
        }
        let url = folder.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A wide house: walls, a roof slab, a chimney; many triangles from a fence row.
    private static func house() -> [(min: [Double], max: [Double])] {
        var boxes: [(min: [Double], max: [Double])] = [([-2, 0, -1.5], [2, 2.2, 1.5]), ([-2.3, 2.2, -1.8], [2.3, 2.6, 1.8]), ([1, 2.6, 0], [1.4, 3.3, 0.4])]
        for i in 0..<40 { boxes.append(([-2.5 + Double(i) * 0.125, 0, 2], [-2.45 + Double(i) * 0.125, 0.6, 2.05])) }
        return boxes
    }

    /// A standing figure: legs, body, arms, head — taller than wide, no skeleton.
    private static func person() -> [(min: [Double], max: [Double])] {
        [([-0.2, 0, -0.1], [-0.05, 0.85, 0.1]), ([0.05, 0, -0.1], [0.2, 0.85, 0.1]), ([-0.25, 0.85, -0.12], [0.25, 1.45, 0.12]),
         ([-0.4, 0.9, -0.06], [-0.27, 1.42, 0.06]), ([0.27, 0.9, -0.06], [0.4, 1.42, 0.06]), ([-0.12, 1.47, -0.12], [0.12, 1.75, 0.12])]
    }
}
#endif
