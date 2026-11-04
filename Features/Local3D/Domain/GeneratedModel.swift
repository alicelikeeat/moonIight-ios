import Foundation

enum GenerationError: Error, LocalizedError, Equatable {
    case unsupported(String), invalidInput(String), noSubject, flatDepth, cancelled
    case memory, thermal, storage, corruptAsset, modelMissing, busy

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason), .invalidInput(let reason): return reason
        case .noSubject: return "未找到清晰主体，请选择背景简单、主体完整的图片。"
        case .flatDepth: return "主体深度变化不足，无法生成有效立体网格。请换一张图片。"
        case .cancelled: return "任务已取消，原素材未修改。"
        case .memory: return "可用内存不足，已停止生成。请关闭其他应用后重试。"
        case .thermal: return "设备温度过高，已停止任务。请冷却后重试。"
        case .storage: return "存储空间不足，无法保存生成资源。"
        case .corruptAsset: return "模型文件缺失或损坏，无法加载。"
        case .modelMissing: return "离线深度模型缺失或无法加载，请重新安装包含模型的完整应用。"
        case .busy: return "已有生成任务，请等待或取消当前任务。"
        }
    }
}

struct DepthMesh: Codable, Equatable, Sendable {
    var positions: [SIMD3<Float>]
    var textureCoordinates: [SIMD2<Float>]
    var indices: [UInt32]

    var triangleCount: Int { indices.count / 3 }

    func validate() throws {
        guard positions.count >= 3, positions.count <= 70_000,
              textureCoordinates.count == positions.count,
              !indices.isEmpty, indices.count <= 400_000, indices.count % 3 == 0,
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs($0.x) <= 2 && abs($0.y) <= 2 && abs($0.z) <= 2 }),
              textureCoordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              indices.allSatisfy({ Int($0) < positions.count }) else { throw GenerationError.corruptAsset }
        let z = positions.map(\.z)
        guard (z.max() ?? 0) - (z.min() ?? 0) > 0.001 else { throw GenerationError.flatDepth }
    }
}

/// A front surface inferred from monocular *relative inverse depth*.
/// Never invents a back surface, volume, bones, or clothing parts.
enum ModelOptimizationService {
    static func depthMesh(width: Int, height: Int, inverseDepth: [Float], mask: [UInt8],
                          imageAspect: Float, maximumEdge: Int) throws -> DepthMesh {
        guard width >= 3, height >= 3, width <= 4096, height <= 4096,
              width * height == inverseDepth.count, mask.count == inverseDepth.count,
              imageAspect.isFinite, imageAspect > 0.05, imageAspect < 20 else {
            throw GenerationError.invalidInput("深度与主体遮罩尺寸无效。")
        }
        let foreground = inverseDepth.indices.filter { mask[$0] >= 128 && inverseDepth[$0].isFinite }
        guard foreground.count >= 32 else { throw GenerationError.noSubject }
        let sorted = foreground.map { inverseDepth[$0] }.sorted()
        let low = sorted[sorted.count / 50], high = sorted[sorted.count - 1 - sorted.count / 50]
        guard high - low > max(0.00001, abs(high) * 0.0001) else { throw GenerationError.flatDepth }
        let edge = min(192, max(16, maximumEdge))
        let columns = max(3, Int(Float(edge) * min(1, imageAspect)))
        let rows = max(3, Int(Float(edge) * min(1, 1 / imageAspect)))
        let size = SIMD2<Float>(min(1, imageAspect), min(1, 1 / imageAspect))
        var vertices: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], indices: [UInt32] = []
        var lookup = [Int](repeating: -1, count: rows * columns)
        for y in 0..<rows {
            try Task.checkCancellation()
            for x in 0..<columns {
                let u = Float(x) / Float(columns - 1), v = Float(y) / Float(rows - 1)
                let px = Int((u * Float(width - 1)).rounded()), py = Int((v * Float(height - 1)).rounded())
                let sample = py * width + px
                guard mask[sample] >= 128, inverseDepth[sample].isFinite else { continue }
                let depth = min(1, max(0, (inverseDepth[sample] - low) / (high - low)))
                lookup[y * columns + x] = vertices.count
                vertices.append([(u - 0.5) * size.x, (0.5 - v) * size.y, (depth - 0.5) * 0.28])
                uv.append([u, 1 - v])
            }
        }
        func triangle(_ a: Int, _ b: Int, _ c: Int) {
            guard a >= 0, b >= 0, c >= 0 else { return }
            // Avoid stretching triangles across occlusion/depth discontinuities.
            let depths = [vertices[a].z, vertices[b].z, vertices[c].z]
            guard depths.max()! - depths.min()! <= 0.10 else { return }
            indices += [UInt32(a), UInt32(b), UInt32(c)]
        }
        for y in 0..<(rows - 1) {
            try Task.checkCancellation()
            for x in 0..<(columns - 1) {
                let a = lookup[y * columns + x], b = lookup[y * columns + x + 1]
                let c = lookup[(y + 1) * columns + x], d = lookup[(y + 1) * columns + x + 1]
                triangle(a, c, b); triangle(b, c, d)
            }
        }
        // Compact unused vertices (e.g. isolated foreground pixels).
        let used = Set(indices).sorted()
        var remap: [UInt32: UInt32] = [:]
        for (new, old) in used.enumerated() { remap[old] = UInt32(new) }
        let mesh = DepthMesh(positions: used.map { vertices[Int($0)] },
                             textureCoordinates: used.map { uv[Int($0)] }, indices: indices.map { remap[$0]! })
        try mesh.validate()
        return mesh
    }
}

