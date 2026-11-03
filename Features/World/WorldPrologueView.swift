import SwiftUI

struct WorldPrologue: Equatable {
    let title: String
    let quest: String
    let mode: String
    let perspective: String
}

/// A short title card shown when a world opens (about 1.5 s). Any tap
/// skips it; the tap is consumed here, so it can never also attack, build
/// or select in the world underneath.
struct WorldPrologueView: View {
    let prologue: WorldPrologue
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 10) {
                Text(prologue.title).font(.title2.weight(.semibold))
                Text(prologue.quest).font(.subheadline).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Label(prologue.mode, systemImage: "hammer")
                    Label(prologue.perspective, systemImage: "eye")
                }.font(.caption)
                Text("轻点跳过").font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28).padding(.vertical, 20)
            .moonSingleGlass(radius: 24)
            .scaleEffect(shown || reducedMotion ? 1 : 0.96)
            .opacity(shown ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onFinish() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("world-prologue")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点跳过")
        .task {
            withAnimation(reducedMotion ? nil : .easeOut(duration: 0.25)) { shown = true }
            // UI tests hold the card so they can find and skip it; real
            // launches show it for about 1.5 s.
            let hold: UInt64 = ProcessInfo.processInfo.arguments.contains("--prologue-ui-tests") ? 20_000_000_000 : 1_500_000_000
            try? await Task.sleep(nanoseconds: hold)
            guard !Task.isCancelled else { return }
            onFinish()
        }
    }
}
