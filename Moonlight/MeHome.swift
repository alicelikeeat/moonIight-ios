import PhotosUI
import SwiftUI
import UIKit

private enum MeRoute: Equatable {
    case settings, library, favorites, friends, chats, moments, appearance
}

struct MeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var route: MeRoute?
    @State private var editing = false
    @State private var name = ""
    @State private var bio = ""
    @State private var avatarItem: PhotosPickerItem?

    private var colors: MoonColors { app.settings.showsBackdrop(.me) ? .media : theme }
    private var mine: Int { app.social.moments.filter { $0.authorId == app.social.selfId }.count }
    private var libraryCount: Int { app.library.entries.count }
    private var favoriteCount: Int { app.library.entries.filter(\.favorite).count }

    var body: some View {
        let me = app.social.me
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 14) {
                        profileAvatar(me)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(me.name).font(.system(size: 22, weight: .bold)).foregroundColor(colors.text)
                            Text(me.bio.isEmpty ? "写一句签名" : me.bio).font(.system(size: 14)).foregroundColor(colors.textDim)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        stat("\(mine)", "动态", "me.stat.moments") { route = .moments }
                        stat("\(app.social.friends.count)", "朋友", "me.stat.friends") { route = .friends }
                        stat("\(libraryCount)", "库", "me.stat.library") { route = .library }
                        stat("\(favoriteCount)", "收藏", "me.stat.fav") { route = .favorites }
                    }
                    GlassGroup(title: "我的", colors: colors) {
                        row("我的主页", "\(mine) 条动态", "person.crop.circle", GlassTint.blue, "me.home") { route = .moments }
                        row("编辑资料", "名字、签名、头像（照片或视频）", "pencil", GlassTint.blue, "me.edit") {
                            name = app.social.me.name
                            bio = app.social.me.bio
                            editing = true
                        }
                    }
                    GlassGroup(title: "内容与社交", colors: colors) {
                        row("库", "\(libraryCount) 项 · \(favoriteCount) 收藏", "square.grid.2x2", GlassTint.orange, "me.library") { route = .library }
                        row("朋友", "\(app.social.friends.count) 位虚拟好友", "person.2", GlassTint.green, "me.friends") { route = .friends }
                        row("消息", app.social.totalUnread == 0 ? "没有未读" : "\(app.social.totalUnread) 条未读", "bubble.left", GlassTint.purple, "me.messages") { route = .chats }
                    }
                    GlassGroup(title: "App", colors: colors) {
                        row("外观", app.settings.theme.label, "circle.lefthalf.filled", GlassTint.pink, "me.appearance") { route = .appearance }
                        row("设置", "播放、首页背景、朋友圈、备份…", "gearshape", GlassTint.gray, "me.settings") { route = .settings }
                    }
                }
                .padding(16)
                .padding(.bottom, 110)
            }
            .background {
                ZStack {
                    SystemGlassFill(dark: colors.dark)
                    PageBackdrop(page: .me)
                }
            }
            .navigationTitle("我")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: Binding(get: { route != nil }, set: { if !$0 { route = nil } })) {
                meDestination
            }
            .sheet(isPresented: $editing) { editSheet }
        }
        .environment(\.colorScheme, app.settings.showsBackdrop(.me) ? .dark : scheme)
        .onAppear {
            app.visibleBackdrop = .me
            if app.requestSettings { route = .settings }
        }
        .moonOnChange(of: app.requestSettings) { on in if on { route = .settings } }
        .moonOnChange(of: route == .settings) { on in if !on { app.requestSettings = false } }
        .moonOnChange(of: avatarItem) { item in
            guard let item else { return }
            let contact = app.social.selfId
            Task {
                await app.importProfile(item: item, contactId: contact, cover: false)
                await MainActor.run { avatarItem = nil }
            }
        }
    }

    private func profileAvatar(_ me: Contact) -> some View {
        PhotosPicker(selection: $avatarItem, matching: .any(of: [.images, .videos])) {
            ZStack {
                if let path = me.avatarPath, me.avatarVideo, FileManager.default.fileExists(atPath: path) {
                    LoopFilm(ref: path)
                } else if let path = me.avatarPath, FileManager.default.fileExists(atPath: path), let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Monogram.color(me.avatarColor))
                    Text(Monogram.letter(me.name)).font(.system(size: 28, weight: .semibold)).foregroundColor(.black.opacity(0.7))
                }
            }
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityIdentifier("me.avatar")
    }

    private func stat(_ count: String, _ title: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(count).font(.system(size: 18, weight: .bold)).foregroundColor(colors.text)
                Text(title).font(.system(size: 12)).foregroundColor(colors.textDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .moonGlass(colors, radius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func row(_ title: String, _ subtitle: String, _ symbol: String, _ tint: Color, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassLine(title: title, subtitle: subtitle, symbol: symbol, tint: tint, colors: colors)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var editSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("名字", text: $name).textFieldStyle(.roundedBorder)
                TextField("签名", text: $bio).textFieldStyle(.roundedBorder)
                PhotosPicker(selection: $avatarItem, matching: .any(of: [.images, .videos])) {
                    Label("头像（照片或视频）", systemImage: "person.crop.square")
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle("编辑资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var copy = app.social.me
                        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我的朋友圈" : name
                        copy.bio = bio
                        app.upsertFriend(copy)
                        editing = false
                    }
                }
            }
        }
        .accessibilityIdentifier("me.editor")
    }

    @ViewBuilder private var meDestination: some View {
        switch route {
        case .settings: SettingsView()
        case .library: LibraryView()
        case .favorites: LibraryView(startFilter: 1)
        case .friends: FriendsView()
        case .chats: ChatListView()
        case .moments: MyMomentsView()
        case .appearance: AppearanceView()
        case nil: Color.clear
        }
    }
}

struct MyMomentsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var theme
    private var colors: MoonColors { app.settings.showsBackdrop(.moments) ? .media : theme }

    var body: some View {
        let mine = app.social.timeline.filter { $0.authorId == app.social.selfId }
        ScrollView {
            VStack(spacing: 12) {
                if mine.isEmpty {
                    Text("还没有自己的动态").foregroundColor(colors.textDim).padding(.top, 40)
                }
                ForEach(mine) { moment in
                    MomentCard(moment: moment)
                }
            }
            .padding(16)
        }
        .background { PageBackdrop(page: .moments).background(SystemGlassFill(dark: colors.dark)) }
        .navigationTitle("我的主页")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("me.moments")
    }
}

struct AppearanceView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var colors

    var body: some View {
        VStack(spacing: 12) {
            ForEach(ThemeMode.allCases, id: \.self) { mode in
                Button {
                    app.settings.theme = mode
                    app.saveSettings()
                } label: {
                    HStack {
                        Text(mode.label).foregroundColor(colors.text)
                        Spacer()
                        if app.settings.theme == mode { Image(systemName: "checkmark").foregroundColor(colors.accent) }
                    }
                    .padding(14)
                    .moonGlass(colors, radius: 16)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("appearance.\(mode.rawValue)")
            }
            Spacer()
        }
        .padding(16)
        .background { SystemGlassFill(dark: colors.dark) }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("appearance.root")
    }
}
