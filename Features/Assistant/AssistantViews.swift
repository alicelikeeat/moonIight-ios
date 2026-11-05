import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AssistantProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI, doubao, gemini, grok
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "GPT"
        case .doubao: "豆包"
        case .gemini: "Gemini"
        case .grok: "Grok"
        }
    }
    var endpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1/responses"
        case .doubao: "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .grok: "https://api.x.ai/v1/chat/completions"
        }
    }
    var keyAccount: String { self == .openAI ? "moonlight_openai_chat" : "moonlight_assistant_" + rawValue }
    var modelKey: String { self == .openAI ? "moonlight.assistant.model" : "moonlight.assistant.model." + rawValue }
    var configuredModel: String {
        UserDefaults.standard.string(forKey: modelKey) ?? (self == .openAI ? "gpt-4.1-mini" : "")
    }
    var modelHint: String { self == .doubao ? "豆包模型 ID 或 ep- 推理接入点" : "填写此账户已开通的模型 ID" }
}

struct AssistantProviderPicker: View {
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    var body: some View {
        Menu {
            Picker("选择智能体", selection: $providerRaw) {
                ForEach(AssistantProvider.allCases) { provider in
                    Text(provider.title).tag(provider.rawValue)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text((AssistantProvider(rawValue: providerRaw) ?? .openAI).title)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.caption.weight(.semibold))
                .padding(.horizontal, 10).frame(minHeight: 44)
        }
        .accessibilityLabel("选择智能体")
        .accessibilityIdentifier("assistant-provider")
    }
}

enum AssistantCommands {
    static func matching(_ query: String) -> [AppCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        if MediaSearchIntent.parse(query) != nil { return [.searchMedia] }
        // Media-specific commands require a selected item; showing them in
        // page search would produce inert buttons.
        let available = AppCommand.allCases.filter { $0.mediaAction == nil }
        return Array(available.filter {
            $0.searchTerms.contains { $0.lowercased().contains(needle) }
        }.sorted { lhs, rhs in
            if (lhs.title == needle) != (rhs.title == needle) { return lhs.title == needle }
            return lhs.title.count < rhs.title.count
        }.prefix(6))
    }
}

struct AssistantLaunch: Identifiable {
    let id = UUID()
    let prompt: String
    let deepThinking: Bool
}

struct AssistantDock: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    @State private var draft = ""
    @State private var submission = 0
    @State private var deepThinking = false
    @FocusState private var focused: Bool
    var onFocusChange: (Bool) -> Void
    let onOpen: (String, Bool) -> Void
    private var provider: AssistantProvider { AssistantProvider(rawValue: providerRaw) ?? .openAI }
    private var matches: [AppCommand] { focused ? AssistantCommands.matching(draft) : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if focused {
                HStack {
                    AssistantProviderPicker()
                    Spacer()
                    Button { draft = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                    }.disabled(draft.isEmpty).accessibilityLabel("清除输入").accessibilityIdentifier("assistant-clear")
                    Button {
                        focused = false
                    } label: {
                        Image(systemName: "chevron.down").frame(width: 44, height: 44)
                    }.accessibilityLabel("收起输入栏")
                }
            }
            if !matches.isEmpty {
                FlowLayout(spacing: 9) {
                    ForEach(matches) { command in
                        Button {
                            if command == .searchMedia { model.pendingMediaSearch = MediaSearchIntent.parse(draft) }
                            focused = false
                            draft = ""
                            model.send(command, context: "assistant-search")
                        } label: {
                            Label(command.title, systemImage: command.symbol)
                        }
                        .globalSearchBubble(tint: MoonStyle.accent)
                        .accessibilityIdentifier("assistant-command-" + command.rawValue)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                Menu {
                    Button { model.send(.photo) } label: { Label("相机", systemImage: "camera") }
                    Button { model.send(.importMedia) } label: { Label("照片或视频", systemImage: "photo") }
                    Divider()
                    Picker("智能体", selection: $providerRaw) {
                        ForEach(AssistantProvider.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("深入思考", isOn: $deepThinking)
                } label: {
                    Image(systemName: "plus").font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.clear, in: Circle())
                }
                TextField("搜索功能或询问 \(provider.title)", text: $draft)
                    .focused($focused).lineLimit(1)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.send).onSubmit(submit)
                    .accessibilityIdentifier("assistant-input")
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.headline.weight(.bold))
                        .foregroundStyle(MoonStyle.accent).frame(width: 44, height: 44)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送给 " + provider.title)
            }
            .padding(8).modifier(MoonSearchBubble(focused: focused, submission: submission))
        }

        // Keep the input and command bubbles as separate accessibility elements.
        .accessibilityElement(children: .contain)
        .onChange(of: focused) { onFocusChange($0) }
        .onDisappear { onFocusChange(false) }
        .onReceive(NotificationCenter.default.publisher(for: .init("moonlight.assistantDockFocus"))) { _ in
            DispatchQueue.main.async { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("moonlight.assistantDockDismiss"))) { _ in
            focused = false
        }
    }

