import Foundation

// v1.74: text → full 360° 3D character. A description ("a red warrior with
// a sword") becomes a CharacterSpec — chosen by Claude (online, the user's
// key) or by local keyword rules (offline) — and the spec is built into a
// closed, coloured humanoid mesh on the phone from rounded primitives,
// standing in an A-pose so the automatic rig can separate the limbs.
// Pure Swift (tested on Linux).

struct CharacterSpec: Codable, Equatable, Sendable {
    enum Build: String, Codable, CaseIterable, Sendable { case slim, normal, heavy }
    enum Hair: String, Codable, CaseIterable, Sendable { case none, short, long, spiky, bun }
    enum Outfit: String, Codable, CaseIterable, Sendable { case casual, armor, robe, dress, ninja, robot }
    enum Accessory: String, Codable, CaseIterable, Sendable {
        case helmet, crown, wizardHat, cape, sword, shield, staff, bow, backpack, mask, shoulderPads, belt, horns, tail
    }
    var name: String
    var height: Float = 1.7
    var build = Build.normal
    /// Head size relative to normal (0.8…1.6; chibi characters are larger).
    var headScale: Float = 1
    var hair = Hair.short
    var outfit = Outfit.casual
    var accessories: [Accessory] = []
    /// Hex colours (RRGGBB).
    var skin = "F1C7A5"
    var hairColor = "3B2A20"
    var top = "4A78C2"
    var bottom = "2E3A4F"
    var shoes = "3A2C24"
    var accent = "D9B44A"
    var metal = "B8BEC8"

    var clamped: CharacterSpec {
        var s = self
        s.height = min(2.4, max(0.8, height.isFinite ? height : 1.7))
        s.headScale = min(1.6, max(0.8, headScale.isFinite ? headScale : 1))
        s.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if s.name.isEmpty { s.name = L10n.t("AI 角色", "AI Character") }
        var seen = Set<Accessory>()
        s.accessories = accessories.filter { seen.insert($0).inserted }
        for path in [\CharacterSpec.skin, \.hairColor, \.top, \.bottom, \.shoes, \.accent, \.metal] {
            let hex = s[keyPath: path].trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
            s[keyPath: path] = hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? hex : CharacterSpec(name: "")[keyPath: path]
        }
        return s
    }
}

// MARK: Local keyword rules (offline; not AI)

