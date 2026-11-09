import Foundation

// v1.91: what a character looks like, kept apart from how it moves.
//   - CharacterMaterialProfile: one material description (base colour,
//     metal, roughness, opacity, glow, texture, style) for every renderer.
//   - Outfit pieces (hair, top, bottom, shoes, gloves) are real meshes: a
//     shell lifted off the body's own surface, carrying the body's weights,
//     so they bend with it on every motion and every body shape.
//   - Equipment (weapon, shield, back item) is rigid and rides a socket on
//     a joint; it never needs weights.
// Pure Swift (tested on Linux); the RealityKit side turns profiles into
// materials. A glass material here is a transparent 3D material, not the
// system's Liquid Glass controls.

struct CharacterMaterialProfile: Codable, Equatable, Sendable {
    enum Style: String, Codable, CaseIterable, Sendable {
        case pbr, oilPaint, pixel, toon, glass, energy
        var title: String {
            switch self {
            case .pbr: L10n.t("标准 PBR", "Standard PBR"); case .oilPaint: L10n.t("油画", "Oil Paint"); case .pixel: L10n.t("像素", "Pixel")
            case .toon: L10n.t("卡通", "Toon"); case .glass: L10n.t("半透明玻璃", "Translucent Glass"); case .energy: L10n.t("发光能量", "Glowing Energy")
            }
        }
    }
    /// RGB 0…1.
    var baseColor: SIMD3<Float> = SIMD3(0.8, 0.78, 0.75)
    var metallic: Float = 0
    var roughness: Float = 0.6
    var opacity: Float = 1
    var emission: SIMD3<Float> = .zero
    var emissionStrength: Float = 0
    /// Texture file name (in the character package), nil for plain colour.
    var texture: String?
    var style = Style.pbr

    var clamped: CharacterMaterialProfile {
        func c(_ v: Float, _ f: Float, _ lo: Float = 0, _ hi: Float = 1) -> Float { v.isFinite ? min(hi, max(lo, v)) : f }
        func c3(_ v: SIMD3<Float>, _ f: SIMD3<Float>) -> SIMD3<Float> { SIMD3(c(v.x, f.x), c(v.y, f.y), c(v.z, f.z)) }
        var m = self
        m.baseColor = c3(baseColor, SIMD3(0.8, 0.78, 0.75)); m.metallic = c(metallic, 0); m.roughness = c(roughness, 0.6)
        m.opacity = c(opacity, 1, 0.05, 1); m.emission = c3(emission, .zero); m.emissionStrength = c(emissionStrength, 0, 0, 8)
        if style == .glass { m.opacity = min(m.opacity, 0.85) }
        return m
    }
    /// Needs sorting with other transparent things (and costs more GPU).
    var transparent: Bool { clamped.opacity < 0.999 }

    static func preset(_ style: Style, color: SIMD3<Float>) -> CharacterMaterialProfile {
        switch style {
        case .pbr: CharacterMaterialProfile(baseColor: color, metallic: 0, roughness: 0.55, style: .pbr)
        case .oilPaint: CharacterMaterialProfile(baseColor: color, metallic: 0, roughness: 0.95, style: .oilPaint)
        case .pixel: CharacterMaterialProfile(baseColor: color, metallic: 0, roughness: 1, style: .pixel)
        case .toon: CharacterMaterialProfile(baseColor: color, metallic: 0, roughness: 0.8, style: .toon)
        case .glass: CharacterMaterialProfile(baseColor: color, metallic: 0.1, roughness: 0.05, opacity: 0.45, style: .glass)
        case .energy: CharacterMaterialProfile(baseColor: color, metallic: 0, roughness: 0.3, opacity: 0.9, emission: color, emissionStrength: 2.5, style: .energy)
        }
    }
}

enum OutfitSlot: String, Codable, CaseIterable, Sendable {
    case hair, top, bottom, shoes, gloves
    var title: String {
        switch self {
        case .hair: L10n.t("头发", "Hair"); case .top: L10n.t("上衣", "Top"); case .bottom: L10n.t("下装", "Bottom")
        case .shoes: L10n.t("鞋子", "Shoes"); case .gloves: L10n.t("手套", "Gloves")
        }
    }
}

struct OutfitPiece: Codable, Equatable, Identifiable, Sendable {
    enum Style: String, Codable, CaseIterable, Sendable {
        case shortHair, longHair, shirt, longSleeve, armor, shorts, trousers, boots, sneakers, gloves
    }
    var id: String
    var slot: OutfitSlot
    var style: Style
    var name: String
    var material: CharacterMaterialProfile
    /// How far the shell stands off the skin, metres.
    var thickness: Float = 0.01

