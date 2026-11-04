import SwiftUI
import UniformTypeIdentifiers

// v1.60 editors for the 3D world: media characters with their action
// clips, the skill timeline, and Boss phases. Each edits a copy and saves
// once (one undo step). Sheets use the system's native glass on iOS 26.


// MARK: Characters

@available(iOS 18.0, *)
struct Glass3DCharacterEditor: View {
    @ObservedObject var controller: Glass3DController
    let store: MediaStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating: String?
    @State private var created: String?

    var body: some View {
        NavigationStack {
            List {
                if let manifest = Glass3DStarterPack.manifest {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(manifest.characters) { character in
                                    Button { create(character.id, poses: character.poses) } label: {
                                        VStack(spacing: 6) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.1))
                                                if let idle = character.poses["walk"] ?? character.poses["idle"] {
                                                    Glass3DMediaThumbnail(url: Glass3DStarterPack.url(idle), kind: Glass3DStarterPack.kind(idle), side: 64, corner: 12)
                                                }
                                                if creating == character.id { ProgressView() }
                                            }
                                            .frame(width: 78, height: 78)
                                            Text(Glass3DStarterPack.characterName(character.id)).font(.caption.weight(.semibold))
                                        }
                                    }
                                    .buttonStyle(.plain).disabled(creating != nil)
                                    .accessibilityIdentifier("glass3d-starter-character-\(character.id)")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        if let created { Label(created, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                    } header: { Text(L10n.t("内置角色 · 一键创建", "Built-in Characters · One Tap")) } footer: {
                        Text(L10n.t("Kenney 的 CC0 角色：待机、行走、跳跃、下落、攻击、受伤、欢呼都已配好，点一下就会加入下面的列表，可再设为主角或敌人外观。", "Kenney's CC0 characters with idle, walk, jump, fall, attack, hurt and cheer set up. Tap to add one below, then use it for the player or enemies."))
                    }
                }
                Section {
                    ForEach(controller.world.characters ?? []) { template in
                        NavigationLink {
                            Glass3DCharacterForm(controller: controller, store: store, draft: template)
                        } label: {
                            HStack {
                                Label(template.name, systemImage: template.mode == .model ? "cube" : "person.crop.rectangle")
                                Spacer()
                                if controller.world.playerCharacterID == template.id { Text(L10n.t("主角", "Player")).font(.caption).foregroundStyle(.tint) }
                            }
                        }
                    }
                    .onDelete { offsets in for i in offsets { if let id = controller.world.characters?[i].id { controller.deleteCharacter(id) } } }
                } footer: { Text(L10n.t("用图片、GIF、视频或 USDZ 模型做角色外观。动作只改外观，伤害由技能和战斗规则决定。", "Make looks from pictures, GIFs, videos or USDZ models. Actions only change the look; damage comes from skills and combat rules.")) }
                NavigationLink {
                    Glass3DCharacterForm(controller: controller, store: store, draft: CharacterTemplate(id: "char:" + UUID().uuidString, name: L10n.t("新角色", "New Character")))
                } label: { Label(L10n.t("新建角色", "New Character"), systemImage: "plus") }
            }
            .navigationTitle(L10n.t("角色编辑器", "Character Editor")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { dismiss() } } }
        }
    }

    private func create(_ id: String, poses: [String: StarterAsset]) {
        creating = id; created = nil
        Task {
            let template = await Glass3DStarterPack.createCharacter(id, poses: poses, controller: controller, store: store)
            creating = nil
            created = template.map { L10n.t("已创建「\($0.name)」", "Created \($0.name)") } ?? L10n.t("创建失败", "Could not create")
        }
    }
}

