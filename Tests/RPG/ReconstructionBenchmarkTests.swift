import Foundation

/// v1.92: the photo → 3D benchmark. Prints the full score table (the CI log
/// keeps it) and holds the floor: every method returns a body, a fit from
/// one photo beats the neutral body, and side photos do not make carving worse.
func reconstructionBenchmarkTests() {
    let start = Date()
    let scores = ReconstructionBenchmark.run()
    let summary = Dictionary(uniqueKeysWithValues: ReconstructionBenchmark.summary(scores).map { ($0.method, $0) })
    print("Photo → 3D benchmark (\(ReconstructionBenchmark.subjects.count) subjects, \(String(format: "%.0f", Date().timeIntervalSince(start))) s):")
    print(ReconstructionBenchmark.report(scores))
    let dir = URL(fileURLWithPath: "build/benchmark")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? ReconstructionBenchmark.report(scores).write(to: dir.appendingPathComponent("reconstruction.md"), atomically: true, encoding: .utf8)

    check(scores.count == ReconstructionBenchmark.subjects.count * ReconstructionMethod.allCases.count, "benchmark: every subject is scored by every method")
    check(scores.allSatisfy { $0.iou.isFinite && $0.chamfer.isFinite && $0.iou >= 0 && $0.iou <= 1 }, "benchmark: scores are finite and IoU within 0…1")
    check(scores.filter { $0.method == .carve2 || $0.method == .carve4 }.allSatisfy { $0.failure == nil },
          "benchmark: carving rebuilds every subject (\(scores.compactMap { s in s.failure.map { "\(s.subject)/\(s.method.rawValue): \($0)" } }))")
    // Sanity of the scorer itself: the truth against itself is perfect.
    if let body = HumanBase.build(.standard, lod: 1) {
        check(ReconstructionBenchmark.iou(body.mesh, body.mesh) > 0.99 && ReconstructionBenchmark.chamfer(body.mesh, body.mesh) < 1e-4
              && (ReconstructionBenchmark.jointError(body, body) ?? 1) < 1e-5, "benchmark: a body scored against itself is perfect")
    }
    if let fit = summary[.photoFit], let neutral = summary[.neutral], let fj = fit.jointError, let nj = neutral.jointError {
        check(fj < nj, "benchmark: one photo's fit beats the neutral body on joints (\(fj) vs \(nj))")
        check(fit.iou > neutral.iou, "benchmark: one photo's fit beats the neutral body on outline (\(fit.iou) vs \(neutral.iou))")
    } else { check(false, "benchmark: fit and neutral scores exist") }
    if let two = summary[.carve2], let four = summary[.carve4] {
        check(four.iou >= two.iou - 0.01, "benchmark: side photos do not make carving worse (\(four.iou) vs \(two.iou))")
    }
}
