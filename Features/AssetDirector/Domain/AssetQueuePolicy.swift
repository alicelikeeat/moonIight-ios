import Foundation

// v1.87 AI Asset Director — the processing queue as pure state, so it can
// be saved, resumed after the app is closed, and tested. The app's actor
// (AssetProcessingQueue) only runs what this decides.

enum AssetJobState: String, Codable, Sendable {
    case waiting, running, done, failed, cancelled
}

struct AssetJob: Codable, Equatable, Sendable {
    var assetID: String
    var state: AssetJobState = .waiting
    var attempts = 0
    var lastError: String?
    var enqueuedAt: Date
}

struct AssetQueueState: Codable, Equatable, Sendable {
    var jobs: [AssetJob] = []
    var paused = false

    var waiting: Int { jobs.filter { $0.state == .waiting }.count }
    var running: Int { jobs.filter { $0.state == .running }.count }
    var failed: Int { jobs.filter { $0.state == .failed }.count }
    var done: Int { jobs.filter { $0.state == .done }.count }
}

/// Device conditions the queue adapts to.
struct AssetDeviceConditions: Equatable, Sendable {
    /// ProcessInfo.ThermalState raw value: 0 nominal … 3 critical.
    var thermal = 0
    var lowPower = false
    /// Physical memory in MB.
    var memoryMB = 4096
    var background = false
}

enum AssetQueuePolicy {
    static let maxAttempts = 3
    /// Finished jobs kept for the status counts; older ones are dropped.
    static let keepFinished = 600

    /// How many analyses may run at once. Never unbounded; none in the
    /// background or when the device is critically hot.
    static func concurrency(_ c: AssetDeviceConditions) -> Int {
        if c.background || c.thermal >= 3 { return 0 }
        var n = c.memoryMB >= 6000 ? 3 : c.memoryMB >= 3500 ? 2 : 1
        if c.thermal == 2 || c.lowPower { n = 1 }
        return n
    }

    static func enqueue(_ ids: [String], into q: inout AssetQueueState, now: Date) {
        for id in ids {
            if let i = q.jobs.firstIndex(where: { $0.assetID == id }) {
                // Re-queue finished, failed or cancelled jobs; leave active ones alone.
                if q.jobs[i].state != .waiting && q.jobs[i].state != .running { q.jobs[i] = AssetJob(assetID: id, enqueuedAt: now) }
            } else {
                q.jobs.append(AssetJob(assetID: id, enqueuedAt: now))
            }
        }
    }

    /// Jobs to start now, oldest first, within the concurrency limit.
    static func next(_ q: AssetQueueState, limit: Int) -> [String] {
        guard !q.paused else { return [] }
        let free = max(0, limit - q.running)
        // Oldest first; equal times keep their queue order.
        let waiting = q.jobs.enumerated().filter { $0.element.state == .waiting }
            .sorted { $0.element.enqueuedAt == $1.element.enqueuedAt ? $0.offset < $1.offset : $0.element.enqueuedAt < $1.element.enqueuedAt }
        return Array(waiting.prefix(free).map(\.element.assetID))
    }

    static func start(_ id: String, in q: inout AssetQueueState) {
        guard let i = q.jobs.firstIndex(where: { $0.assetID == id }), q.jobs[i].state == .waiting else { return }
        q.jobs[i].state = .running; q.jobs[i].attempts += 1
    }

    static func finish(_ id: String, in q: inout AssetQueueState) {
        guard let i = q.jobs.firstIndex(where: { $0.assetID == id }) else { return }
        q.jobs[i].state = .done; q.jobs[i].lastError = nil
        trim(&q)
    }

    /// A failure goes back to waiting while attempts remain and the error
    /// is worth retrying (e.g. memory pressure), otherwise it stays failed.
    static func fail(_ id: String, error: String, retryable: Bool, in q: inout AssetQueueState) {
        guard let i = q.jobs.firstIndex(where: { $0.assetID == id }) else { return }
        q.jobs[i].lastError = String(error.prefix(300))
        q.jobs[i].state = retryable && q.jobs[i].attempts < maxAttempts ? .waiting : .failed
    }

    static func cancel(_ ids: [String]? = nil, in q: inout AssetQueueState) {
        for i in q.jobs.indices where (ids?.contains(q.jobs[i].assetID) ?? true) && (q.jobs[i].state == .waiting || q.jobs[i].state == .running) {
            q.jobs[i].state = .cancelled
        }
    }

    static func retryFailed(in q: inout AssetQueueState) {
        for i in q.jobs.indices where q.jobs[i].state == .failed || q.jobs[i].state == .cancelled {
            q.jobs[i].state = .waiting; q.jobs[i].attempts = 0
        }
    }

    /// After a relaunch nothing is running: interrupted jobs wait again.
    static func recover(_ q: inout AssetQueueState) {
        for i in q.jobs.indices where q.jobs[i].state == .running { q.jobs[i].state = .waiting }
    }

    static func trim(_ q: inout AssetQueueState) {
        let finished = q.jobs.indices.filter { q.jobs[$0].state == .done }
        guard finished.count > keepFinished else { return }
        let drop = Set(finished.prefix(finished.count - keepFinished))
        q.jobs = q.jobs.indices.filter { !drop.contains($0) }.map { q.jobs[$0] }
    }
}