@available(iOS 18.0, *)
private struct Glass3DCharacterForm: View {
    @ObservedObject var controller: Glass3DController
    let store: MediaStore
    @State var draft: CharacterTemplate
    @State private var bindings: [MediaBinding] = []
    @State private var importing = false
    /// Action whose media is being picked (thumbnail grid sheet).
    @State private var picking: CharacterAction?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section(L10n.t("外观", "Look")) {
                TextField(L10n.t("名称", "Name"), text: $draft.name)
                Picker(L10n.t("显示方式", "Display"), selection: $draft.mode) { ForEach(CharacterDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                if draft.mode == .model {
                    Button { importing = true } label: { Label(draft.modelMediaID == nil ? L10n.t("导入 USDZ 模型", "Import USDZ Model") : L10n.t("更换 USDZ 模型", "Replace USDZ Model"), systemImage: "square.and.arrow.down") }
                }
                slider(L10n.t("高度", "Height"), value: $draft.height, range: 0.5...8)
                slider(L10n.t("宽高比", "Width / Height"), value: $draft.aspect, range: 0.2...2)
                slider(L10n.t("脚底锚点", "Foot Anchor"), value: $draft.footAnchor, range: 0...0.5)
                slider(L10n.t("不透明度", "Opacity"), value: $draft.opacity, range: 0.1...1)
                Toggle(L10n.t("阴影", "Shadow"), isOn: $draft.shadow)
            }
            Section(L10n.t("碰撞与受击", "Collision & Hurt Box")) {
                slider(L10n.t("碰撞半径", "Collider Radius"), value: $draft.colliderRadius, range: 0.15...3)
                slider(L10n.t("碰撞高度", "Collider Height"), value: $draft.colliderHeight, range: 0.5...10)
                slider(L10n.t("受击范围倍数", "Hurt Box Scale"), value: $draft.hurtScale, range: 0.5...3)
            }
            if draft.mode != .model {
                Section {
                    ForEach(CharacterAction.allCases, id: \.self) { action in actionRow(action) }
                } header: { Text(L10n.t("动作素材", "Action Media")) } footer: {
                    Text(draft.mode.directions > 1 ? L10n.t("每个动作按顺序选 \(draft.mode.directions) 个方向：正面开始，顺时针。", "Pick \(draft.mode.directions) directions per action: front first, then clockwise.")
                         : draft.mode == .layered ? L10n.t("分层：按从前到后的顺序选最多 6 层。", "Layers: pick up to 6, front to back.") : L10n.t("缺少的动作会用行走或待机代替。", "Missing actions fall back to walk or idle."))
                }
            }
            Section(L10n.t("使用", "Use")) {
                Button(L10n.t("保存并设为主角", "Save and Use for Player")) { save(); controller.setPlayerCharacter(draft.id) }
                ForEach([CreatureKind.neutral, .enemy, .guardian, .miniBoss, .boss], id: \.self) { kind in
                    Button(L10n.t("保存并用于所有", "Save and Use for All ") + kind.title) { save(); controller.applyCharacter(draft.id, to: kind) }
                }
            }
        }
        .navigationTitle(draft.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("保存", "Save")) { save(); dismiss() }.disabled(!draft.valid) } }
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            if let action = picking {
                Glass3DMediaPicker(store: store, title: action.title, used: controller.worldMediaIDs) { item in add(item, to: action) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType.usdz]) { result in
            if case .success(let url) = result, let name = controller.importModel(from: url) { draft.modelMediaID = name }
        }
    }

    private func add(_ item: Glass3DMediaItem, to action: CharacterAction) {
        let wanted = draft.mode == .layered ? 6 : draft.mode.directions
        let binding = MediaBinding(id: "cb:" + UUID().uuidString, mediaID: item.id, kind: item.kind, fit: .fit)
        bindings.append(binding)
        var next = draft.clips[action.rawValue] ?? ActionClip()
        if next.bindingIDs.count >= wanted { next.bindingIDs.removeFirst() }
        next.bindingIDs.append(binding.id)
        draft.clips[action.rawValue] = next
    }
    /// Library file behind a clip binding (new in this form or saved).
    private func preview(_ bindingID: String) -> Glass3DMediaItem? {
        let mediaID = bindings.first { $0.id == bindingID }?.mediaID ?? controller.mediaID(forBinding: bindingID)
        return mediaID.flatMap { id in glass3DMediaItems(store).first { $0.id == id } }
    }

    private func save() {
        // Keep only the bindings the clips still use.
        let used = Set(draft.clips.values.flatMap(\.bindingIDs))
        controller.saveCharacter(draft, bindings: bindings.filter { used.contains($0.id) })
        bindings = []
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title + " " + String(format: "%.2f", value.wrappedValue)).font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func actionRow(_ action: CharacterAction) -> some View {
        let clip = draft.clips[action.rawValue] ?? ActionClip()
        let wanted = draft.mode == .layered ? 6 : draft.mode.directions
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(clip.bindingIDs.count)/\(wanted)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { picking = action } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).accessibilityLabel(L10n.t("添加素材", "Add Media"))
                if !clip.bindingIDs.isEmpty { Button(role: .destructive) { draft.clips[action.rawValue] = nil } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
            }
            if !clip.bindingIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(clip.bindingIDs.enumerated()), id: \.offset) { _, id in
                            let media = preview(id)
                            Glass3DMediaThumbnail(url: media?.url, kind: media?.kind ?? .image, side: 44, corner: 8)
                        }
                    }
                }
                HStack {
                    Stepper(L10n.t("速度 \(String(format: "%.1f", clip.speed))", "Speed \(String(format: "%.1f", clip.speed))"), value: Binding(get: { clip.speed }, set: { draft.clips[action.rawValue]?.speed = $0 }), in: 0.25...4, step: 0.25)
                    Toggle(L10n.t("循环", "Loop"), isOn: Binding(get: { clip.loop }, set: { draft.clips[action.rawValue]?.loop = $0 })).fixedSize()
                }.font(.caption)
            }
        }
    }
}