    static let catalog: [OutfitPiece] = [
        OutfitPiece(id: "hair.short", slot: .hair, style: .shortHair, name: L10n.t("短发", "Short Hair"), material: .preset(.toon, color: SIMD3(0.18, 0.12, 0.09)), thickness: 0.014),
        OutfitPiece(id: "hair.long", slot: .hair, style: .longHair, name: L10n.t("长发", "Long Hair"), material: .preset(.toon, color: SIMD3(0.55, 0.36, 0.2)), thickness: 0.018),
        OutfitPiece(id: "top.shirt", slot: .top, style: .shirt, name: L10n.t("短袖上衣", "T-Shirt"), material: .preset(.pbr, color: SIMD3(0.25, 0.45, 0.8)), thickness: 0.008),
        OutfitPiece(id: "top.longSleeve", slot: .top, style: .longSleeve, name: L10n.t("长袖外套", "Long-Sleeve Jacket"), material: .preset(.pbr, color: SIMD3(0.55, 0.15, 0.2)), thickness: 0.012),
        OutfitPiece(id: "top.armor", slot: .top, style: .armor, name: L10n.t("胸甲", "Breastplate"), material: CharacterMaterialProfile(baseColor: SIMD3(0.7, 0.72, 0.78), metallic: 0.9, roughness: 0.3), thickness: 0.022),
        OutfitPiece(id: "bottom.shorts", slot: .bottom, style: .shorts, name: L10n.t("短裤", "Shorts"), material: .preset(.pbr, color: SIMD3(0.2, 0.2, 0.25)), thickness: 0.008),
        OutfitPiece(id: "bottom.trousers", slot: .bottom, style: .trousers, name: L10n.t("长裤", "Trousers"), material: .preset(.pbr, color: SIMD3(0.15, 0.17, 0.3)), thickness: 0.009),
        OutfitPiece(id: "shoes.boots", slot: .shoes, style: .boots, name: L10n.t("靴子", "Boots"), material: .preset(.pbr, color: SIMD3(0.3, 0.2, 0.12)), thickness: 0.014),
        OutfitPiece(id: "shoes.sneakers", slot: .shoes, style: .sneakers, name: L10n.t("运动鞋", "Sneakers"), material: .preset(.toon, color: SIMD3(0.92, 0.92, 0.95)), thickness: 0.012),
        OutfitPiece(id: "gloves.leather", slot: .gloves, style: .gloves, name: L10n.t("手套", "Gloves"), material: .preset(.pbr, color: SIMD3(0.25, 0.15, 0.1)), thickness: 0.004),
    ]
    static func find(_ id: String) -> OutfitPiece? { catalog.first { $0.id == id } }
}

enum EquipmentSlot: String, Codable, CaseIterable, Sendable {
    case weapon, shield, back
    var title: String { switch self { case .weapon: L10n.t("武器", "Weapon"); case .shield: L10n.t("盾牌", "Shield"); case .back: L10n.t("背部", "Back") } }
    /// The joint the item rides on.
    var joint: String { switch self { case .weapon: "rightHand"; case .shield: "leftHand"; case .back: "chest" } }
}

struct EquipmentItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case sword, axe, staff, shield, quiver }
    var id: String
    var slot: EquipmentSlot
    var kind: Kind
    var name: String
    var material: CharacterMaterialProfile
    /// Overall length, metres.
    var length: Float

    static let catalog: [EquipmentItem] = [
        EquipmentItem(id: "weapon.sword", slot: .weapon, kind: .sword, name: L10n.t("月刃长剑", "Moon Blade"), material: CharacterMaterialProfile(baseColor: SIMD3(0.82, 0.86, 0.95), metallic: 0.95, roughness: 0.2), length: 0.95),
        EquipmentItem(id: "weapon.axe", slot: .weapon, kind: .axe, name: L10n.t("战斧", "Battle Axe"), material: CharacterMaterialProfile(baseColor: SIMD3(0.6, 0.6, 0.62), metallic: 0.85, roughness: 0.35), length: 0.8),
        EquipmentItem(id: "weapon.staff", slot: .weapon, kind: .staff, name: L10n.t("星光法杖", "Starlight Staff"), material: .preset(.energy, color: SIMD3(0.55, 0.75, 1)), length: 1.4),
        EquipmentItem(id: "shield.round", slot: .shield, kind: .shield, name: L10n.t("圆盾", "Round Shield"), material: CharacterMaterialProfile(baseColor: SIMD3(0.45, 0.3, 0.18), metallic: 0.3, roughness: 0.6), length: 0.6),
        EquipmentItem(id: "back.quiver", slot: .back, kind: .quiver, name: L10n.t("箭袋", "Quiver"), material: .preset(.pbr, color: SIMD3(0.4, 0.25, 0.12)), length: 0.6),
    ]
    static func find(_ id: String) -> EquipmentItem? { catalog.first { $0.id == id } }
}

