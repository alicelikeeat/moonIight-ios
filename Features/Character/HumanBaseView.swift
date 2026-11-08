import SwiftUI
import RealityKit

// v1.91: the universal base body (HumanBase) on its own. The same panel is
// the workbench's 底模 page and a separate page in the 3D world's ⋯ menu:
// the bare mannequin, its three levels of detail, its 60 joints by body
// region, its 18 shape channels and where it comes from.

/// The live 3D preview: drag to turn, pinch to zoom.
@available(iOS 18.0, *)
struct CharacterPreview: View {
    @ObservedObject var scene: WorkbenchScene
    var status: String
    var height: CGFloat = 280
    @State private var dragStart: Float?
    @State private var zoomStart: Float?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(scene.root)
            let scene = scene
            scene.updates = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated { scene.tick(Float(event.deltaTime)) }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 8)
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            let start = dragStart ?? scene.yaw
            dragStart = start
            scene.yaw = start + Float(value.translation.width) * 0.01
        }.onEnded { _ in dragStart = nil })
        .simultaneousGesture(MagnifyGesture().onChanged { value in
            let start = zoomStart ?? scene.distance
            zoomStart = start
            scene.distance = start / Float(max(0.3, value.magnification))
        }.onEnded { _ in zoomStart = nil })
        .overlay(alignment: .bottomLeading) {
            Text(status).font(.caption2.monospacedDigit()).padding(6).background(.ultraThinMaterial, in: Capsule()).padding(18)
                .accessibilityIdentifier("workbench-status")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("角色预览，左右拖动旋转，双指缩放", "Character preview; drag to turn, pinch to zoom"))
        .accessibilityValue(status)
        .accessibilityIdentifier("workbench-preview")
    }
}

/// The base body's own sections (used inside a Form).
@available(iOS 18.0, *)
struct HumanBasePanel: View {
    @ObservedObject var scene: WorkbenchScene
    @State private var region: BodyRegion?

    private var asset: HumanBaseAsset? { HumanBaseAsset.shared }

    static let lodTitles = [L10n.t("精细", "Full"), L10n.t("中等", "Medium"), L10n.t("远景", "Far")]
    static func lodLabel(_ lod: Int) -> String {
        let triangles = HumanBaseAsset.shared?.lods.indices.contains(lod) == true ? HumanBaseAsset.shared!.lods[lod].triangleCount : 0
        return "\(lodTitles.indices.contains(lod) ? lodTitles[lod] : "LOD\(lod)") · \(triangles) " + L10n.t("三角形", "triangles")
    }

    static let channelTitles: [String: String] = [
        "weight": L10n.t("胖瘦", "Weight"), "muscle": L10n.t("肌肉", "Muscle"), "gender": L10n.t("性别特征", "Gender"),
        "shoulders": L10n.t("肩宽", "Shoulders"), "vshape": L10n.t("倒三角", "V shape"), "hips": L10n.t("臀宽", "Hips"),
        "belly": L10n.t("腹部", "Belly"), "neck": L10n.t("脖子", "Neck"), "upperArm": L10n.t("上臂", "Upper arm"),
        "lowerArm": L10n.t("前臂", "Forearm"), "upperLeg": L10n.t("大腿", "Thigh"), "lowerLeg": L10n.t("小腿", "Calf"),
        "hands": L10n.t("手", "Hands"), "feet": L10n.t("脚", "Feet"), "head": L10n.t("头部大小", "Head size"),
        "faceOval": L10n.t("鹅蛋脸", "Oval face"), "faceRound": L10n.t("圆脸", "Round face"), "faceSquare": L10n.t("方脸", "Square face"),
    ]

