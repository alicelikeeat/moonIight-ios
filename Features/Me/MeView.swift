import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MeView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.bio") private var profileBio = "分享生活里的灵感"
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    let selectedImage: Image?
    @Binding var selection: PhotosPickerItem?
    let onSelect: (MediaEntry) -> Void
    @State private var commandPath = NavigationPath()
    @State private var showingTreasureMap = false
    var body: some View {
        NavigationStack(path: $commandPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: "我", subtitle: "个人空间", symbol: "person.crop.circle") {
                        NavigationLink(value: AppCommand.settings) {
                            Image(systemName: "gearshape").font(.title3).frame(width: 42, height: 42).moonGlassCircle()
                        }
                        .buttonStyle(.moonJelly)
                        .accessibilityIdentifier("settings-entry")
                    }
                    if !coverPath.isEmpty {
                        ProfileBackgroundMedia(target: .cover).frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                    NavigationLink(value: AppCommand.profile) {
                        HStack(spacing: 14) {
                            ProfileBackgroundMedia(target: .avatar).frame(width: 58, height: 58).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                Text(displayName).font(.title3.bold()).foregroundStyle(.primary)
                                Text(profileBio).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(18).moonSingleGlass(radius: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.moonJelly)
                    HStack(spacing: 10) {
                        StatCard(value: "\(model.moments.count)", label: "动态")
                        StatCard(value: "\(VirtualFriendRoster.names.count)", label: "好友")
                        StatCard(value: "\(model.mediaStore.items.count)", label: "库")
                        StatCard(value: "\(model.mediaStore.items.filter(\.isFavorite).count)", label: "收藏")
                    }
                    VStack(spacing: 0) {
                        NavigationLink(value: AppCommand.library) { MenuRow(symbol: "square.grid.2x2.fill", title: "库", color: .orange) }
                            .accessibilityIdentifier("me-library")
                        Divider().padding(.leading, 56)
                        Button { showingTreasureMap = true } label: { MenuRow(symbol: "sparkles.rectangle.stack", title: "月藏图", color: .purple) }
                            .accessibilityIdentifier("me-treasure-map")
                        Divider().padding(.leading, 56)
                        Button { model.send(.rpg) } label: { MenuRow(symbol: "square.grid.3x3", title: "自由媒体沙盒", color: .teal) }
                            .accessibilityIdentifier("me-rpg-entrance")
                        Divider().padding(.leading, 56)
                        NavigationLink(value: AppCommand.friends) { MenuRow(symbol: "person.2.fill", title: "朋友", color: .green) }
                        Divider().padding(.leading, 56)
                        NavigationLink(value: AppCommand.messages) { MenuRow(symbol: "bubble.left.and.bubble.right.fill", title: "消息", color: .purple) }
                    }
                    .buttonStyle(.moonJelly).padding(.horizontal, 14)
                    .moonSingleGlass(radius: 24)
                }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .pageBackground(.me)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AppCommand.self) { action in
                switch action {
                case .settings: SettingsView()
                case .profile: ProfileEditView()
                case .friends: VirtualFriendsView(onSelect: onSelect)
                case .messages: VirtualMessagesView()
                default: LibraryView(selectedImage: selectedImage, selection: $selection, onPlay: onSelect, initialAction: action)
                }
            }
        }
        .fullScreenCover(isPresented: $showingTreasureMap) {
            NavigationStack { MoonTreasureMapView().environmentObject(model) }
        }
        .task(id: model.command?.id) {
            guard let action = model.command?.action,
                  [.library, .selectAll, .favorites, .downloads, .settings, .friends, .messages, .profile].contains(action) else { return }
            commandPath = NavigationPath([action])
            model.command = nil
        }
    }
}