enum CharacterKeywords {
    static func spec(for prompt: String) -> CharacterSpec {
        let p = prompt.lowercased()
        func has(_ words: String...) -> Bool { words.contains { p.contains($0) } }
        var s = CharacterSpec(name: prompt)
        if has("战士", "warrior", "勇士", "fighter") { s.outfit = .armor; s.accessories += [.helmet, .sword, .shield, .shoulderPads, .belt]; s.top = "8C2F2F"; s.bottom = "4A4A52" }
        if has("骑士", "knight", "圣骑") { s.outfit = .armor; s.accessories += [.helmet, .sword, .shield, .cape, .shoulderPads]; s.top = "C8CDD6"; s.accent = "2F4F9E" }
        if has("法师", "巫师", "mage", "wizard", "魔法") { s.outfit = .robe; s.accessories += [.wizardHat, .staff]; s.top = "5B3A8C"; s.bottom = "3E2763"; s.hair = .long }
        if has("弓箭手", "射手", "archer", "猎人", "hunter") { s.outfit = .casual; s.accessories += [.bow, .backpack, .belt]; s.top = "3F6B3A"; s.bottom = "5A4632" }
        if has("忍者", "ninja", "刺客", "assassin") { s.outfit = .ninja; s.accessories += [.mask, .sword, .belt]; s.top = "22242B"; s.bottom = "22242B"; s.build = .slim }
        if has("公主", "princess", "皇后", "queen") { s.outfit = .dress; s.accessories += [.crown]; s.hair = .long; s.top = "E58FB5"; s.bottom = "E58FB5" }
        if has("国王", "king", "王子", "prince") { s.accessories += [.crown, .cape]; s.top = "7A1F2B"; s.accent = "E2B93B" }
        if has("机器人", "robot", "机甲", "mech") { s.outfit = .robot; s.hair = .none; s.skin = "9AA3AE"; s.top = "6D7884"; s.bottom = "4B535C"; s.build = .heavy }
        if has("恶魔", "demon", "魔王", "devil") { s.accessories += [.horns, .tail, .cape]; s.skin = "B5483F"; s.top = "2B1A1A" }
        if has("盗贼", "thief", "rogue") { s.outfit = .ninja; s.accessories += [.mask, .backpack]; s.top = "4B3A2E" }
        if has("小孩", "孩子", "child", "kid", "q版", "chibi", "可爱", "cute") { s.headScale = 1.45; s.height = 1.2 }
        if has("胖", "强壮", "壮", "heavy", "strong", "big") { s.build = .heavy }
        if has("瘦", "苗条", "slim", "thin") { s.build = .slim }
        if has("长发", "long hair") { s.hair = .long }
        if has("短发", "short hair") { s.hair = .short }
        if has("光头", "bald") { s.hair = .none }
        if has("披风", "斗篷", "cape", "cloak") { s.accessories.append(.cape) }
        if has("剑", "sword", "刀", "blade") { s.accessories.append(.sword) }
        if has("盾", "shield") { s.accessories.append(.shield) }
        if has("法杖", "权杖", "staff", "wand") { s.accessories.append(.staff) }
        if has("弓", "bow") && !has("弓箭手") { s.accessories.append(.bow) }
        if has("头盔", "helmet") { s.accessories.append(.helmet) }
        if has("背包", "backpack") { s.accessories.append(.backpack) }
        let colours: [(String, String)] = [("红", "B83A3A"), ("red", "B83A3A"), ("蓝", "3A62B8"), ("blue", "3A62B8"), ("绿", "3E8A4A"), ("green", "3E8A4A"),
                                           ("黑", "24262C"), ("black", "24262C"), ("白", "E8E8EC"), ("white", "E8E8EC"), ("金", "D6A93A"), ("gold", "D6A93A"),
                                           ("紫", "6A3F9C"), ("purple", "6A3F9C"), ("粉", "E58FB5"), ("pink", "E58FB5"), ("橙", "E0782E"), ("orange", "E0782E"),
                                           ("银", "BFC5CE"), ("silver", "BFC5CE"), ("黄", "E3C43A"), ("yellow", "E3C43A")]
        if let colour = colours.first(where: { p.contains($0.0) }) { s.top = colour.1 }
        if has("金发", "blonde") { s.hairColor = "E2C46A" }
        if has("白发", "银发", "white hair", "silver hair") { s.hairColor = "E4E4EA" }
        if has("红发", "red hair") { s.hairColor = "A8382A" }
        return s.clamped
    }
}

// MARK: Mesh

struct ColouredMesh: Sendable {
    var mesh: GeneratedMesh
    /// Palette texture (RGBA, 8 cells per row) the UVs point into.
    var palette: RasterImage
    /// Exact rig: the builder knows where every joint is and which bone
    /// each part belongs to (no estimation needed).
    var skeleton: SkeletonDefinition
    var skin: SkinInfluences
}

enum ProceduralCharacterBuilder {
    enum Slot: Int, CaseIterable { case skin, hair, top, bottom, shoes, accent, metal, dark }

