import SwiftUI
import QuartzCore

/// v1.78: tools for the selected blocks, as one Liquid Glass group.
/// Collapsed it is a single capsule (what is selected); expanded the
/// capsule shares its glass with Edit, Copy, Delete and Deselect, and the
/// pieces flow out of / back into it (system glass morphing on iOS 26:
/// GlassEffectContainer + glassEffectID). The blocks themselves keep their
/// RealityKit materials; only these controls are system glass.
@available(iOS 18.0, *)
struct Glass3DSelectionBar: View {
    @ObservedObject var controller: Glass3DController
    @Binding var panel: Bool
    @State private var expanded = true
    @State private var lastAction: Double?
    @Namespace private var glassSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private struct Action: Identifiable {
        let id: String
        let symbol: String
        let title: String
        var role: ButtonRole? = nil
        let run: () -> Void
    }

    private var actions: [Action] {
        [Action(id: "edit", symbol: "slider.horizontal.3", title: L10n.t("编辑", "Edit")) { panel = true },
         Action(id: "copy", symbol: "plus.square.on.square", title: L10n.t("复制", "Copy")) { controller.duplicateSelection() },
         Action(id: "delete", symbol: "trash", title: L10n.t("删除", "Delete"), role: .destructive) { controller.deleteSelection() },
         Action(id: "deselect", symbol: "xmark", title: L10n.t("取消选中", "Deselect")) { controller.selection = [] }]
    }

    var body: some View {
        group {
            HStack(spacing: 8) {
                summary
                if expanded {
                    ForEach(actions) { action in button(action) }
                }
            }
        }
        // Large text grows the bar, up to a size that still fits a phone.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("glass3d-selection-bar")
    }

    /// One glass container on iOS 26 so the pieces blend and morph.
    @ViewBuilder private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency { GlassEffectContainer(spacing: 10) { content() } } else { content() }
    }

    private var summary: some View {
        let count = controller.selection.count
        return Button {
            withAnimation(MoonGlassMotion.animation(.morph, reduceMotion: reduceMotion)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: count > 1 ? "square.stack.3d.up.fill" : "cube.transparent.fill")
                Text(L10n.t("已选 \(count)", "\(count) selected")).lineLimit(1)
                Image(systemName: expanded ? "chevron.left" : "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).frame(minHeight: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(RPGPressStyle())
        .modifier(GlassPiece(id: "summary", space: glassSpace, reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.t("已选 \(count) 个方块", "\(count) blocks selected"))
        .accessibilityHint(expanded ? L10n.t("收起选中工具", "Collapses the selection tools") : L10n.t("展开选中工具", "Expands the selection tools"))
        .accessibilityIdentifier("glass3d-selection-summary")
    }

    private func button(_ action: Action) -> some View {
        Button(role: action.role) {
            // While the group morphs a second tap must not run it again.
            let now = CACurrentMediaTime()
            guard MoonGlassMotion.allows(lastAction: lastAction, now: now) else { return }
            lastAction = now
            action.run()
        } label: {
            Group {
                if action.role == .destructive {
                    // v1.80: the delete key is labelled and red, easy to find.
                    Label(action.title, systemImage: "trash.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(Color.red.gradient, in: Capsule())
                } else {
                    Image(systemName: action.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(Color.primary)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(RPGPressStyle())
        .modifier(GlassPiece(id: action.id, space: glassSpace, reduceMotion: reduceMotion))
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("glass3d-selection-" + action.id)
    }
}

/// One piece of a morphing glass group: system glass with an identity on
/// iOS 26 (pieces flow into each other), the adaptive HUD glass elsewhere
/// and with Reduce Transparency (solid surface).
@available(iOS 18.0, *)
private struct GlassPiece: ViewModifier {
    let id: String
    let space: Namespace.ID
    let reduceMotion: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.rpgHUDState) private var hudState

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency, !hudState.powerSave {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID(id, in: space)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                .overlay { if contrast == .increased { Capsule().strokeBorder(Color.primary.opacity(0.4), lineWidth: 1).allowsHitTesting(false) } }
        } else {
            content.hudGlass(.interactive, in: Capsule())
        }
    }
}

/// v1.80: the delete key for a tapped creature or chest — what it is, a
/// clear red Delete, and Deselect. Deleting is one undo step.
@available(iOS 18.0, *)
struct Glass3DObjectBar: View {
    @ObservedObject var controller: Glass3DController
    let title: String
    @State private var lastAction: Double?

    var body: some View {
        RPGGlassGroup(spacing: 10) {
            HStack(spacing: 8) {
                Label(title, systemImage: controller.picked?.kind == "pickup" ? "shippingbox.fill" : "pawprint.fill")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .hudGlass(.panel, in: Capsule())
                    .accessibilityIdentifier("glass3d-picked-title")
                Button(role: .destructive) {
                    let now = CACurrentMediaTime()
                    guard MoonGlassMotion.allows(lastAction: lastAction, now: now) else { return }
                    lastAction = now
                    controller.deletePicked()
                } label: {
                    Label(L10n.t("删除", "Delete"), systemImage: "trash.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Color.red.gradient, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(RPGPressStyle())
                .accessibilityIdentifier("glass3d-picked-delete")
                Button { controller.picked = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(minWidth: 44, minHeight: 44).contentShape(Capsule())
                }
                .buttonStyle(RPGPressStyle()).hudGlass(.interactive, in: Capsule())
                .accessibilityLabel(L10n.t("取消选中", "Deselect")).accessibilityIdentifier("glass3d-picked-deselect")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