    private func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        submission += 1
        focused = false
        if let intent = MediaSearchIntent.parse(prompt) {
            model.pendingMediaSearch = intent
            model.send(.searchMedia, context: "assistant-search")
        } else if let exact = AssistantCommands.matching(prompt).first(where: { $0.searchTerms.contains { $0.caseInsensitiveCompare(prompt) == .orderedSame } }) {
            model.send(exact, context: "assistant-search")
        } else { onOpen(prompt, deepThinking) }
        draft = ""
    }
}

struct AssistantMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID().uuidString
    var role: Role
    var text: String
}

enum AssistantAPIError: LocalizedError {
    case missingKey, disabled, server(String), invalidResponse
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在智能体设置中保存当前服务的 API Key。"
        case .disabled: "请先在设置中启用 API 对话。"
        case .server(let reason): reason
        case .invalidResponse: "服务没有返回可显示的回答。"
        }
    }
}

enum AssistantAPI {
    static func answer(history: [AssistantMessage], provider: AssistantProvider,
                       model: String, apiKey: String, deepThinking: Bool) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AssistantAPIError.missingKey }
        guard !modelID.isEmpty else {
            throw AssistantAPIError.server("请在设置中填写 \(provider.title) 的模型 ID；豆包也可填写 ep- 推理接入点。")
        }
        guard let endpoint = URL(string: provider.endpoint) else { throw AssistantAPIError.invalidResponse }
        let instruction = deepThinking
            ? "你是月淡中的智能助手。请仔细分析，再给出清晰、准确、可执行的中文回答。"
            : "你是月淡中的智能助手。请用清晰、简洁、友好的中文回答。"
        let messages = history.suffix(16).map { ["role": $0.role.rawValue, "content": $0.text] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        let body: [String: Any]
        if provider == .openAI {
            body = ["model": modelID, "instructions": instruction, "input": messages, "store": false]
        } else {
            body = ["model": modelID,
                    "messages": [["role": "system", "content": instruction]] + messages,
                    "stream": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason = (json?["error"] as? [String: Any])?["message"] as? String ?? "请检查密钥、模型权限及网络连接。"
            throw AssistantAPIError.server("\(provider.title) 请求失败（\(status)）：\(reason)")
        }
        if provider != .openAI,
           let choices = json?["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let text = message["content"] as? String, !text.isEmpty { return text }
        if let text = json?["output_text"] as? String, !text.isEmpty { return text }
        if let output = json?["output"] as? [[String: Any]] {
            let text = output.flatMap { ($0["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        throw AssistantAPIError.invalidResponse
    }
}

struct AssistantChatView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("moonlight.assistant.enabled") private var enabled = false
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    private var provider: AssistantProvider { AssistantProvider(rawValue: providerRaw) ?? .openAI }
    let initialPrompt: String
    let initialDeepThinking: Bool
    @State private var messages: [AssistantMessage] = []
    @State private var draft = ""
    @State private var deepThinking = false
    @State private var sending = false
    @State private var errorText: String?
    @State private var didSeed = false
    @State private var settingsPresented = false

    init(initialPrompt: String, deepThinking: Bool) {
        self.initialPrompt = initialPrompt
        self.initialDeepThinking = deepThinking
        _deepThinking = State(initialValue: deepThinking)
    }

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(MoonStyle.accent)
                    Text(provider.title).font(.title3.weight(.semibold))
                    Text("可向它提问、整理观看计划或解释内容。").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                HStack {
                                    if message.role == .assistant {
                                        Text(message.text).padding(12).moonGlassCard(radius: 18)
                                        Spacer(minLength: 42)
                                    } else {
                                        Spacer(minLength: 42)
                                        Text(message.text).foregroundStyle(.white).padding(12).background(MoonStyle.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    }
                                }.id(message.id)
                            }
                            if sending { HStack { ProgressView(); Text("正在思考…").foregroundStyle(.secondary); Spacer() } }
                        }.padding()
                    }
                    .onChange(of: messages.count) { _ in if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                }
            }
            if let errorText {
                HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(errorText).font(.footnote); Spacer(); Button("配置") { settingsPresented = true } }
                    .padding(.horizontal).padding(.vertical, 8).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Menu {
                    Toggle("深入思考", isOn: $deepThinking)
                    Button("清除本次对话", role: .destructive) { messages.removeAll() }
                } label: { Image(systemName: "plus").frame(width: 38, height: 38).moonLiquidSurface(.circle) }
                TextField("询问 \(provider.title)", text: $draft, axis: .vertical)
                    .lineLimit(1...5).submitLabel(.send).onSubmit { Task { await send() } }
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up").foregroundStyle(.white).frame(width: 38, height: 38).background(MoonStyle.accent, in: Circle())
                }.disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10).moonLiquidSurface(.capsule).padding()
        }
        .navigationTitle(provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { AssistantProviderPicker().disabled(sending) }
            ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
        }
        .onChange(of: providerRaw) { _ in
            // Start a fresh conversation rather than silently forwarding one
            // provider's existing conversation to a different company.
            messages.removeAll()
            errorText = nil
        }
        .task {
            guard !didSeed else { return }; didSeed = true
            draft = initialPrompt
            if !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await send() }
        }
        .sheet(isPresented: $settingsPresented) { NavigationStack { AssistantSettingsView() } }
    }

    @MainActor private func send() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !sending else { return }
        guard enabled else { errorText = AssistantAPIError.disabled.errorDescription; return }
        let selectedProvider = provider
        let selectedModel = selectedProvider.configuredModel
        let key = SecureSettings.read(selectedProvider.keyAccount) ?? ""
        guard !key.isEmpty else { errorText = AssistantAPIError.missingKey.errorDescription; return }
        errorText = nil; draft = ""; sending = true
        messages.append(AssistantMessage(role: .user, text: question))
        do {
            let answer = try await AssistantAPI.answer(history: messages, provider: selectedProvider, model: selectedModel, apiKey: key, deepThinking: deepThinking)
            messages.append(AssistantMessage(role: .assistant, text: answer))
        } catch {
            errorText = error.localizedDescription
        }
        sending = false
    }
}