/// v1.92: a painted skin for any base body: the photo measurements (front
/// and, when there is one, back) and the texture atlas made from them (front
/// on the left half, back on the right). The body is repainted from these for
/// every shape and level of detail, so one skin fits every base.
struct CharacterSkin: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case photo, video, sheet, multiView
        var title: String {
            switch self { case .photo: L10n.t("照片", "Photo"); case .video: L10n.t("视频", "Video"); case .sheet: L10n.t("设定图", "Character sheet"); case .multiView: L10n.t("多张照片", "Several photos") }
        }
    }
    var source: Source
    var front: BodyPhoto
    var back: BodyPhoto?
    /// Atlas file in the character package (Textures/).
    var atlas = "skin.jpg"
}

/// The whole look: body shape, skin material, outfit and equipment.
struct CharacterAppearance: Codable, Equatable, Sendable {
    /// v1.92: the base body this character starts from (BaseBodyCatalog id; nil = the neutral mannequin).
    var base: String? = nil
    var shape = HumanShape.standard
    var skin = CharacterMaterialProfile.preset(.pbr, color: SIMD3(0.86, 0.72, 0.62))
    var outfit: [String] = []
    var equipment: [String] = []
    /// v1.92: a painted skin (photo, video frame or character sheet); nil = the plain material.
    var painted: CharacterSkin? = nil
    /// v1.93: clothes, hair or shoes from an AI 3D / imported model, fitted on the body (nil in older saves).
    var garments: [CustomGarment]? = nil

    var garmentList: [CustomGarment] { garments ?? [] }
    /// A fitted garment takes its slot: same-slot garments and built-in pieces come off; a full outfit replaces everything.
    mutating func wear(_ garment: CustomGarment) {
        var list = garmentList.filter { $0.id != garment.id && $0.slot != garment.slot && $0.slot != .full && garment.slot != .full }
        list.append(garment)
        garments = list
        let freed = garment.slot.replaces
        outfit.removeAll { OutfitPiece.find($0).map { freed.contains($0.slot) } ?? false }
    }
    mutating func takeOff(garment id: String) {
        garments = garmentList.filter { $0.id != id }
        if garments?.isEmpty == true { garments = nil }
    }

    var pieces: [OutfitPiece] { outfit.compactMap(OutfitPiece.find) }
    var items: [EquipmentItem] { equipment.compactMap(EquipmentItem.find) }

    /// Wearing a piece replaces whatever was in its slot.
    mutating func wear(_ id: String) {
        guard let piece = OutfitPiece.find(id) else { return }
        outfit.removeAll { OutfitPiece.find($0)?.slot == piece.slot }
        outfit.append(id)
        // v1.93: a built-in piece takes the slot back from a fitted garment.
        if garments != nil {
            garments = garmentList.filter { $0.slot != .full && !$0.slot.replaces.contains(piece.slot) }
            if garments?.isEmpty == true { garments = nil }
        }
    }
    mutating func equip(_ id: String) {
        guard let item = EquipmentItem.find(id) else { return }
        equipment.removeAll { EquipmentItem.find($0)?.slot == item.slot }
        equipment.append(id)
    }
    /// Starts over from a base body: its shape and skin colour (outfit and gear stay).
    mutating func use(_ entry: BaseBodyEntry) {
        base = entry.id
        if let shape = entry.shape { self.shape = shape }
        skin.baseColor = entry.skin
    }
    mutating func remove(_ id: String) { outfit.removeAll { $0 == id }; equipment.removeAll { $0 == id } }

    static let presets: [(String, CharacterAppearance)] = [
        (L10n.t("标准剑士", "Swordsman"), CharacterAppearance(shape: .standard, outfit: ["hair.short", "top.shirt", "bottom.trousers", "shoes.boots"], equipment: ["weapon.sword"])),
        (L10n.t("高个骑士", "Tall Knight"), CharacterAppearance(shape: .tall, skin: .preset(.pbr, color: SIMD3(0.62, 0.45, 0.35)),
                                                             outfit: ["hair.short", "top.armor", "bottom.trousers", "shoes.boots", "gloves.leather"], equipment: ["weapon.axe", "shield.round"])),
        (L10n.t("Q 版法师", "Chibi Mage"), CharacterAppearance(shape: .chibi, skin: .preset(.toon, color: SIMD3(0.98, 0.84, 0.76)),
                                                            outfit: ["hair.long", "top.longSleeve", "bottom.shorts", "shoes.sneakers"], equipment: ["weapon.staff", "back.quiver"])),
    ]
}