    /// Rigid binding to one joint.
    static func rigid(_ j: JointTag) -> (SIMD3<Float>) -> [(JointTag, Float)] { { _ in [(j, 1)] } }
    /// A limb segment a → b owned by `joint`, blending into `parent` near a
    /// and into `child` near b (smooth bends at shoulders, elbows, knees).
    static func limb(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ joint: JointTag, parent: JointTag?, child: JointTag?) -> (SIMD3<Float>) -> [(JointTag, Float)] {
        { p in
            let ab = b - a, l2 = max(1e-8, (ab * ab).sum())
            let t = min(1, max(0, ((p - a) * ab).sum() / l2))
            var out: [(JointTag, Float)] = []
            var own: Float = 1
            if let child, t > 0.75 { let w = 0.5 * smooth((t - 0.75) / 0.25); out.append((child, w)); own -= w }
            if let parent, t < 0.2 { let w = 0.5 * smooth((0.2 - t) / 0.2); out.append((parent, w)); own -= w }
            out.append((joint, own))
            return out
        }
    }
    /// Spine chain by height.
    static func spine(_ joints: [(JointTag, Float)]) -> (SIMD3<Float>) -> [(JointTag, Float)] {
        { p in
            guard let first = joints.first, let last = joints.last else { return [(.chest, 1)] }
            if p.y <= first.1 { return [(first.0, 1)] }
            if p.y >= last.1 { return [(last.0, 1)] }
            for (a, b) in zip(joints, joints.dropFirst()) where p.y <= b.1 {
                let t = smooth((p.y - a.1) / max(1e-5, b.1 - a.1))
                return [(a.0, 1 - t), (b.0, t)]
            }
            return [(last.0, 1)]
        }
    }
    static func smooth(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

    static func build(_ input: CharacterSpec) -> ColouredMesh {
        let s = input.clamped
        var b = Builder()
        let k: Float = s.build == .slim ? 0.85 : s.build == .heavy ? 1.25 : 1
        let robot = s.outfit == .robot
        // Proportions for a 1.7 m body; scaled to the spec height at the end.
        let hipY: Float = 0.86, torsoTop: Float = 1.38, shoulderY: Float = 1.34
        let hipHalf: Float = 0.1 * k, legR: Float = 0.065 * k, shoulderHalf: Float = 0.19 * k, armR: Float = 0.045 * k
        let headR: Float = 0.12 * s.headScale
        let headY = torsoTop + 0.08 + headR
        var joints: [JointTag: SIMD3<Float>] = [:]
        let spineChain: [(JointTag, Float)] = [(.pelvis, hipY + 0.03), (.spine, 1.0), (.spine1, 1.12), (.chest, 1.25), (.neck, torsoTop - 0.02)]
        for (tag, y) in spineChain { joints[tag] = [0, y, 0] }
        joints[.head] = [0, headY - headR * 0.55, 0]
        var top: Float = headY + headR

        // Legs and feet.
        for side: Float in [-1, 1] {
            let pre = side < 0 ? "right" : "left"
            func tag(_ n: String) -> JointTag { JointTag(rawValue: pre + n)! }
            let hip = SIMD3<Float>(side * hipHalf, hipY - 0.04, 0), knee = SIMD3<Float>(side * hipHalf, 0.47, 0.01), ankle = SIMD3<Float>(side * hipHalf, 0.09, 0)
            joints[tag("Thigh")] = hip; joints[tag("Shin")] = knee; joints[tag("Foot")] = ankle
            joints[tag("Toe")] = [side * hipHalf, 0.03, 0.1]; joints[tag("ToeEnd")] = [side * hipHalf, 0.02, 0.175]
            b.bind = limb(hip, knee, tag("Thigh"), parent: .pelvis, child: tag("Shin"))
            if robot { b.box(center: (hip + knee) / 2, size: [legR * 2.1, rigLength(hip - knee) + 0.02, legR * 2.1], .bottom) }
            else { b.capsule(hip, knee, legR, .bottom) }
            b.bind = limb(knee, ankle, tag("Shin"), parent: tag("Thigh"), child: tag("Foot"))
            if robot { b.box(center: (knee + ankle) / 2, size: [legR * 2.1, rigLength(knee - ankle), legR * 2.1], .bottom) }
            else { b.capsule(knee, ankle, legR * 0.85, s.outfit == .armor ? .metal : .bottom) }
            b.bind = rigid(tag("Foot"))
            b.box(center: [side * hipHalf, 0.045, 0.045], size: [legR * 1.9, 0.09, 0.26], .shoes)
        }
        // Pelvis, torso, neck, head.
        b.bind = spine(spineChain)
        if robot {
            b.box(center: [0, hipY + 0.02, 0], size: [hipHalf * 2 + legR * 2.4, 0.16, 0.22 * k], .bottom)
            b.box(center: [0, (hipY + torsoTop) / 2 + 0.05, 0], size: [shoulderHalf * 2.2, torsoTop - hipY - 0.06, 0.26 * k], .top)
        } else {
            b.ellipsoid([0, hipY + 0.03, 0], [hipHalf + legR * 1.15, 0.11, 0.12 * k], .bottom)
            b.ellipsoid([0, (hipY + torsoTop) / 2 + 0.04, 0], [shoulderHalf * 1.02, (torsoTop - hipY) / 2 + 0.02, 0.13 * k], .top)
        }
        b.bind = limb([0, torsoTop - 0.04, 0], [0, headY - headR * 0.7, 0], .neck, parent: .chest, child: .head)
        b.capsule([0, torsoTop - 0.04, 0], [0, headY - headR * 0.7, 0], 0.045, .skin)
        b.bind = rigid(.head)
        if robot { b.box(center: [0, headY, 0], size: [headR * 1.9, headR * 1.8, headR * 1.8], .skin); b.box(center: [0, headY + 0.01, headR * 0.92], size: [headR * 1.4, headR * 0.35, 0.02], .dark) }
        else {
            b.ellipsoid([0, headY, 0], [headR * 0.92, headR, headR * 0.95], .skin)
            for side: Float in [-1, 1] { b.ellipsoid([side * headR * 0.35, headY + headR * 0.08, headR * 0.86], [headR * 0.11, headR * 0.14, headR * 0.06], .dark) }
        }
        // Arms in an A-pose (about 22° out).
        let angle: Float = 22 * .pi / 180
        var hands: [SIMD3<Float>] = [], forearms: [SIMD3<Float>] = []
        for side: Float in [-1, 1] {
            let pre = side < 0 ? "right" : "left"
            func tag(_ n: String) -> JointTag { JointTag(rawValue: pre + n)! }
            let shoulder = SIMD3<Float>(side * (shoulderHalf + armR * 0.6), shoulderY - 0.02, 0)
            let dir = SIMD3<Float>(side * sin(angle), -cos(angle), 0)
            let elbow = shoulder + dir * 0.29, wrist = elbow + dir * 0.26, hand = wrist + dir * 0.07
            joints[tag("Clavicle")] = [side * 0.03, shoulderY - 0.03, 0]
            joints[tag("UpperArm")] = shoulder; joints[tag("Forearm")] = elbow; joints[tag("Hand")] = wrist; joints[tag("HandEnd")] = wrist + dir * 0.14
            let sleeve: Slot = s.outfit == .armor || robot ? .metal : s.outfit == .casual ? .skin : .top
            b.bind = limb(shoulder, elbow, tag("UpperArm"), parent: tag("Clavicle"), child: tag("Forearm"))
            if robot { b.box(center: (shoulder + elbow) / 2, size: [armR * 2.2, 0.3, armR * 2.2], .metal, tilt: side * angle) } else { b.capsule(shoulder, elbow, armR, .top) }
            b.bind = limb(elbow, wrist, tag("Forearm"), parent: tag("UpperArm"), child: tag("Hand"))
            if robot { b.box(center: (elbow + wrist) / 2, size: [armR * 2.1, 0.27, armR * 2.1], .metal, tilt: side * angle) } else { b.capsule(elbow, wrist, armR * 0.9, sleeve) }
            b.bind = rigid(tag("Hand"))
            b.ellipsoid(hand, [armR * 0.95, 0.06, armR * 0.8], robot ? .metal : .skin)
            hands.append(hand); forearms.append((elbow + wrist) / 2)
        }
        let rightHand = hands[0], leftHand = hands[1]

        // Clothes: skirts follow the pelvis at the top and the legs below.
        switch s.outfit {
        case .robe, .dress:
            let bottomY: Float = s.outfit == .dress ? 0.42 : 0.16
            b.bind = { p in
                let t = smooth((hipY + 0.1 - p.y) / max(0.05, hipY + 0.1 - bottomY)) * 0.7
                return [(.pelvis, 1 - t), (p.x < 0 ? .rightThigh : .leftThigh, t)]
            }
            b.frustum(bottomCenter: [0, bottomY, 0], top: hipY + 0.12, bottomRadius: 0.27 * k, topRadius: hipHalf + legR * 1.3, .bottom)
        case .ninja:
            b.bind = rigid(.head)
            b.ellipsoid([0, headY + headR * 0.15, -headR * 0.05], [headR * 1.0, headR * 0.75, headR * 1.0], .top)
        default: break
        }

        // Hair.
        b.bind = rigid(.head)
        if !robot && !s.accessories.contains(.helmet) {
            switch s.hair {
            case .none: break
            case .short: b.ellipsoid([0, headY + headR * 0.22, -headR * 0.1], [headR * 1.0, headR * 0.82, headR * 0.98], .hair)
            case .long:
                b.ellipsoid([0, headY + headR * 0.22, -headR * 0.1], [headR * 1.0, headR * 0.82, headR * 0.98], .hair)
                b.box(center: [0, headY - headR * 0.9, -headR * 0.55], size: [headR * 1.8, headR * 2.0, headR * 0.5], .hair)
            case .spiky:
                b.ellipsoid([0, headY + headR * 0.25, -headR * 0.1], [headR * 0.98, headR * 0.8, headR * 0.96], .hair)
                for (dx, dz) in [(-0.5, 0.2), (0.5, 0.2), (0, 0.4), (-0.4, -0.4), (0.4, -0.4), (0, -0.1)] as [(Float, Float)] {
                    b.cone(base: [dx * headR, headY + headR * 0.75, dz * headR], height: headR * 0.6, radius: headR * 0.25, .hair)
                }
                top = max(top, headY + headR * 1.35)
            case .bun:
                b.ellipsoid([0, headY + headR * 0.22, -headR * 0.1], [headR * 1.0, headR * 0.82, headR * 0.98], .hair)
                b.ellipsoid([0, headY + headR * 1.0, -headR * 0.3], [headR * 0.4, headR * 0.35, headR * 0.4], .hair)
                top = max(top, headY + headR * 1.35)
            }
        }

        // Accessories, each bound to the bone that carries it.
        for a in s.accessories {
            switch a {
            case .helmet:
                b.bind = rigid(.head)
                b.ellipsoid([0, headY + headR * 0.15, 0], [headR * 1.12, headR * 0.95, headR * 1.1], .metal)
                b.box(center: [0, headY + headR * 1.05, -headR * 0.1], size: [headR * 0.18, headR * 0.35, headR * 1.2], .accent)
                top = max(top, headY + headR * 1.22)
            case .crown:
                b.bind = rigid(.head)
                for i in 0..<6 {
                    let t = Float(i) / 6 * 2 * .pi
                    b.cone(base: [sin(t) * headR * 0.6, headY + headR * 0.8, cos(t) * headR * 0.6], height: headR * 0.4, radius: headR * 0.14, .accent)
                }
                b.frustum(bottomCenter: [0, headY + headR * 0.72, 0], top: headY + headR * 0.86, bottomRadius: headR * 0.66, topRadius: headR * 0.66, .accent)
                top = max(top, headY + headR * 1.2)
            case .wizardHat:
                b.bind = rigid(.head)
                b.frustum(bottomCenter: [0, headY + headR * 0.6, 0], top: headY + headR * 0.66, bottomRadius: headR * 1.7, topRadius: headR * 1.7, .top)
                b.cone(base: [0, headY + headR * 0.66, 0], height: headR * 2.2, radius: headR * 0.95, .top)
                top = max(top, headY + headR * 2.86)
            case .cape:
                b.bind = spine([(.spine, 0.9), (.chest, 1.25)])
                b.box(center: [0, (shoulderY + 0.5) / 2, -0.17 * k], size: [shoulderHalf * 2.1, shoulderY - 0.5, 0.025], .accent)
            case .sword:
                b.bind = rigid(.rightHand)
                b.box(center: rightHand + [0, -0.02, 0.12], size: [0.03, 0.03, 0.12], .dark)
                b.box(center: rightHand + [0, -0.02, 0.2], size: [0.14, 0.025, 0.025], .accent)
                b.box(center: rightHand + [0, -0.02, 0.48], size: [0.05, 0.012, 0.52], .metal)
            case .shield:
                b.bind = rigid(.leftForearm)
                b.frustum(bottomCenter: forearms[1] + [0.06, 0, 0], top: 0, bottomRadius: 0.17, topRadius: 0.17, .metal, axis: 0, thickness: 0.03)
            case .staff:
                b.bind = rigid(.rightHand)
                b.capsule(rightHand + [0, -0.5, 0.02], rightHand + [0, 0.75, 0.02], 0.018, .hair)
                b.ellipsoid(rightHand + [0, 0.8, 0.02], [0.06, 0.06, 0.06], .accent)
            case .bow:
                b.bind = rigid(.leftHand)
                for i in 0..<6 {
                    let a0 = Float(i) / 6 * .pi - .pi / 2, a1 = Float(i + 1) / 6 * .pi - .pi / 2
                    b.capsule(leftHand + [0.02, sin(a0) * 0.45, cos(a0) * 0.12 + 0.02], leftHand + [0.02, sin(a1) * 0.45, cos(a1) * 0.12 + 0.02], 0.014, .hair)
                }
            case .backpack:
                b.bind = rigid(.chest)
                b.box(center: [0, shoulderY - 0.2, -0.17 * k], size: [0.28, 0.32, 0.12], .accent)
            case .mask:
                b.bind = rigid(.head)
                b.box(center: [0, headY - headR * 0.35, headR * 0.82], size: [headR * 1.5, headR * 0.6, 0.04], .dark)
            case .shoulderPads:
                for side: Float in [-1, 1] {
                    b.bind = rigid(side < 0 ? .rightUpperArm : .leftUpperArm)
                    b.ellipsoid([side * (shoulderHalf + 0.02), shoulderY + 0.02, 0], [0.09 * k, 0.06, 0.1 * k], .metal)
                }
            case .belt:
                b.bind = rigid(.pelvis)
                b.frustum(bottomCenter: [0, hipY + 0.08, 0], top: hipY + 0.13, bottomRadius: (hipHalf + legR * 1.2) * 1.05, topRadius: (hipHalf + legR * 1.2) * 1.05, .accent)
            case .horns:
                b.bind = rigid(.head)
                for side: Float in [-1, 1] { b.cone(base: [side * headR * 0.55, headY + headR * 0.6, 0], height: headR * 0.8, radius: headR * 0.2, .dark) }
            case .tail:
                b.bind = rigid(.pelvis)
                b.capsule([0, hipY, -0.12 * k], [0, 0.35, -0.42], 0.03, .skin)
            }
        }
        joints[.headEnd] = [0, top, 0]

        var mesh = b.mesh
        let scale = s.height / 1.7
        for i in 0..<mesh.positions.count { mesh.positions[i] *= scale }
        mesh.computeNormals()
        for key in joints.keys { joints[key]! *= scale }

        // Exact skeleton and weights.
        let estimate = JointEstimate(positions: joints, confidence: Dictionary(uniqueKeysWithValues: joints.keys.map { ($0, Float(1)) }),
                                     pose: .aPose, humanoid: 1, notes: [])
        let skeleton = SkeletonBuilder.build(estimate)
        var skin = SkinInfluences(count: mesh.vertexCount)
        for (v, list) in b.influences.enumerated() {
            var merged: [JointTag: Float] = [:]
            for (tag, w) in list where w > 1e-4 { merged[tag, default: 0] += w }
            let entries = merged.compactMap { e in skeleton.index(e.key).map { ($0, e.value) } }.sorted { $0.1 > $1.1 }.prefix(4)
            SkinWeightSolver.write(Array(entries), into: &skin, vertex: v)
        }
        return ColouredMesh(mesh: mesh, palette: palette(s), skeleton: skeleton, skin: skin)
    }

    /// 8×1 cells of 8 px; UV v measured from the bottom.
    static func palette(_ s: CharacterSpec) -> RasterImage {
        let colours = [s.skin, s.hairColor, s.top, s.bottom, s.shoes, s.accent, s.metal, "1C1C22"].map(rgb)
        var image = RasterImage(width: 64, height: 8)
        for y in 0..<8 { for x in 0..<64 {
            let c = colours[x / 8], o = (y * 64 + x) * 4
            image.rgba[o] = c[0]; image.rgba[o + 1] = c[1]; image.rgba[o + 2] = c[2]; image.rgba[o + 3] = 255
        } }
        return image
    }
    static func rgb(_ hex: String) -> [UInt8] {
        let v = UInt32(hex, radix: 16) ?? 0x808080
        return [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    /// Closed primitives with one palette UV each.
    struct Builder {
        var mesh = GeneratedMesh()
        /// Bones of the next primitives: a function from a point to joint weights.
        var bind: (SIMD3<Float>) -> [(JointTag, Float)] = { _ in [(.chest, 1)] }
        var influences: [[(JointTag, Float)]] = []
        private func uv(_ slot: Slot) -> (Float, Float) { ((Float(slot.rawValue) + 0.5) / 8, 0.5) }
        private mutating func add(_ points: [SIMD3<Float>], _ triangles: [UInt32], _ slot: Slot) {
            let base = UInt32(mesh.vertexCount), (u, v) = uv(slot)
            for p in points { mesh.positions += [p.x, p.y, p.z]; mesh.normals += [0, 0, 1]; mesh.uvs += [u, v]; influences.append(bind(p)) }
            mesh.indices += triangles.map { $0 + base }
        }
        /// Unit sphere rings (poles included), then mapped.
        private mutating func sphere(_ map: (SIMD3<Float>) -> SIMD3<Float>, _ slot: Slot, rings: Int = 10, segments: Int = 16) {
            var points: [SIMD3<Float>] = [map([0, 1, 0])]
            for r in 1..<rings {
                let phi = Float.pi * Float(r) / Float(rings)
                for sgm in 0..<segments {
                    let theta = 2 * Float.pi * Float(sgm) / Float(segments)
                    points.append(map([sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta)]))
                }
            }
            points.append(map([0, -1, 0]))
            var tris: [UInt32] = []
            let S = UInt32(segments), last = UInt32(points.count - 1)
            for sgm in 0..<S { tris += [0, 1 + sgm, 1 + (sgm + 1) % S] }
            for r in 0..<UInt32(rings - 2) {
                for sgm in 0..<S {
                    let a = 1 + r * S + sgm, b = 1 + r * S + (sgm + 1) % S, c = a + S, d = b + S
                    tris += [a, c, b, b, c, d]
                }
            }
            let lastRing = 1 + UInt32(rings - 2) * S
            for sgm in 0..<S { tris += [last, lastRing + (sgm + 1) % S, lastRing + sgm] }
            add(points, tris, slot)
        }
        mutating func ellipsoid(_ c: SIMD3<Float>, _ r: SIMD3<Float>, _ slot: Slot) { sphere({ c + $0 * r }, slot) }
        /// Sphere-swept segment.
        mutating func capsule(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ radius: Float, _ slot: Slot) {
            let axis = b - a, length = rigLength(axis)
            guard length > 1e-5 else { ellipsoid(a, SIMD3(repeating: radius), slot); return }
            let y = axis / length
            let helper: SIMD3<Float> = abs(y.x) < 0.9 ? [1, 0, 0] : [0, 0, 1]
            var x = cross(helper, y); x /= rigLength(x)
            let z = cross(x, y)
            sphere({ p in
                let base = p.y >= 0 ? b : a
                return base + (x * p.x + y * p.y + z * p.z) * radius
            }, slot, rings: 12)
        }
        mutating func box(center c: SIMD3<Float>, size: SIMD3<Float>, _ slot: Slot, tilt: Float = 0) {
            let h = size / 2
            let ct = cos(tilt), st = sin(tilt)
            func corner(_ sx: Float, _ sy: Float, _ sz: Float) -> SIMD3<Float> {
                let p = SIMD3(sx * h.x, sy * h.y, sz * h.z)
                return c + SIMD3(p.x * ct - p.y * st, p.x * st + p.y * ct, p.z)
            }
            let v = [corner(-1, -1, -1), corner(1, -1, -1), corner(1, 1, -1), corner(-1, 1, -1), corner(-1, -1, 1), corner(1, -1, 1), corner(1, 1, 1), corner(-1, 1, 1)]
            let t: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
            add(v, t, slot)
        }
        /// Closed truncated cone along y (or x with axis 0 and a thickness).
        mutating func frustum(bottomCenter c: SIMD3<Float>, top: Float, bottomRadius r0: Float, topRadius r1: Float, _ slot: Slot, axis: Int = 1, thickness: Float = 0, segments: Int = 20) {
            var points: [SIMD3<Float>] = []
            let h = axis == 1 ? top - c.y : thickness
            for ring in 0..<2 {
                let r = ring == 0 ? r0 : r1, off = ring == 0 ? Float(0) : h
                for sgm in 0..<segments {
                    let t = 2 * Float.pi * Float(sgm) / Float(segments)
                    points.append(axis == 1 ? c + SIMD3(sin(t) * r, off, cos(t) * r) : c + SIMD3(off, cos(t) * r, sin(t) * r))
                }
            }
            points.append(c); points.append(axis == 1 ? c + [0, h, 0] : c + [h, 0, 0])
            let S = UInt32(segments), bc = UInt32(points.count - 2), tc = UInt32(points.count - 1)
            var tris: [UInt32] = []
            for sgm in 0..<S {
                let a = sgm, b = (sgm + 1) % S, c2 = a + S, d = b + S
                tris += [a, b, c2, b, d, c2]
                tris += [bc, b, a, tc, c2, d]
            }
            add(points, tris, slot)
        }
        mutating func cone(base: SIMD3<Float>, height: Float, radius: Float, _ slot: Slot) {
            frustum(bottomCenter: base, top: base.y + height, bottomRadius: radius, topRadius: radius * 0.02, slot, segments: 10)
        }
    }
}

@inline(__always) private func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
