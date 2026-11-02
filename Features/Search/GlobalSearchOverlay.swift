import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct GlobalSearchPresentation: Identifiable {
    let id = UUID()
    let location: CGPoint
}

struct GlobalAssistantSearchOverlay: View {
    let presentation: GlobalSearchPresentation
    let onDismiss: () -> Void
    let onCommand: (AppCommand) -> Void
    let onChat: (String) -> Void
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var submission = 0
    @State private var pendingCommand: AppCommand?
    @State private var pendingChat: String?
    @State private var submitting = false
    @FocusState private var focused: Bool

    private var cleanQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    private var provider: AssistantProvider { AssistantProvider(rawValue: providerRaw) ?? .openAI }
    private var matches: [AppCommand] { AssistantCommands.matching(query) }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea().onTapGesture(perform: onDismiss)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        AssistantProviderPicker()
                        TextField("搜索功能或询问 \(provider.title)", text: $query)
                            .lineLimit(1)
                            .focused($focused)
                            .submitLabel(.send)
                            .onSubmit(submitSearch).accessibilityIdentifier("global-search-input")
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                        }.disabled(query.isEmpty).opacity(query.isEmpty ? 0 : 1)
                            .accessibilityLabel("清除搜索").accessibilityIdentifier("global-search-clear")
                        Button(action: onDismiss) {
                            Image(systemName: "xmark").font(.footnote.weight(.bold))
                                .frame(width: 44, height: 44)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .modifier(MoonSearchBubble(focused: focused, submission: submission))

                    if !cleanQuery.isEmpty {
                        FlowLayout(spacing: 9) {
                            Button { submitChat() } label: {
                                Label("问 \(provider.title)", systemImage: "bubble.left.and.bubble.right.fill")
                            }.globalSearchBubble(tint: MoonStyle.accent)

                            ForEach(matches) { command in
                                Button { sendCommand(command) } label: {
                                    Label(command.title, systemImage: command.symbol)
                                }.globalSearchBubble(tint: .blue).accessibilityIdentifier("global-command-" + command.rawValue)
                            }
                        }
                        .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
                    }
                }
                .padding(16)
                .frame(width: min(proxy.size.width - 32, 430), alignment: .leading)
                .position(x: proxy.size.width / 2,
                          y: min(max(presentation.location.y, 138), max(138, proxy.size.height - 250)))

            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .task(id: submission) {
            guard submission > 0 else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            submitting = false
            if let command = pendingCommand { onCommand(command) }
            else if let prompt = pendingChat { onChat(prompt) }
        }
        .onDisappear { if submitting { model.pendingMediaSearch = nil }; submitting = false }
        .accessibilityIdentifier("global-assistant-search")
    }
    private func sendCommand(_ command: AppCommand) {
        guard !submitting else { return }
        if command == .searchMedia { model.pendingMediaSearch = MediaSearchIntent.parse(query) }
        pendingCommand = command; pendingChat = nil
        focused = false; submitting = true; submission += 1
    }
    private func submitChat() {
        guard !submitting, !cleanQuery.isEmpty else { return }
        pendingCommand = nil; pendingChat = cleanQuery
        focused = false; submitting = true; submission += 1
    }
    private func submitSearch() {
        guard !cleanQuery.isEmpty else { return }
        if MediaSearchIntent.parse(query) != nil { sendCommand(.searchMedia) }
        else if let exact = matches.first(where: { $0.searchTerms.contains { $0.caseInsensitiveCompare(cleanQuery) == .orderedSame } }) { sendCommand(exact) }
        else { submitChat() }
    }
}

extension View {
    func globalSearchBubble(tint: Color) -> some View {
        self.font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary).tint(tint)
            .buttonStyle(MoonGlassButtonStyle())
    }
}
