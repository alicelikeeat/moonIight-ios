import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(L10n.key) private var language = AppLanguage.zh.rawValue
    var body: some View {
            Form { Group {
                Section {
                    Picker(selection: $language) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    } label: { Label("语言 / Language", systemImage: "globe") }
                        .accessibilityIdentifier("settings-language")
                } footer: { Text(L10n.t("目前沙盒、地图编辑器和世界控制中心已支持英文，其他页面会陆续支持。", "The sandbox, map editor and world control center are in English now; other pages will follow.")) }
                Section("外观与媒体") {
                    NavigationLink { ContextMenuSettingsView() } label: { Label("长按菜单与底栏", systemImage: "hand.point.up.left") }
                        .accessibilityIdentifier("context-menu-settings-entry")
                    NavigationLink { BackgroundSettingsView() } label: {
                        Label("背景与按键", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("backgrounds-entry")
                    NavigationLink { MoonGlassSettingsView() } label: {
                        Label("玻璃外观（透明度与颜色）", systemImage: "drop.halffull")
                    }
                    .accessibilityIdentifier("glass-look-entry")
                    Text("各页面、底部按键、长按圆环、头像和横幅的素材、应用范围及播放顺序统一在这里设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("播放") {
                    Toggle("视频保持竖屏", isOn: $model.portraitPlaybackOnly)
                    Text(model.portraitPlaybackOnly ? "关闭后，视频播放页可跟随设备方向横屏。" : "横屏仅在视频播放页启用，其他页面保持竖屏。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("内容源") {
                    ForEach(model.mediaStore.enabledSources) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { model.mediaStore.enabledSources.first(where: { $0.id == source.id })?.enabled ?? false },
                            set: { model.mediaStore.setSourceEnabled(source.id, enabled: $0) }
                        ))
                    }
                }
                Section("智能对话") {
                    NavigationLink { AssistantSettingsView() } label: {
                        Label("智能体与 API", systemImage: "sparkles")
                    }
                    Text("输入栏模式可在“长按菜单与底栏”中切换。API Key 仅保存到本机钥匙串；建议使用项目密钥并设置额度限制。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("YouTube 搜索") {
                    SecureField("YouTube API Key", text: $model.mediaStore.youtubeAPIKeyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("安全保存 API Key") {
                        model.mediaStore.setYouTubeAPIKey(model.mediaStore.youtubeAPIKeyDraft)
                    }
                    Text("频道推荐不需 API Key；关键词搜索需要 YouTube Data API v3。密钥保存在本机 Keychain。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("长按菜单") {
                    Toggle("卡片长按交互", isOn: $model.cardLongPressEnabled)
                        .accessibilityIdentifier("card-long-press-toggle")
                    Text("关闭后卡片只保留点按和滚动，可用于判断实机停顿是否来自长按手势竞争。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("菜单样式", selection: $model.longPressStyle) {
                        ForEach(LongPressStyle.allCases) { style in Text(style.title).tag(style) }
                    }
                    Text("玻璃气泡分离会从长按位置的一侧依次弹出操作按键，并自动避开屏幕边缘。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("选择方式", selection: $model.longPressSelectionMode) {
                        ForEach(LongPressSelectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                }
                Section("圆环快捷键") {
                    NavigationLink("按页面和按键自定义操作") { ContextMenuSettingsView() }
                    Text("松开只会保留圆环，不会误触。点按模式需再点圆环按钮；拖动模式可划到按钮上松开执行。“…”打开完整操作面板，删除只在面板中。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("虚拟好友") {
                    Toggle("自动生成朋友圈动态", isOn: $model.virtualActivityEnabled)
                    Picker("发布间隔", selection: $model.virtualIntervalMinutes) {
                        ForEach([15, 30, 60, 240], id: \.self) { minutes in
                            Text(minutes < 60 ? "每 \(minutes) 分钟" : "每 \(minutes / 60) 小时").tag(minutes)
                        }
                    }.disabled(!model.virtualActivityEnabled)
                    Text("开启后会从已启用的内容源读取推荐条目，在应用前台按间隔生成本机动态，并模拟点赞、评论和转发。不会发布到外部社交平台。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("AI 文案服务", selection: $model.virtualAIProvider) {
                        ForEach(VirtualAIProvider.allCases) { provider in Text(provider.title).tag(provider) }
                    }
                    SecureField("\(model.virtualAIProvider.title) API Key（可选）", text: $model.virtualAIKeyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("安全保存 API Key") { model.saveVirtualAIKey() }
                    Text("密钥保存在本机钥匙串。启用后，仅把内容标题和作者发送给所选服务生成文案；未配置时使用本地模板。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("手势说明") {
                    Label("静止抬起才算点按；纵向滑动优先滚动", systemImage: "arrow.up.and.down")
                    Label("点按媒体卡片：打开播放或预览", systemImage: "hand.tap")
                    Label("长按有触感反馈和弹性展开；手指周围最多 4 个快捷键", systemImage: "hand.point.up.left")
                    Label("松开后圆环保留；点按按钮执行，或在设置中启用拖动选择", systemImage: "circle.grid.2x2")
                    Label("圆环中心“…”：打开播放、分享、保存、整理和删除面板", systemImage: "ellipsis.circle")
                    Label("点空白处或下滑：收起圆环", systemImage: "arrow.down")
                    Label("下拉首页或发现：刷新内容源", systemImage: "arrow.down")
                    Label("播放方向：可在播放设置中开启横屏", systemImage: "rectangle.landscape")
                }
                }.listRowBackground(MoonLiquidRowBackground())
            }
            .scrollContentBackground(.hidden)
            .pageBackground(.settings)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
    }
}
