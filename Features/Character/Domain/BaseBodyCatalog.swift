import Foundation

// v1.92: a library of base bodies, not one. Every character starts from a
// base; a base is either built in (HumanBase shaped by MakeHuman's own
// gender and age targets plus bone proportions), or a model the user made
// with the AI 3D page or imported (GLB / glTF / USDZ / OBJ / FBX), rigged
// on the standard skeleton. All bases share the joint standard, so the
// motion library, sockets and combat timing work on each. Pure Swift.

struct BaseBodyEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// HumanBase with a built-in shape.
        case builtin
        /// A model from the AI 3D page or an imported file (Generated3D id), rigged.
        case model
    }
    enum Category: String, Codable, CaseIterable, Sendable {
        case adult, child, elder, giant, custom
        var title: String {
            switch self {
            case .adult: L10n.t("成人", "Adult"); case .child: L10n.t("儿童", "Child"); case .elder: L10n.t("老人", "Elder")
            case .giant: L10n.t("大型 / Boss", "Large / Boss"); case .custom: L10n.t("自定义模型", "Custom model")
            }
        }
    }

    var id: String
    var name: String
    var kind: Kind
    var category: Category
    /// Built-in bases: the shape (HumanBase parameters).
    var shape: HumanShape?
    /// Model bases: the Generated3D model id.
    var modelID: String?
    /// Default skin colour.
    var skin: SIMD3<Float> = SIMD3(0.86, 0.72, 0.62)
    /// Collision and hurt-box size relative to a 1.75 m adult.
    var bodyScale: Float { (shape?.clamped.height ?? 1.75) / 1.75 }
    var symbol: String {
        switch category { case .adult: "figure.stand"; case .child: "figure.child"; case .elder: "figure.walk.motion"; case .giant: "figure.strengthtraining.traditional"; case .custom: "cube.transparent" }
    }
}

enum BaseBodyCatalog {
    static let neutralID = "humanbase.neutral"

    static let builtins: [BaseBodyEntry] = [
        BaseBodyEntry(id: neutralID, name: L10n.t("中性人台", "Neutral Mannequin"), kind: .builtin, category: .adult, shape: .standard),
        BaseBodyEntry(id: "humanbase.woman", name: L10n.t("女性", "Woman"), kind: .builtin, category: .adult,
                      shape: HumanShape(height: 1.66, build: -0.1, gender: -1, hips: 0.2, faceOval: 0.5), skin: SIMD3(0.9, 0.76, 0.66)),
        BaseBodyEntry(id: "humanbase.man", name: L10n.t("男性", "Man"), kind: .builtin, category: .adult,
                      shape: HumanShape(height: 1.8, muscle: 0.3, gender: 1, shoulders: 0.3, faceSquare: 0.4), skin: SIMD3(0.82, 0.66, 0.54)),
        BaseBodyEntry(id: "humanbase.child", name: L10n.t("小孩", "Child"), kind: .builtin, category: .child,
                      shape: HumanShape(height: 1.25, age: -1, headSize: 1.08, faceRound: 0.6), skin: SIMD3(0.95, 0.8, 0.7)),
        BaseBodyEntry(id: "humanbase.elder", name: L10n.t("老人", "Elder"), kind: .builtin, category: .elder,
                      shape: HumanShape(height: 1.64, build: 0.1, age: 1), skin: SIMD3(0.84, 0.72, 0.64)),
        BaseBodyEntry(id: "humanbase.giant", name: L10n.t("大型 Boss", "Giant Boss"), kind: .builtin, category: .giant,
                      shape: HumanShape(height: 3.4, build: 0.6, muscle: 1, gender: 1, shoulders: 1, neck: 0.6, armLength: 1.12, headSize: 0.85, hands: 0.8, feet: 0.6, faceSquare: 1),
                      skin: SIMD3(0.55, 0.45, 0.5)),
    ]

    static func builtin(_ id: String) -> BaseBodyEntry? { builtins.first { $0.id == id } }

    /// The base a model becomes (rigged model from the AI 3D page or an import).
    static func entry(model id: String, name: String) -> BaseBodyEntry {
        BaseBodyEntry(id: "model." + id, name: name, kind: .model, category: .custom, modelID: id)
    }
}