/// A mesh with weights on the body's skeleton (an outfit layer).
struct SkinnedPart: Sendable {
    var mesh: GeneratedMesh
    var skin: SkinInfluences
}

enum OutfitBuilder {
    /// The shell for a piece on a body: the body triangles the piece covers,
    /// lifted along the normals, with the body's weights.
    static func build(_ piece: OutfitPiece, on body: HumanBody) -> SkinnedPart? {
        let m = body.mesh, s = body.skeleton
        func y(_ tag: JointTag) -> Float { s.position(tag)?.y ?? 0 }
        let headY = y(.head), crown = y(.headEnd), headZ = s.position(.head)?.z ?? 0
        let ankle = y(.rightFoot), knee = y(.rightShin)
        func strongest(_ v: Int) -> String {
            var best = 0
            for k in 1..<4 where body.skin.joints[v * 4 + k] != 255 && body.skin.weights[v * 4 + k] > body.skin.weights[v * 4 + best] { best = k }
            let j = Int(body.skin.joints[v * 4 + best])
            return j < s.joints.count ? s.joints[j].jointID : ""
        }
        func covers(_ v: Int) -> Bool {
            let id = strongest(v), p = SIMD3(m.positions[v * 3], m.positions[v * 3 + 1], m.positions[v * 3 + 2])
            let n = SIMD3(m.normals[v * 3], m.normals[v * 3 + 1], m.normals[v * 3 + 2])
            func side(_ names: [String]) -> Bool { names.contains { id == "right" + $0 || id == "left" + $0 } }
            switch piece.style {
            case .shortHair, .longHair:
                guard id == "head" || id == "neck" && piece.style == .longHair else { return false }
                let top = p.y > headY + (crown - headY) * 0.42
                let back = p.z < headZ - 0.01 && p.y > headY + (crown - headY) * (piece.style == .longHair ? -0.1 : 0.15)
                // Leave the face open: no forward-facing skin below the hairline.
                return (top || back) && !(n.z > 0.55 && p.y < headY + (crown - headY) * 0.6)
            case .shirt, .armor: return ["spine", "spine1", "chest"].contains(id) || side(["Clavicle"]) || (piece.style == .shirt && side(["UpperArm"])) || (id == "pelvis" && p.y > y(.pelvis))
            case .longSleeve: return ["spine", "spine1", "chest"].contains(id) || side(["Clavicle", "UpperArm", "Forearm"]) || (id == "pelvis" && p.y > y(.pelvis))
            case .shorts: return id == "pelvis" || (side(["Thigh"]) && p.y > (knee + y(.rightThigh)) / 2)
            case .trousers: return id == "pelvis" || side(["Thigh", "Shin"]) && p.y > ankle + 0.02
            case .boots: return side(["Foot", "Toe"]) || side(["Shin"]) && p.y < ankle + (knee - ankle) * 0.45
            case .sneakers: return side(["Foot", "Toe"]) || side(["Shin"]) && p.y < ankle + 0.03
            case .gloves: return side(["Hand"]) || id.hasPrefix("ext.right") && id.contains("Finger") || id.hasPrefix("ext.left") && id.contains("Finger")
            }
        }
        let covered = (0..<m.vertexCount).map(covers)
        var map = [Int](repeating: -1, count: m.vertexCount)
        var out = GeneratedMesh(), joints: [UInt8] = [], weights: [Float] = []
        let lift = max(0.001, piece.thickness) * max(0.4, body.shape.height / 1.75)
        for t in 0..<m.triangleCount {
            let tri = (0..<3).map { Int(m.indices[t * 3 + $0]) }
            guard tri.allSatisfy({ covered[$0] }) else { continue }
            for v in tri where map[v] < 0 {
                map[v] = out.vertexCount
                let n = SIMD3(m.normals[v * 3], m.normals[v * 3 + 1], m.normals[v * 3 + 2])
                let p = SIMD3(m.positions[v * 3], m.positions[v * 3 + 1], m.positions[v * 3 + 2]) + n * lift
                out.positions += [p.x, p.y, p.z]; out.normals += [n.x, n.y, n.z]
                out.uvs += [m.uvs[v * 2], m.uvs[v * 2 + 1]]
                joints += body.skin.joints[v * 4 ..< v * 4 + 4]; weights += body.skin.weights[v * 4 ..< v * 4 + 4]
            }
            out.indices += tri.map { UInt32(map[$0]) }
        }
        guard out.triangleCount > 0 else { return nil }
        return SkinnedPart(mesh: out, skin: SkinInfluences(joints: joints, weights: weights))
    }
}