// MARK: Skills

@available(iOS 18.0, *)
struct Glass3DSkillEditor: View {
    @ObservedObject var controller: Glass3DController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.t("技能栏", "Hotbar")) {
                    ForEach(0..<4, id: \.self) { slot in
                        Picker(L10n.t("第 \(slot + 1) 格", "Slot \(slot + 1)"), selection: Binding(get: { controller.hotbar.indices.contains(slot) ? controller.hotbar[slot] : "" }, set: { controller.setHotbar(slot, skill: $0) })) {
                            ForEach(controller.allSkills) { skill in Label(skill.name, systemImage: skill.symbol).tag(skill.id) }
                        }
                    }
                }
                Section {
                    ForEach(controller.allSkills) { skill in
                        NavigationLink {
                            Glass3DSkillForm(controller: controller, draft: skill.id.hasPrefix("tpl.") && !(controller.world.skills ?? []).contains { $0.id == skill.id } ? copy(of: skill) : skill)
                        } label: {
                            HStack {
                                Label(skill.name, systemImage: skill.symbol)
                                Spacer()
                                if skill.id.hasPrefix("tpl.") { Text(L10n.t("模板", "Template")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let list = controller.allSkills
                        for i in offsets where !list[i].id.hasPrefix("tpl.") { controller.deleteSkill(list[i].id) }
                    }
                } header: { Text(L10n.t("技能", "Skills")) } footer: { Text(L10n.t("模板打开后会复制成你自己的技能再编辑。", "Opening a template edits your own copy.")) }
                NavigationLink {
                    Glass3DSkillForm(controller: controller, draft: SkillDefinition(id: "skill:" + UUID().uuidString, name: L10n.t("新技能", "New Skill"), events: [SkillEvent(time: 0, kind: .action(.skill))]))
                } label: { Label(L10n.t("新建技能", "New Skill"), systemImage: "plus") }
            }
            .navigationTitle(L10n.t("技能编辑器", "Skill Editor")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { dismiss() } } }
        }
    }

    private func copy(of skill: SkillDefinition) -> SkillDefinition {
        var copy = skill; copy.id = "skill:" + UUID().uuidString; copy.name = String((skill.name + L10n.t(" 副本", " Copy")).prefix(64)); return copy
    }
}

@available(iOS 18.0, *)
private struct Glass3DSkillForm: View {
    @ObservedObject var controller: Glass3DController
    @State var draft: SkillDefinition
    @Environment(\.dismiss) private var dismiss
    private let symbols = ["sparkles", "flame", "snowflake", "bolt.fill", "bolt.horizontal", "wind", "tornado", "sparkle", "circle.hexagongrid", "cross.case", "shield", "burst"]