struct GeneratedModelManifest: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case depthSurface, photogrammetry }
    static let engineVersion = "moonlight-local3d/1.66-depth-v1"
    var id: UUID
    var createdAt: Date
    var title: String
    var sourceName: String
    var sourceHash: String
    var sourceExtension: String
    var sourceLibraryID: String?
    var engine: String
    var kind: Kind
    var quality: String
    var vertices: Int
    var triangles: Int
    var textureWidth: Int
    var textureHeight: Int
    var textureHash: String?
    var modelBytes: Int
    var elapsedSeconds: Double
    /// Sampled process physical footprint, not the OS high-water mark or GPU total.
    var sampledPeakFootprintBytes: UInt64? = nil
    // Only set after the actual saved file has loaded in RealityKit.
    var realityKitValidated: Bool
    var skeletonStatus = "notImplemented"
    var animationStatus = "staticOnly"
    var clothingStatus = "wholeMaterialOnly"
}

struct ModelSkinPreset: Codable, Equatable, Sendable {
    var modelID: UUID
    var red: Float = 1
    var green: Float = 1
    var blue: Float = 1
    var roughness: Float = 0.8
    func validate() throws {
        guard [red, green, blue, roughness].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw GenerationError.corruptAsset
        }
    }
}

struct VideoQualityReport: Codable, Equatable, Sendable {
    var sampled: Int
    var accepted: Int
    var blurry: Int
    var duplicates: Int
    var humanFrames: Int
    var durationSeconds: Double
    /// Feature distance is a diversity heuristic, never measured camera poses.
    var diverseTransitions: Int
    var coverageStatus: String { accepted < 20 || diverseTransitions < 8 ? "insufficient" : "unverified" }
    var canAttemptObjectCapture: Bool { humanFrames == 0 && coverageStatus == "unverified" }
    var guidance: String {
        if humanFrames > 0 { return "检测到人物：普通人物视频不能视为静态物体多视角重建。请选择清晰单帧进行基础立体化，或重新拍摄静止物体。" }
        if coverageStatus == "insufficient" { return "清晰且有变化的画面不足。请保持物体静止，缓慢环绕拍摄，覆盖正面、侧面和背面。可选择单帧进行基础立体化。" }
        return "已提取候选多视角输入，尚未验证真实视角覆盖。只有实际摄影测量并通过 RealityKit 加载后才算重建成功。"
    }
}
