import Foundation

// One semantic material, two looks. Pixel Glass is flat and mostly opaque.
// Spatial Glass is a RealityKit/Metal PBR preset. Screen-space system glass
// is not a preset here — that layer stays on the HUD.

enum GlassSemantic: String, Codable, CaseIterable, Sendable {
    case moonlightCrystalWhite
    case moonlightCrystalBlue
    case streetCrystal
    case houseGlass
    case landmarkGlass
    case water
}

enum GlassRenderRole: String, Codable, Sendable {
    case ground, structure, landmark, water, decor, playerBuilt
}

enum GlassViewPreset: String, Codable, Sendable {
    case pixel, spatial
}

enum GlassQualityTier: String, Sendable {
    case low, standard, high
}

struct SemanticGlass: Equatable, Sendable {
    var id: GlassSemantic
    var tintHex: String
    var roughness: Double
    /// 0 keeps the surface solid, 1 asks for a clear body. Presets may ignore this for large ground.
    var transparencyIntent: Double
    var glow: Double
}

struct ResolvedGlassLook: Equatable, Sendable {
    var tintHex: String
    var roughness: Double
    /// 1 is fully solid. Large ground stays at or above 0.92 in both presets.
    var opacity: Double
    var metallic: Double
    var clearcoat: Double
    var emissive: Double
    var pixelated: Bool
    /// Landmark spatial glass at high quality only. The renderer spends clearcoat here.
    /// It is not a refraction shader and not a full-screen transparent pass.
    var prioritySpecular: Bool
}

enum GlassMaterialResolver {
    static func semantic(_ id: GlassSemantic) -> SemanticGlass {
        switch id {
        case .moonlightCrystalWhite:
            return SemanticGlass(id: id, tintHex: "F4F7FB", roughness: 0.22, transparencyIntent: 0.2, glow: 0.04)
        case .moonlightCrystalBlue:
            return SemanticGlass(id: id, tintHex: "9EC9E8", roughness: 0.18, transparencyIntent: 0.28, glow: 0.08)
        case .streetCrystal:
            return SemanticGlass(id: id, tintHex: "D5E2EE", roughness: 0.4, transparencyIntent: 0.06, glow: 0)
        case .houseGlass:
            return SemanticGlass(id: id, tintHex: "E7EEF6", roughness: 0.3, transparencyIntent: 0.18, glow: 0.02)
        case .landmarkGlass:
            return SemanticGlass(id: id, tintHex: "F7FBFF", roughness: 0.08, transparencyIntent: 0.42, glow: 0.22)
        case .water:
            return SemanticGlass(id: id, tintHex: "7EB6D8", roughness: 0.05, transparencyIntent: 0.55, glow: 0.02)
        }
    }

    static func resolve(_ id: GlassSemantic, preset: GlassViewPreset, role: GlassRenderRole, quality: GlassQualityTier) -> ResolvedGlassLook {
        let source = semantic(id)
        var look = ResolvedGlassLook(tintHex: source.tintHex, roughness: source.roughness, opacity: 1, metallic: 0.02, clearcoat: 0.1, emissive: source.glow, pixelated: preset == .pixel, prioritySpecular: false)
        switch (preset, role) {
        case (.pixel, .ground):
            look.opacity = 0.97; look.roughness = 0.62; look.clearcoat = 0.04; look.emissive = min(look.emissive, 0.02)
        case (.spatial, .ground):
            look.opacity = 0.94; look.roughness = 0.34; look.clearcoat = 0.22; look.metallic = 0.04
        case (.pixel, .structure), (.pixel, .playerBuilt):
            look.opacity = 0.98; look.roughness = 0.58; look.clearcoat = 0.05
        case (.spatial, .structure), (.spatial, .playerBuilt):
            look.opacity = quality == .low ? 0.9 : 0.78
            look.roughness = quality == .low ? 0.4 : 0.2
            look.clearcoat = quality == .high ? 0.45 : 0.28
        case (.pixel, .landmark):
            look.opacity = 0.92; look.roughness = 0.42; look.clearcoat = 0.16; look.emissive = max(look.emissive, 0.24)
        case (.spatial, .landmark):
            switch quality {
            case .high:
                look.opacity = 0.58; look.roughness = 0.06; look.clearcoat = 1; look.emissive = max(look.emissive, 0.16); look.prioritySpecular = true
            case .standard:
                look.opacity = 0.66; look.roughness = 0.12; look.clearcoat = 0.75; look.emissive = max(look.emissive, 0.1)
            case .low:
                look.opacity = 0.88; look.roughness = 0.32; look.clearcoat = 0.2
            }
        case (.pixel, .water):
            look.opacity = 0.74; look.roughness = 0.36; look.clearcoat = 0.08
        case (.spatial, .water):
            look.opacity = quality == .low ? 0.7 : 0.5; look.roughness = 0.06; look.clearcoat = quality == .low ? 0.2 : 0.65
        case (.pixel, .decor):
            look.opacity = 0.96; look.roughness = 0.5; look.clearcoat = 0.05
        case (.spatial, .decor):
            look.opacity = 0.9; look.roughness = 0.24; look.clearcoat = 0.3
        }
        if role == .ground {
            look.opacity = max(look.opacity, preset == .pixel ? 0.97 : 0.94)
            look.prioritySpecular = false
        }
        if preset == .pixel { look.prioritySpecular = false; look.pixelated = true }
        return look
    }
}