    var body: some View {
        Form {
            Section(L10n.t("技能", "Skill")) {
                TextField(L10n.t("名称", "Name"), text: $draft.name)
                Picker(L10n.t("图标", "Icon"), selection: $draft.symbol) { ForEach(symbols, id: \.self) { Image(systemName: $0).tag($0) } }
                Stepper(L10n.t("冷却 \(String(format: "%.1f", draft.cooldown)) 秒", "Cooldown \(String(format: "%.1f", draft.cooldown))s"), value: $draft.cooldown, in: 0...60, step: 0.5)
                Stepper(L10n.t("耐力消耗 \(draft.staminaCost)", "Stamina \(draft.staminaCost)"), value: $draft.staminaCost, in: 0...100, step: 5)
            }
            Section(L10n.t("时间轴", "Timeline")) {
                timeline
                Text(L10n.t("总时长 \(String(format: "%.1f", draft.length)) 秒 · 单体伤害约 \(estimatedDamage)", "Length \(String(format: "%.1f", draft.length))s · about \(estimatedDamage) damage to one target"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(draft.events.indices, id: \.self) { index in
                Section {
                    eventEditor(index)
                } header: {
                    HStack {
                        Text(draft.events[index].kind.title)
                        Spacer()
                        Button(role: .destructive) { draft.events.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            Section {
                Menu {
                    Button(L10n.t("动作", "Action")) { add(.action(.attack)) }
                    Button(L10n.t("粒子", "Particles")) { add(.particles(.magic, seconds: 0.6)) }
                    Button(L10n.t("飞行弹", "Projectile")) { add(.projectile(ProjectileSpec())) }
                    Button(L10n.t("追踪弹", "Homing Projectile")) { add(.projectile(ProjectileSpec(speed: 8, lifetime: 3, damage: 8, homing: 220))) }
                    Button(L10n.t("光束", "Beam")) { add(.beam(BeamSpec())) }
                    Button(L10n.t("范围（带预警）", "Area (telegraphed)")) { add(.area(AreaSpec(radius: 3, forward: 3, damage: 25, delay: 0.8))) }
                    Button(L10n.t("持续伤害区域", "Damage Zone")) { add(.area(AreaSpec(radius: 2.5, forward: 2, damage: 5, duration: 3, interval: 0.5, particle: .fire, status: StatusSpec(kind: .burn)))) }
                    Button(L10n.t("冲击波", "Shockwave")) { add(.area(AreaSpec(shape: .ring, radius: 4, damage: 15, knockback: 3, particle: .smoke))) }
                    Button(L10n.t("冲刺", "Dash")) { add(.dash(distance: 3)) }
                    Button(L10n.t("镜头震动", "Camera Shake")) { add(.shake(0.4)) }
                } label: { Label(L10n.t("添加事件", "Add Event"), systemImage: "plus") }
            }
        }
        .navigationTitle(draft.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("保存", "Save")) { controller.saveSkill(draft); dismiss() }.disabled(!draft.valid) } }
    }

    private func add(_ kind: SkillEventKind) {
        guard draft.events.count < SkillDefinition.maximumEvents else { return }
        draft.events.append(SkillEvent(time: (draft.events.map(\.time).max() ?? 0), kind: kind))
    }

    /// Bars for each event over time (start and how long it acts).
    private var timeline: some View {
        let total = max(1, draft.length)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(draft.events.indices, id: \.self) { index in
                let event = draft.events[index]
                let span = max(0.05, duration(event))
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 3).fill(color(event).opacity(0.7))
                        .frame(width: max(4, geometry.size.width * span / total), height: 10)
                        .offset(x: geometry.size.width * event.time / total)
                }.frame(height: 10)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement().accessibilityLabel(L10n.t("技能时间轴", "Skill timeline"))
    }
    private func duration(_ event: SkillEvent) -> Double {
        switch event.kind {
        case .projectile(let p): p.lifetime
        case .beam(let b): b.duration
        case .area(let a): a.delay + max(0.2, a.duration)
        case .particles(_, let s): s
        default: 0.15
        }
    }
    private func color(_ event: SkillEvent) -> Color {
        switch event.kind { case .projectile: .orange; case .beam: .purple; case .area: .red; case .particles: .cyan; case .action: .green; default: .gray }
    }
    private var estimatedDamage: Int {
        draft.events.reduce(0) { sum, event in
            switch event.kind {
            case .projectile(let p): sum + p.damage + p.explosionDamage
            case .beam(let b): sum + Int(b.duration / max(0.05, b.interval)) * b.tickDamage
            case .area(let a): sum + (a.duration > 0 ? Int(a.duration / max(0.05, a.interval)) * a.damage : a.damage)
            default: sum
            }
        }
    }

    @ViewBuilder private func eventEditor(_ index: Int) -> some View {
        Stepper(L10n.t("开始 \(String(format: "%.2f", draft.events[index].time)) 秒", "Starts at \(String(format: "%.2f", draft.events[index].time))s"), value: $draft.events[index].time, in: 0...10, step: 0.05)
        switch draft.events[index].kind {
        case .action(let action):
            Picker(L10n.t("动作", "Action"), selection: Binding(get: { action }, set: { draft.events[index].kind = .action($0) })) { ForEach(CharacterAction.allCases, id: \.self) { Text($0.title).tag($0) } }
        case .particles(let preset, let seconds):
            Picker(L10n.t("粒子", "Particles"), selection: Binding(get: { preset }, set: { draft.events[index].kind = .particles($0, seconds: seconds) })) { ForEach(ParticlePreset.allCases, id: \.self) { Text($0.title).tag($0) } }
            Stepper(L10n.t("持续 \(String(format: "%.1f", seconds)) 秒", "\(String(format: "%.1f", seconds))s"), value: Binding(get: { seconds }, set: { draft.events[index].kind = .particles(preset, seconds: $0) }), in: 0.1...5, step: 0.1)
        case .projectile(var spec):
            Stepper(L10n.t("伤害 \(spec.damage)", "Damage \(spec.damage)"), value: Binding(get: { spec.damage }, set: { spec.damage = $0; draft.events[index].kind = .projectile(spec) }), in: 0...200, step: 1)
            Stepper(L10n.t("速度 \(Int(spec.speed))", "Speed \(Int(spec.speed))"), value: Binding(get: { spec.speed }, set: { spec.speed = $0; draft.events[index].kind = .projectile(spec) }), in: 2...40, step: 1)
            Stepper(L10n.t("数量 \(spec.count) · 扇角 \(Int(spec.spread))°", "Count \(spec.count) · spread \(Int(spec.spread))°"), value: Binding(get: { spec.count }, set: { spec.count = $0; if spec.spread == 0 && $0 > 1 { spec.spread = 15 }; draft.events[index].kind = .projectile(spec) }), in: 1...12)
            Stepper(L10n.t("追踪 \(Int(spec.homing))°/秒", "Homing \(Int(spec.homing))°/s"), value: Binding(get: { spec.homing }, set: { spec.homing = $0; draft.events[index].kind = .projectile(spec) }), in: 0...720, step: 30)
            Stepper(L10n.t("穿透 \(spec.pierce)", "Pierce \(spec.pierce)"), value: Binding(get: { spec.pierce }, set: { spec.pierce = $0; draft.events[index].kind = .projectile(spec) }), in: 0...10)
            Stepper(L10n.t("爆炸半径 \(String(format: "%.1f", spec.explosionRadius))", "Explosion \(String(format: "%.1f", spec.explosionRadius))"), value: Binding(get: { spec.explosionRadius }, set: { spec.explosionRadius = $0; if spec.explosionDamage == 0 { spec.explosionDamage = 10 }; draft.events[index].kind = .projectile(spec) }), in: 0...8, step: 0.5)
            Picker(L10n.t("拖尾", "Trail"), selection: Binding(get: { spec.particle }, set: { spec.particle = $0; draft.events[index].kind = .projectile(spec) })) { ForEach(ParticlePreset.allCases, id: \.self) { Text($0.title).tag($0) } }
        case .beam(var spec):
            Stepper(L10n.t("每跳伤害 \(spec.tickDamage)", "Tick damage \(spec.tickDamage)"), value: Binding(get: { spec.tickDamage }, set: { spec.tickDamage = $0; draft.events[index].kind = .beam(spec) }), in: 0...100)
            Stepper(L10n.t("长度 \(Int(spec.length))", "Length \(Int(spec.length))"), value: Binding(get: { spec.length }, set: { spec.length = $0; draft.events[index].kind = .beam(spec) }), in: 2...30, step: 1)
            Stepper(L10n.t("持续 \(String(format: "%.1f", spec.duration)) 秒", "\(String(format: "%.1f", spec.duration))s"), value: Binding(get: { spec.duration }, set: { spec.duration = $0; draft.events[index].kind = .beam(spec) }), in: 0.2...6, step: 0.2)
            Picker(L10n.t("粒子", "Particles"), selection: Binding(get: { spec.particle }, set: { spec.particle = $0; draft.events[index].kind = .beam(spec) })) { ForEach(ParticlePreset.allCases, id: \.self) { Text($0.title).tag($0) } }
        case .area(var spec):
            Picker(L10n.t("形状", "Shape"), selection: Binding(get: { spec.shape }, set: { spec.shape = $0; draft.events[index].kind = .area(spec) })) { ForEach(AreaShape.allCases, id: \.self) { Text($0.title).tag($0) } }
            Stepper(L10n.t("伤害 \(spec.damage)", "Damage \(spec.damage)"), value: Binding(get: { spec.damage }, set: { spec.damage = $0; draft.events[index].kind = .area(spec) }), in: 0...200)
            Stepper(L10n.t("半径 \(String(format: "%.1f", spec.radius))", "Radius \(String(format: "%.1f", spec.radius))"), value: Binding(get: { spec.radius }, set: { spec.radius = $0; draft.events[index].kind = .area(spec) }), in: 0.5...12, step: 0.5)
            Stepper(L10n.t("前方距离 \(String(format: "%.1f", spec.forward))", "Forward \(String(format: "%.1f", spec.forward))"), value: Binding(get: { spec.forward }, set: { spec.forward = $0; draft.events[index].kind = .area(spec) }), in: 0...12, step: 0.5)
            Stepper(L10n.t("预警 \(String(format: "%.1f", spec.delay)) 秒", "Warning \(String(format: "%.1f", spec.delay))s"), value: Binding(get: { spec.delay }, set: { spec.delay = $0; draft.events[index].kind = .area(spec) }), in: 0...4, step: 0.1)
            Stepper(L10n.t("持续 \(String(format: "%.1f", spec.duration)) 秒", "Lasts \(String(format: "%.1f", spec.duration))s"), value: Binding(get: { spec.duration }, set: { spec.duration = $0; draft.events[index].kind = .area(spec) }), in: 0...10, step: 0.5)
            Stepper(L10n.t("击退 \(String(format: "%.1f", spec.knockback))", "Knockback \(String(format: "%.1f", spec.knockback))"), value: Binding(get: { spec.knockback }, set: { spec.knockback = $0; draft.events[index].kind = .area(spec) }), in: 0...8, step: 0.5)
            Picker(L10n.t("粒子", "Particles"), selection: Binding(get: { spec.particle }, set: { spec.particle = $0; draft.events[index].kind = .area(spec) })) { ForEach(ParticlePreset.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker(L10n.t("状态", "Status"), selection: Binding(get: { spec.status?.kind.rawValue ?? "" }, set: { value in spec.status = StatusKind(rawValue: value).map { StatusSpec(kind: $0) }; draft.events[index].kind = .area(spec) })) {
                Text(L10n.t("无", "None")).tag(""); ForEach(StatusKind.allCases.filter { $0 != .heal }, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
        case .dash(let distance):
            Stepper(L10n.t("距离 \(String(format: "%.1f", distance))", "Distance \(String(format: "%.1f", distance))"), value: Binding(get: { distance }, set: { draft.events[index].kind = .dash(distance: $0) }), in: 0.5...10, step: 0.5)
        case .shake(let amount):
            Stepper(L10n.t("强度 \(String(format: "%.1f", amount))", "Strength \(String(format: "%.1f", amount))"), value: Binding(get: { amount }, set: { draft.events[index].kind = .shake($0) }), in: 0.1...1.5, step: 0.1)
        }
    }
}

// MARK: Boss phases

@available(iOS 18.0, *)
struct Glass3DBossEditor: View {
    @ObservedObject var controller: Glass3DController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(controller.world.bossScripts ?? []) { script in
                        NavigationLink { Glass3DBossForm(controller: controller, draft: script) } label: { Label(script.name + " · " + L10n.t("\(script.phases.count) 阶段", "\(script.phases.count) phases"), systemImage: "crown") }
                    }
                    .onDelete { offsets in for i in offsets { if let id = controller.world.bossScripts?[i].id { controller.deleteBossScript(id) } } }
                } footer: { Text(L10n.t("没有指定阶段的大 Boss 使用内置的三阶段「玻璃巨像」。", "Bosses without a script use the built-in three-phase Glass Colossus.")) }
                NavigationLink { Glass3DBossForm(controller: controller, draft: BossDirector.example(id: "boss:" + UUID().uuidString)) } label: { Label(L10n.t("新建（从示例开始）", "New (from the example)"), systemImage: "plus") }
            }
            .navigationTitle(L10n.t("Boss 阶段编辑器", "Boss Phase Editor")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { dismiss() } } }
        }
    }
}

@available(iOS 18.0, *)
private struct Glass3DBossForm: View {
    @ObservedObject var controller: Glass3DController
    @State var draft: BossScript
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section(L10n.t("Boss", "Boss")) {
                TextField(L10n.t("名称", "Name"), text: $draft.name)
                Stepper(L10n.t("击败奖励 \(draft.rewardShards) 月晶", "Reward \(draft.rewardShards) shards"), value: $draft.rewardShards, in: 0...500, step: 5)
            }
            ForEach(draft.phases.indices, id: \.self) { index in
                Section {
                    if index > 0 {
                        Stepper(L10n.t("生命低于 \(Int(draft.phases[index].threshold * 100))% 时开始", "Starts below \(Int(draft.phases[index].threshold * 100))% health"), value: $draft.phases[index].threshold, in: 0.05...0.95, step: 0.05)
                    }
                    Stepper(L10n.t("出招间隔 \(String(format: "%.1f", draft.phases[index].castInterval)) 秒", "Casts every \(String(format: "%.1f", draft.phases[index].castInterval))s"), value: $draft.phases[index].castInterval, in: 0.5...20, step: 0.5)
                    Stepper(L10n.t("移动速度 ×\(String(format: "%.2f", draft.phases[index].speed))", "Speed ×\(String(format: "%.2f", draft.phases[index].speed))"), value: $draft.phases[index].speed, in: 0.5...2, step: 0.05)
                    ForEach(draft.phases[index].skills.indices, id: \.self) { s in
                        HStack {
                            Text(controller.allSkills.first { $0.id == draft.phases[index].skills[s].skillID }?.name ?? draft.phases[index].skills[s].skillID).lineLimit(1)
                            Spacer()
                            Stepper(L10n.t("权重 \(Int(draft.phases[index].skills[s].weight))", "Weight \(Int(draft.phases[index].skills[s].weight))"), value: $draft.phases[index].skills[s].weight, in: 1...10).fixedSize()
                            Button(role: .destructive) { draft.phases[index].skills.remove(at: s) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }.font(.caption)
                    }
                    Menu {
                        ForEach(controller.allSkills) { skill in Button(skill.name) { if draft.phases[index].skills.count < 8 { draft.phases[index].skills.append(WeightedSkill(skillID: skill.id)) } } }
                    } label: { Label(L10n.t("添加技能", "Add Skill"), systemImage: "plus") }
                    Toggle(L10n.t("进入时召唤", "Summon on Entry"), isOn: Binding(get: { draft.phases[index].summon != nil }, set: { draft.phases[index].summon = $0 ? SummonSpec() : nil }))
                    if let summon = draft.phases[index].summon {
                        Picker(L10n.t("召唤", "Summon"), selection: Binding(get: { summon.kind }, set: { draft.phases[index].summon?.kind = $0 })) { ForEach([CreatureKind.enemy, .guardian], id: \.self) { Text($0.title).tag($0) } }
                        Stepper(L10n.t("数量 \(summon.count) · 上限 \(summon.cap)", "Count \(summon.count) · cap \(summon.cap)"), value: Binding(get: { summon.count }, set: { draft.phases[index].summon?.count = $0; draft.phases[index].summon?.cap = max(draft.phases[index].summon?.cap ?? $0, $0) }), in: 1...6)
                    }
                    Picker(L10n.t("变身外观", "Transform Look"), selection: Binding(get: { draft.phases[index].appearanceID ?? "" }, set: { draft.phases[index].appearanceID = $0.isEmpty ? nil : $0 })) {
                        Text(L10n.t("不变", "No change")).tag("")
                        ForEach(controller.world.characters ?? []) { Text($0.name).tag($0.id) }
                    }
                } header: {
                    HStack {
                        Text(L10n.t("第 \(index + 1) 阶段", "Phase \(index + 1)"))
                        Spacer()
                        if index > 0 { Button(role: .destructive) { draft.phases.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                    }
                }
            }
            if draft.phases.count < 6 {
                Button { draft.phases.append(BossPhase(threshold: max(0.05, (draft.phases.last?.threshold ?? 1) - 0.25))) } label: { Label(L10n.t("添加阶段", "Add Phase"), systemImage: "plus") }
            }
            Section(L10n.t("使用", "Use")) {
                Button(L10n.t("保存并用于所有大 Boss", "Save and Use for All Bosses")) { controller.saveBossScript(draft); controller.applyBossScript(draft.id, to: .boss) }
                Button(L10n.t("保存并用于所有小 Boss", "Save and Use for All Mini Bosses")) { controller.saveBossScript(draft); controller.applyBossScript(draft.id, to: .miniBoss) }
            }
        }
        .navigationTitle(draft.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("保存", "Save")) { controller.saveBossScript(draft); dismiss() }.disabled(!draft.valid) } }
    }
}