enum EquipmentBuilder {
    /// The item's own mesh: grip at the origin, along +y (blade, haft, shaft),
    /// metres. Simple solid shapes; props, not the body.
    static func mesh(_ item: EquipmentItem) -> GeneratedMesh {
        var m = GeneratedMesh()
        func box(_ c: SIMD3<Float>, _ h: SIMD3<Float>) {
            let base = UInt32(m.vertexCount)
            let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
                (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
                (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
                (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
            ]
            for (f, (n, u, v)) in faces.enumerated() {
                let o = c + n * h
                for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                    let p = o + u * (a * cDot(u, h).magnitude) + v * (b * cDot(v, h).magnitude)
                    m.positions += [p.x, p.y, p.z]; m.normals += [n.x, n.y, n.z]; m.uvs += [(a + 1) / 2, (b + 1) / 2]
                }
                let k = base + UInt32(f * 4)
                m.indices += [k, k + 1, k + 2, k, k + 2, k + 3]
            }
        }
        func cylinder(_ y0: Float, _ y1: Float, _ r: Float, sides: Int = 10) {
            let base = UInt32(m.vertexCount)
            for i in 0...sides {
                let a = Float(i) / Float(sides) * 2 * .pi, n = SIMD3<Float>(cos(a), 0, sin(a))
                for y in [y0, y1] { m.positions += [n.x * r, y, n.z * r]; m.normals += [n.x, 0, n.z]; m.uvs += [Float(i) / Float(sides), y == y0 ? 0 : 1] }
            }
            for i in 0..<UInt32(sides) { let k = base + i * 2; m.indices += [k, k + 1, k + 3, k, k + 3, k + 2] }
        }
        let L = max(0.2, item.length)
        switch item.kind {
        case .sword:
            cylinder(-0.06, 0.12, 0.016)                                   // grip
            box(SIMD3(0, 0.13, 0), SIMD3(0.09, 0.012, 0.02))              // guard
            box(SIMD3(0, 0.14 + (L - 0.14) / 2, 0), SIMD3(0.022, (L - 0.14) / 2, 0.004))   // blade
        case .axe:
            cylinder(-0.08, L, 0.018)
            box(SIMD3(0.07, L - 0.12, 0), SIMD3(0.07, 0.09, 0.006))
        case .staff:
            cylinder(-0.5 * L, 0.5 * L, 0.018)
            box(SIMD3(0, 0.5 * L + 0.05, 0), SIMD3(0.045, 0.045, 0.045))
        case .shield:
            cylinder(-0.012, 0.012, L / 2, sides: 20)
        case .quiver:
            cylinder(-L / 2, L / 2, 0.05)
        }
        return m
    }

    /// Where the item sits relative to its joint (bind frame of the T-pose):
    /// the sword's blade points forward out of the fist, the shield faces out
    /// from the forearm, the quiver hangs on the back.
    static func offset(_ item: EquipmentItem, skeleton: SkeletonDefinition) -> RigXform {
        let hand = skeleton.position(.rightHand) ?? .zero, tip = skeleton.position(.rightHandEnd) ?? hand
        let palm = (tip - hand) * 0.45
        switch item.slot {
        case .weapon:
            // +y (blade) → +z (forward from the fist), at the palm.
            var x = Quat(axis: SIMD3(1, 0, 0), angle: .pi / 2).xform
            x.tx = palm.x; x.ty = palm.y - 0.02; x.tz = palm.z
            return x
        case .shield:
            // The disc's axis (+y) outward along the forearm's back (−y in the T-pose palm-down hand).
            var x = Quat(axis: SIMD3(0, 0, 1), angle: .pi).xform
            x.tx = -palm.x * 0.2; x.ty = -0.05; x.tz = 0
            return x
        case .back:
            var x = Quat(axis: SIMD3(0, 0, 1), angle: 0.4).xform
            x.tz = -0.16; x.ty = 0.05
            return x
        }
    }

    /// The item's model-space transform in a pose (follows its joint).
    static func transform(_ item: EquipmentItem, skeleton: SkeletonDefinition, world: [RigXform]) -> RigXform? {
        guard let j = skeleton.index(item.slot.joint), j < world.count else { return nil }
        // Joint world transform without the bind offset baked in: rotation from the pose, origin at the joint.
        return world[j] * offset(item, skeleton: skeleton)
    }
}
