import Foundation
import Metal
import Darwin

enum GenerationResources {
    static var availableBytes: UInt64 { UInt64(os_proc_available_memory()) }

    static func check(minimumMemory: UInt64 = 240 << 20) throws {
        try Task.checkCancellation()
        guard MTLCreateSystemDefaultDevice() != nil else { throw GenerationError.unsupported("设备不支持 Metal，无法本地生成。") }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw GenerationError.thermal }
        guard availableBytes >= minimumMemory else { throw GenerationError.memory }
    }

    /// Check between expensive steps. Core ML prediction itself is not interruptible.
    /// Serious thermal state pauses, critical thermal state fails safely.
    static func checkpoint(minimumMemory: UInt64 = 240 << 20) async throws {
        try check(minimumMemory: minimumMemory)
        while ProcessInfo.processInfo.thermalState == .serious {
            try await Task.sleep(for: .seconds(1))
            try check(minimumMemory: minimumMemory)
        }
    }

    static var gridEdge: Int { availableBytes > 900 << 20 && !ProcessInfo.processInfo.isLowPowerModeEnabled ? 160 : 96 }
    static var textureEdge: Int { availableBytes > 900 << 20 ? 2048 : 1024 }

    static func checkDisk(at directory: URL, bytes: Int64) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= bytes + (100 << 20) else {
            throw GenerationError.storage
        }
    }
}

typealias GenerationProgress = @Sendable (String, Double?) async -> Void
