import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// What the on-device model returns: anchors only. Handles are computed
/// from the points (`ShapeGeneration`), so the output always parses into an
/// editable outline instead of free text.
@available(iOS 26.0, *)
@Generable(description: "A closed 2D outline described by anchor points on a unit square")
struct GeneratedOutlineSpec {
    @Guide(description: "Anchor points in clockwise order around the outline, starting at the top", .count(4...12))
    var anchors: [GeneratedAnchorSpec]
}

@available(iOS 26.0, *)
@Generable(description: "One anchor point of the outline")
struct GeneratedAnchorSpec {
    @Guide(description: "Horizontal position: 0 is the left edge, 1 is the right edge", .range(0.0...1.0))
    var x: Double
    @Guide(description: "Vertical position: 0 is the top edge, 1 is the bottom edge", .range(0.0...1.0))
    var y: Double
    @Guide(description: "true for a rounded curve through this point, false for a sharp point or corner")
    var smooth: Bool
}
#endif

/// Text-to-shape with Apple Intelligence. Runs on device only; nothing is
/// uploaded. Hidden where the model is unavailable (unsupported iPhone,
/// Apple Intelligence off, model not downloaded).
enum GlassShapeAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    enum Failure: Error {
        case invalid(ShapeGenerationProblem)
        case model(String)
        var message: String {
            switch self {
            case .invalid(let problem): L10n.t("生成的形状不可用（\(problem.message)），请换个说法再试。", "The generated shape isn't usable (\(problem.message)). Try describing it differently.")
            case .model(let text): text
            }
        }
    }

    /// Generates an outline, streaming finished anchors to `onPartial`. An
    /// unusable result is retried once before giving up.
    static func generate(_ prompt: String, onPartial: @escaping @Sendable @MainActor ([ShapePoint]) -> Void) async -> Result<ShapeOutline, Failure> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            var request = prompt
            for attempt in 0..<2 {
                do {
                    let anchors = try await stream(request, onPartial: onPartial)
                    switch ShapeGeneration.outline(from: anchors) {
                    case .success(let outline): return .success(outline)
                    case .failure(let problem):
                        if attempt == 1 { return .failure(.invalid(problem)) }
                        request = prompt + "\n(Previous attempt was unusable: \(problem). Use 5 to 10 anchors in clockwise order, spread around the outline, and do not let it cross itself.)"
                    }
                } catch {
                    return .failure(.model(describe(error)))
                }
            }
        }
        #endif
        return .failure(.model(L10n.t("此设备不支持 Apple 智能。", "Apple Intelligence isn't available on this device.")))
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func stream(_ prompt: String, onPartial: @escaping @Sendable @MainActor ([ShapePoint]) -> Void) async throws -> [GeneratedShapeAnchor] {
        let session = LanguageModelSession(instructions: ShapeGeneration.instructions)
        var latest: [GeneratedShapeAnchor] = []
        for try await snapshot in session.streamResponse(to: prompt, generating: GeneratedOutlineSpec.self) {
            let partial = snapshot.content.anchors ?? []
            let points = ShapeGeneration.partialPoints(partial.map { ($0.x, $0.y) })
            latest = partial.compactMap { anchor in
                guard let x = anchor.x, let y = anchor.y else { return nil }
                return GeneratedShapeAnchor(x: x, y: y, smooth: anchor.smooth ?? true)
            }
            await onPartial(points)
        }
        return latest
    }

    @available(iOS 26.0, *)
    private static func describe(_ error: Error) -> String {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation: return L10n.t("这段描述无法生成，请换个说法。", "That description can't be generated. Try other words.")
            case .unsupportedLanguageOrLocale: return L10n.t("当前语言暂不支持，请换用英文描述。", "This language isn't supported yet. Try English.")
            case .exceededContextWindowSize: return L10n.t("描述太长，请缩短后再试。", "The description is too long.")
            default: break
            }
        }
        return L10n.t("生成失败：", "Generation failed: ") + error.localizedDescription
    }
    #endif
}
