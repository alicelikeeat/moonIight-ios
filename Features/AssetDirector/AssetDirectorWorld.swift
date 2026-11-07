import Foundation

// v1.87 AI Asset Director — putting an analysed asset into the open 3D
// world. Each placement is one undoable edit made as the player (origin
// .user), so World Director regeneration never removes it.

@available(iOS 18.0, *)
extension Glass3DController {
    func placeDirectorAsset(_ r: AssetIntelligenceRecord, operation: AssetOperation, director: AIAssetDirector) async -> String {
        let p = world.player.position
        let fx = max(1, min(240, Int(p.x.rounded(.down)))), fy = max(1, min(240, Int(p.y.rounded(.down))))
        let title = L10n.t("放置素材：", "Place asset: ") + r.title
        switch operation {
        case .placeModel:
            guard case .generatedModel(let mid) = r.storage, let manifest = Generated3DStore.shared.models.first(where: { $0.id == mid }) else {
                return L10n.t("模型已不在模型库", "The model is no longer in the model store")
            }
            let look = characterID(forGenerated: manifest)
            let spot = SpatialVector(Double(fx) + 2.5, Double(fy) + 2.5, p.z)
            var creature = CreatureEntity(id: "asset:" + UUID().uuidString, kind: .neutral, position: spot, home: spot, health: 10, maxHealth: 10, damage: 0, origin: .user)
            creature.characterID = look
            edit(title) { w in w.creatures.append(creature) }
            persist(force: true)
            return L10n.t("「\(r.title)」已放在你身边（可撤销）", "“\(r.title)” placed next to you (undoable)")
        case .placeSprite, .adaptEffect:
            guard case .library(let library) = r.storage else { return L10n.t("这个素材不在媒体库里", "This asset is not in the media library") }
            let kind: RPGMediaKind = r.mediaType == .video ? .video : r.mediaType == .gif ? .gif : .image
            let rows = operation == .placeSprite ? 3 : 2
            let columns = max(1, min(6, Int((Double(rows) * (r.signals?.technical.aspect ?? 1)).rounded())))
            let binding = MediaBinding(id: "ad:" + UUID().uuidString, mediaID: library, kind: kind, fit: operation == .placeSprite ? .fit : .fill)
            var blocks: [SpatialBlock] = []
            for column in 0..<columns { for row in 0..<rows {
                var b = SpatialBlock(id: "ad:" + UUID().uuidString, x: fx + 1 + column, y: fy + 3, elevation: p.z + Double(row), thickness: 1)
                b.glass = SpatialGlass.tinted("F5F7FA", density: 0.6)
                b.glass.frosted = true
                b.collision = .decor
                blocks.append(b)
            } }
            guard blocks.allSatisfy(\.valid) else { return L10n.t("这里放不下", "No room here") }
            let ids = blocks.map(\.id)
            edit(title, bindings: [binding]) { w in
                w.blocks.append(contentsOf: blocks)
                SpatialBuilder.mediaGrid(bindingID: binding.id, blocks: ids, face: .front, stretch: true, world: &w)
            }
            persist(force: true)
            return operation == .placeSprite ? L10n.t("已放置立牌（可撤销）", "Standee placed (undoable)") : L10n.t("已放置动态画面（可撤销）", "Moving picture placed (undoable)")
        case .configureMaterial:
            guard let tint = r.dominantColors.first else { return L10n.t("这张图没有可用的主色", "No usable main colour in this picture") }
            guard !selection.isEmpty else { return L10n.t("先在设计模式里选中要改的方块", "Select the blocks to change in Design first") }
            let count = selection.count
            updateSelected(title) { block in block.glass.tintHex = tint }
            return L10n.t("已把 \(count) 个方块改为 #\(tint)（可撤销）", "\(count) blocks set to #\(tint) (undoable)")
        default:
            return ""
        }
    }
}