    var body: some View {
        if asset == nil {
            Section { Text(L10n.t("没有找到通用底模文件（HumanBase.hbm）", "The base body file (HumanBase.hbm) is missing")).foregroundStyle(.red) }
        }
        Section(L10n.t("人台", "Mannequin")) {
            Picker(L10n.t("姿态", "Pose"), selection: Binding(get: { scene.bindPose }, set: { on in
                scene.bindPose = on
                if !on, scene.motion == nil { scene.motion = MotionLibrary.motion("idle") }
                scene.restart()
            })) {
                Text(L10n.t("T-Pose（绑定姿态）", "T-pose (bind pose)")).tag(true)
                Text(L10n.t("待机", "Idle")).tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("workbench-tpose")
            Picker(L10n.t("精度", "Detail"), selection: $scene.lod) {
                ForEach(0..<3, id: \.self) { Text(Self.lodTitles[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("humanbase-lod")
            LabeledContent(L10n.t("当前精度", "Shown"), value: Self.lodLabel(scene.lod))
                .accessibilityIdentifier("humanbase-lod-label")
            Toggle(L10n.t("显示关节（人台变半透明）", "Show joints (see-through mannequin)"), isOn: $scene.showSkeleton)
                .accessibilityIdentifier("workbench-show-joints")
        }
        jointSections
        Section(L10n.t("体型参数（\(asset?.channels.count ?? 0) 个）", "Shape channels (\(asset?.channels.count ?? 0))")) {
            Text(L10n.t("每个参数是一组顶点偏移；关节位置随体型一起重算。另有身高、腿长、手臂、上半身和 Q 版头身比例。", "Each channel is a set of vertex offsets; the joints are recomputed with the shape. Height, leg, arm and torso length and the chibi head ratio come on top."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(asset?.channels.map(\.name) ?? [], id: \.self) { name in
                LabeledContent(Self.channelTitles[name] ?? name, value: name).font(.caption)
            }
        }
        Section(L10n.t("来源和授权", "Source and licence")) {
            LabeledContent(L10n.t("网格", "Mesh"), value: "MakeHuman hm08")
            LabeledContent(L10n.t("授权", "Licence"), value: "CC0 1.0")
            LabeledContent(L10n.t("顶点", "Vertices"), value: "\(asset?.vertexCount ?? 0)")
            LabeledContent(L10n.t("每顶点权重", "Weights per vertex"), value: "4")
            LabeledContent(L10n.t("文件格式", "File format"), value: "HBM v\(HumanBaseAsset.formatVersion)")
            Text(L10n.t("可编辑源文件和生成脚本在仓库 tools/humanbase/，说明见 Resources/HumanBase/SOURCE.md。", "Editable sources and the build script are in tools/humanbase/; see Resources/HumanBase/SOURCE.md."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("humanbase-source")
    }

    @ViewBuilder private var jointSections: some View {
        let joints = scene.runtime.skeleton(WorkbenchScene.owner)?.joints ?? []
        let extensions = joints.filter(\.isExtension).count
        Section(L10n.t("关节（\(joints.count) 个：\(joints.count - extensions) 个标准 + \(extensions) 个扩展）", "Joints (\(joints.count): \(joints.count - extensions) standard + \(extensions) extensions)")) {
            ForEach(BodyRegion.allCases) { r in
                let count = joints.filter { BodyRegion.of($0.jointID) == r }.count
                Button { select(r == region ? nil : r, joints: joints) } label: {
                    HStack {
                        Text(r.title)
                        Spacer()
                        Text("\(count)").foregroundStyle(.secondary)
                        Image(systemName: r == region ? "scope" : "circle").foregroundStyle(r == region ? Color.pink : Color.secondary)
                    }
                }
                .accessibilityIdentifier("humanbase-region-" + r.rawValue)
            }
        }
        if let region {
            Section(L10n.t("\(region.title)的关节（预览里标成粉色）", "\(region.title) joints (pink in the preview)")) {
                ForEach(joints.filter { BodyRegion.of($0.jointID) == region }, id: \.jointID) { j in
                    LabeledContent(BodyRegion.title(j), value: j.jointID + (j.mirrorID.map { " ↔ " + $0 } ?? "")).font(.caption)
                }
            }
            .accessibilityIdentifier("humanbase-region-joints")
        }
    }

    private func select(_ r: BodyRegion?, joints: [RigJoint]) {
        region = r
        if r != nil { scene.showSkeleton = true }
        scene.highlighted = Set(joints.filter { r != nil && BodyRegion.of($0.jointID) == r }.map(\.jointID))
    }
}

/// The base body as its own page (3D world ⋯ menu).
@available(iOS 18.0, *)
struct HumanBaseView: View {
    /// Opens the workbench to build a character on this body.
    var openWorkbench: (() -> Void)?
    @StateObject private var scene = WorkbenchScene()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            CharacterPreview(scene: scene, status: status)
            Form {
                HumanBasePanel(scene: scene)
                if let openWorkbench {
                    Section {
                        Button(L10n.t("用这个底模建角色（角色工作台）", "Build a character on it (Character Workbench)")) { openWorkbench() }
                            .accessibilityIdentifier("humanbase-open-workbench")
                    }
                }
            }
        }
        .navigationTitle(L10n.t("通用底模", "Base Body"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.t("关闭", "Close")) { dismiss() }.accessibilityIdentifier("humanbase-close") }
        }
        .onAppear {
            scene.bare = true
            scene.bindPose = true
            scene.show(CharacterAppearance())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("humanbase-view")
    }

    private var status: String {
        let pose = scene.bindPose ? "T-Pose" : (scene.motion?.name ?? L10n.t("待机", "Idle"))
        return "HumanBase · \(pose) · \(HumanBasePanel.lodLabel(scene.lod))"
    }
}
