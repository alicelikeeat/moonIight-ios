import BackgroundTasks
import Foundation

enum TransferHub {
    static var completions: [String: () -> Void] = [:]
    static weak var center: TransferCenter?
}

/// Background URLSession downloads. Active jobs show up under 库 › 我的下载 and resume after a relaunch.
/// Automatic jobs stay out of the library.
final class TransferCenter: NSObject, URLSessionDownloadDelegate {
    static let activeID = "com.moonlight.feed.downloads"
    static let autoID = "com.moonlight.feed.autocache"

    var onProgress: ((String, Double, Int64) -> Void)?
    var onFinish: ((String, URL?, String?) -> Void)?
    var onResume: ((String, String) -> Void)?
    private let lock = NSLock()
    private var sessions: [String: URLSession] = []
    private var jobs: [String: TransferJob] = [:]
    private var settled = Set<String>()

    func attach(jobs: [TransferJob]) {
        TransferHub.center = self
        lock.lock()
        self.jobs = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        lock.unlock()
        sessions[Self.activeID] = make(Self.activeID)
        sessions[Self.autoID] = make(Self.autoID)
        for id in [Self.activeID, Self.autoID] {
            sessions[id]?.getAllTasks { [weak self] tasks in
                let running = Set(tasks.compactMap(\.taskDescription))
                DispatchQueue.main.async {
                    self?.restartMissing(running: running)
                }
            }
        }
        drainCompletions()
    }

    func wake(_ identifier: String) {
        if sessions[identifier] == nil { sessions[identifier] = make(identifier) }
        drainCompletions()
    }

    func start(_ job: TransferJob) {
        lock.lock()
        jobs[job.id] = job
        lock.unlock()
        let session = sessions[job.lane == .active ? Self.activeID : Self.autoID] ?? sessions.values.first
        guard let session, let url = URL(string: job.url) else { return }
        let task: URLSessionDownloadTask
        if let path = job.resumeFile, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
            task = session.downloadTask(withResumeData: data)
        } else {
            let hasPartial = job.partialFile.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } != nil
            switch TransferRestart.choose(received: job.received, hasResume: false, hasPartial: hasPartial) {
            case .resume:
                task = session.downloadTask(with: url)
            case .range:
                task = session.downloadTask(with: ResumePlan.request(url: url, receivedBytes: job.received))
            case .full:
                task = session.downloadTask(with: url)
            }
        }
        task.taskDescription = job.id
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async { self.onProgress?(id, fraction, totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let job = lockedJob(id) else { return }
        Paths.ensureDirs()
        let ext = downloadTask.response?.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
        let folder = job.lane == .auto ? Paths.cache : Paths.media
        let dest = folder.appendingPathComponent("dl_\(IDs.new()).\(ext)")
        do {
            if let partial = job.partialFile, FileManager.default.fileExists(atPath: partial), job.received > 0 {
                let part = Paths.cache.appendingPathComponent("part_\(IDs.new()).\(ext)")
                try FileManager.default.copyItem(at: location, to: part)
                try FileJoin.append(part: part, onto: URL(fileURLWithPath: partial))
                if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: partial), to: dest)
            } else {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: location, to: dest)
            }
            settle(id, file: dest, error: nil)
        } catch {
            settle(id, file: nil, error: "文件不完整")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        guard let error else { return }
        let ns = error as NSError
        if let data = ResumePlan.resumeData(from: ns), var job = lockedJob(id), !job.retried {
            Paths.ensureDirs()
            let file = Paths.resume.appendingPathComponent("\(id).resume")
            try? data.write(to: file)
            job.resumeFile = file.path
            job.retried = true
            lock.lock()
            jobs[id] = job
            lock.unlock()
            let received = job.received
            DispatchQueue.main.async {
                self.onResume?(id, file.path)
                self.onProgress?(id, 0, received)
            }
            start(job)
            return
        }
        settle(id, file: nil, error: ns.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let id = session.configuration.identifier
        DispatchQueue.main.async {
            if let id, let done = TransferHub.completions.removeValue(forKey: id) { done() }
        }
    }

    private func restartMissing(running: Set<String>) {
        lock.lock()
        let pending = jobs.values.filter { !$0.done && !running.contains($0.id) }
        lock.unlock()
        for job in pending {
            start(job)
        }
    }

    private func lockedJob(_ id: String) -> TransferJob? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]
    }

    private func settle(_ id: String, file: URL?, error: String?) {
        lock.lock()
        if settled.contains(id) { lock.unlock(); return }
        settled.insert(id)
        lock.unlock()
        DispatchQueue.main.async { self.onFinish?(id, file, error) }
    }

    private func make(_ identifier: String) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func drainCompletions() {
        for (id, done) in TransferHub.completions {
            TransferHub.completions.removeValue(forKey: id)
            done()
        }
    }
}

enum BGRefresh {
    static let id = "com.moonlight.feed.refresh"
    private static var installed = false

    static func install() {
        if installed { return }
        installed = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            run(refresh)
        }
    }

    static func schedule(enabled: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func run(_ task: BGAppRefreshTask) {
        schedule(enabled: true)
        let work = Task {
            let items = await NASAAPI.search(query: "moon", limit: 3)
            await MainActor.run { AppHooks.model?.absorbRefresh(items) }
        }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
}

enum AppHooks {
    static weak var model: AppModel?
}