struct AssistantSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("moonlight.assistant.enabled") private var enabled = false
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    @State private var modelDraft = ""
    @State private var keyDraft = ""
    @State private var saved = false
    private var provider: AssistantProvider { AssistantProvider(rawValue: providerRaw) ?? .openAI }

    var body: some View {
        Form { Group {
            Section("智能体") {
                Toggle("启用 API 对话", isOn: $enabled)
                Picker("当前服务", selection: $providerRaw) {
                    ForEach(AssistantProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section(provider.title + " API") {
                SecureField("API Key", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(provider.modelHint, text: $modelDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(provider.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(saved ? "已保存" : "保存当前服务配置") {
                    let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if key.isEmpty { SecureSettings.delete(provider.keyAccount) }
                    else { SecureSettings.write(key, account: provider.keyAccount) }
                    UserDefaults.standard.set(modelDraft.trimmingCharacters(in: .whitespacesAndNewlines), forKey: provider.modelKey)
                    saved = true
                }
                if provider == .doubao {
                    Text("使用火山方舟 API Key 和已开通的豆包模型 ID，或 ep- 开头的推理接入点 ID。豆包 App 登录信息不能代替 API Key。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("使用说明") {
                Text("在底部输入栏或长按搜索条选择智能体。输入功能名称会出现直达气泡，点击气泡执行功能；发送文字则进入 AI 对话。")
                Text("每个服务独立保存模型和密钥。切换服务前请保存；切换聊天服务将开始新对话。")
                Label("密钥只保存在此设备的钥匙串，不会写入 IPA 或 GitHub。", systemImage: "key.fill")
                Text("API 按各服务的账户单独计费。“深入思考”是更仔细回答的提示，不会擅自切换模型。")
            }
            }.listRowBackground(MoonLiquidRowBackground())
        }.moonLiquidList()
        .navigationTitle("智能体与 API")
        .onAppear(perform: loadConfiguration)
        .onChange(of: providerRaw) { _ in loadConfiguration() }
        .onChange(of: keyDraft) { _ in saved = false }
        .onChange(of: modelDraft) { _ in saved = false }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
    }

    private func loadConfiguration() {
        keyDraft = SecureSettings.read(provider.keyAccount) ?? ""
        modelDraft = provider.configuredModel
        saved = false
    }
}
