import Foundation
import Metal
import RealityKit
import UIKit

// v1.93: the materials characters wear. Painted skins use their surface maps
// (roughness, detail normals) and, where RealityKit's CustomMaterial is
// available, the skin shader (subsurface approximation on the skin mask);
// hair uses the hair shader (strand highlight). Anywhere the shaders cannot
// run (the simulator, a device without the Metal library) the same textures
// go into a standard PBR material, so nothing disappears.

@MainActor enum CharacterShading {
    private static let library: MTLLibrary? = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
    private static var skinShader: CustomMaterial.SurfaceShader?
    private static var hairShader: CustomMaterial.SurfaceShader?
    /// Why the custom shaders are or are not in use (shown in the workbench).
    private(set) static var failure: String?

    static var shadersAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return library != nil
        #endif
    }

    static var status: String {
        if !shadersAvailable { return L10n.t("皮肤 / 头发着色器：本设备不可用（模拟器或缺少着色器库），使用标准 PBR 材质", "Skin / hair shaders: not available here (simulator or no shader library); standard PBR materials are used") }
        if let failure { return L10n.t("皮肤 / 头发着色器加载失败，使用标准 PBR：", "Skin / hair shaders failed to load; standard PBR is used: ") + failure }
        return L10n.t("皮肤着色器（透光近似）和头发着色器（发丝高光）已启用", "Skin shader (light-through approximation) and hair shader (strand highlight) are on")
    }

    private static func shader(_ name: String, _ cache: inout CustomMaterial.SurfaceShader?) -> CustomMaterial.SurfaceShader? {
        guard shadersAvailable, let library else { return nil }
        if let cache { return cache }
        let made = CustomMaterial.SurfaceShader(named: name, in: library)
        cache = made
        return made
    }

    /// A painted skin: colour atlas plus its surface maps (any may be missing).
    static func skin(color: TextureResource, normal: TextureResource?, roughness: TextureResource?, mask: TextureResource?) -> RealityKit.Material {
        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor = .init(tint: .white, texture: .init(color))
        if let roughness { pbr.roughness = .init(scale: 1, texture: .init(roughness)) } else { pbr.roughness = .init(floatLiteral: 0.75) }
        if let normal { pbr.normal = .init(texture: .init(normal)) }
        pbr.metallic = .init(floatLiteral: 0)
        guard normal != nil, roughness != nil, let mask, let surface = shader("moonlightSkin", &skinShader) else { return pbr }
        do {
            var custom = try CustomMaterial(from: pbr, surfaceShader: surface)
            custom.custom.texture = .init(mask)
            return custom
        } catch {
            failure = String(describing: error)
            return pbr
        }
    }

    /// Hair in one colour, or with its own texture (a fitted hair garment).
    static func hair(tint: UIColor, texture: TextureResource? = nil, fallback: RealityKit.Material) -> RealityKit.Material {
        guard let surface = shader("moonlightHair", &hairShader) else { return fallback }
        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor = texture.map { .init(tint: .white, texture: .init($0)) } ?? .init(tint: tint)
        pbr.roughness = .init(floatLiteral: 0.6)
        do { return try CustomMaterial(from: pbr, surfaceShader: surface) } catch {
            failure = String(describing: error)
            return fallback
        }
    }

    /// Cloth from a texture with its surface maps.
    static func cloth(color: TextureResource, normal: TextureResource?, roughness: TextureResource?) -> RealityKit.Material {
        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor = .init(tint: .white, texture: .init(color))
        if let roughness { pbr.roughness = .init(scale: 1, texture: .init(roughness)) } else { pbr.roughness = .init(floatLiteral: 0.7) }
        if let normal { pbr.normal = .init(texture: .init(normal)) }
        return pbr
    }

    /// Loads a texture file off the frame (nil when missing).
    static func load(_ url: URL?, semantic: TextureResource.Semantic) async -> TextureResource? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? await TextureResource(contentsOf: url, options: .init(semantic: semantic))
    }

    /// A saved character's garment material (its texture and surface maps; hair gets the hair shader).
    static func garment(package id: String, _ g: CustomGarment) async -> RealityKit.Material? {
        let store = CharacterLibrary.shared.store
        guard let color = await load(g.texture.map { store.textureURL(id, $0) }, semantic: .color) else { return nil }
        let normal = await load(g.normal.map { store.textureURL(id, $0) }, semantic: .normal)
        let rough = await load(g.roughness.map { store.textureURL(id, $0) }, semantic: .raw)
        let plain = cloth(color: color, normal: normal, roughness: rough)
        return g.slot == .hair ? hair(tint: .white, texture: color, fallback: plain) : plain
    }

    /// A saved character's painted-skin material (colour and surface maps).
    static func skin(package id: String, _ skin: CharacterSkin) async -> RealityKit.Material? {
        let store = CharacterLibrary.shared.store
        guard let color = await load(store.textureURL(id, skin.atlas), semantic: .color) else { return nil }
        let normal = await load(skin.normal.map { store.textureURL(id, $0) }, semantic: .normal)
        let rough = await load(skin.roughness.map { store.textureURL(id, $0) }, semantic: .raw)
        let mask = await load(skin.mask.map { store.textureURL(id, $0) }, semantic: .raw)
        return Self.skin(color: color, normal: normal, roughness: rough, mask: mask)
    }
}