struct VirtualFriendsView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    var body: some View {
        List { Group {
            Section("虚拟好友 · 本机") {
                ForEach(Array(VirtualFriendRoster.names.enumerated()), id: \.offset) { item in
                    let index = item.offset
                    let name = item.element
                    NavigationLink {
                        ScrollView {
                            VStack(spacing: 14) {
                                ForEach(model.moments.filter { $0.authorName == name }) { post in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(post.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                        if let entry = post.attachment {
                                            Button { onSelect(entry) } label: { MomentAttachmentPreview(entry: entry) }.buttonStyle(.moonJelly)
                                        }
                                        Label("\(post.likes) 赞 · \(post.comments.count) 评论 · \(post.reposts) 转发", systemImage: "heart")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(14).moonGlassCard(radius: 18)
                                }
                                if model.moments.allSatisfy({ $0.authorName != name }) {
                                    EmptyPanel(title: "还没有动态", detail: "开启虚拟好友自动动态后，这里会显示其分享。", symbol: "person.crop.circle")
                                }
                            }.padding(16)
                        }.navigationTitle(name).navigationBarTitleDisplayMode(.inline).pageBackground(.friends)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 38))
                                .foregroundStyle([Color.blue, .orange, .purple, .pink, .teal, .green][index % 6])
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.body.weight(.semibold))
                                Text(model.moments.first(where: { $0.authorName == name })?.date.formatted(.relative(presentation: .named)) ?? "等待分享")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            }.listRowBackground(MoonLiquidRowBackground())
        }.navigationTitle("朋友").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).pageBackground(.friends)
    }
}

struct VirtualMessagesView: View {
    @EnvironmentObject private var model: AppModel
    private var recentInteractions: [MomentPost] { model.moments.filter { $0.isVirtual && !$0.comments.isEmpty } }
    var body: some View {
        List { Group {
            if recentInteractions.isEmpty {
                EmptyPanel(title: "还没有新消息", detail: "虚拟好友发布动态或评论后，互动摘要会显示在这里。", symbol: "bubble.left.and.bubble.right")
            } else {
                ForEach(recentInteractions) { post in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(post.authorName).font(.subheadline.weight(.semibold))
                        Text(post.comments.last ?? post.text).font(.body).lineLimit(2)
                        Text(post.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
            }.listRowBackground(MoonLiquidRowBackground())
        }.navigationTitle("消息").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).pageBackground(.messages)
    }
}

struct ProfileEditView: View {
    @State private var avatar: PhotosPickerItem?
    @State private var cover: PhotosPickerItem?
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.bio") private var profileBio = "分享生活里的灵感"

    var body: some View {
        Form { Group {
            Section("个人资料") {
                TextField("昵称", text: $displayName).textInputAutocapitalization(.never)
                TextField("签名", text: $profileBio, axis: .vertical).lineLimit(1...3)
            }
            Section("个人头像") {
                ProfileBackgroundMedia(target: .avatar).frame(width: 88, height: 88).clipShape(Circle())
                PhotosPicker(selection: $avatar, matching: .any(of: [.images, .videos])) {
                    Label("选择头像照片或视频", systemImage: "person.crop.circle")
                }
                NavigationLink("调整头像画面与背景") { BackgroundEditorView(target: .avatar) }
            }
            Section("顶部封面") {
                ProfileBackgroundMedia(target: .cover).frame(height: 130).clipShape(RoundedRectangle(cornerRadius: 16))
                PhotosPicker(selection: $cover, matching: .any(of: [.images, .videos])) {
                    Label("选择顶部封面照片或视频", systemImage: "rectangle.fill")
                }
                NavigationLink("调整顶部横幅画面与背景") { BackgroundEditorView(target: .cover) }
            }
            }.listRowBackground(MoonLiquidRowBackground())
        }.navigationTitle("编辑资料").scrollContentBackground(.hidden).pageBackground(.profile)
            .task(id: avatar) { await save(avatar, key: "avatar") }
            .task(id: cover) { await save(cover, key: "cover") }
    }

    @MainActor
    private func save(_ item: PhotosPickerItem?, key: String) async {
        guard let path = await saveProfileMedia(item, name: key) else { return }
        if key == "avatar" { avatarPath = path } else { coverPath = path }
    }
}

func isMoviePath(_ path: String) -> Bool {
    ["mov", "mp4", "m4v", "mpeg", "mpg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
}
