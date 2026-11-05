import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MomentsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let onSelect: (MediaEntry) -> Void
    let onCompose: () -> Void
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    @State private var avatarSelection: PhotosPickerItem?
    @State private var coverSelection: PhotosPickerItem?
    @State private var avatarPickerPresented = false
    @State private var coverPickerPresented = false
    @State private var commentTargetID: String?
    @State private var commentDraft = ""
    @State private var showingCommentPrompt = false
    @State private var deletingMoment: String?
    @State private var momentActionsID: String?
    @State private var activeVideoID: String?
    @State private var timelineFilter = "全部"
    @AppStorage("moonlight.glass.bannerSize") private var bannerSizeRaw = GlassSurfaceSize.balanced.rawValue
    private var bannerSize: GlassSurfaceSize { GlassSurfaceSize(rawValue: bannerSizeRaw) ?? .balanced }

    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    Button { coverPickerPresented = true } label: {
                        ProfileBackgroundMedia(target: .cover)
                        .frame(height: 190 * bannerSize.bannerScale).frame(maxWidth: .infinity).clipped()
                        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom))
                        .overlay(alignment: .topLeading) {
                            HStack {
                                Text("朋友圈").font(.title2.bold())
                                Spacer()
                            }.foregroundStyle(.white).padding(14)
                        }
                        .overlay(Color.clear.contentShape(Rectangle()))
                    }
                    .contentShape(Rectangle()).buttonStyle(.moonJelly).accessibilityLabel("更换朋友圈横幅")
                    .photosPicker(isPresented: $coverPickerPresented, selection: $coverSelection, matching: .any(of: [.images, .videos]))
                    HStack(spacing: 12) {
                        Button { avatarPickerPresented = true } label: {
                            ProfileBackgroundMedia(target: .avatar)
                            .frame(width: 60, height: 60).clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .overlay(Color.clear.contentShape(Circle()))
                        }.contentShape(Circle()).buttonStyle(.moonJelly).accessibilityLabel("更换朋友圈头像")
                        .photosPicker(isPresented: $avatarPickerPresented, selection: $avatarSelection, matching: .any(of: [.images, .videos]))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName).font(.headline).foregroundStyle(.white)
                            Text("点击头像或横幅更换媒体").font(.caption).foregroundStyle(.white.opacity(0.82))
                        }
                        Spacer()
                        Button(action: onCompose) {
                            Image(systemName: "square.and.pencil").font(.title3).frame(width: 42, height: 42).moonGlassCircle()
                        }.buttonStyle(.moonJelly).accessibilityLabel("发布动态")
                    }.padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                HStack {
                    Text("最近动态").font(.title3.bold())
                    Spacer()
                    Menu {
                        ForEach(["全部", "我的动态", "虚拟好友", "含媒体"], id: \.self) { option in
                            Button(option) { timelineFilter = option }
                        }
                    } label: { Label(timelineFilter, systemImage: "line.3.horizontal.decrease.circle") }
                    .buttonStyle(MoonGlassButtonStyle()).foregroundStyle(MoonStyle.accent)
                }
                let filteredMoments = model.moments.filter { moment in
                    switch timelineFilter {
                    case "我的动态": return !moment.isVirtual
                    case "虚拟好友": return moment.isVirtual
                    case "含媒体": return moment.attachment != nil
                    default: return true
                    }
                }
                if filteredMoments.isEmpty {
                    EmptyPanel(title: "还没有动态", detail: "写下近况，发布后会保存在本机朋友圈。", symbol: "person.2")
                } else {
                    ForEach(filteredMoments) { moment in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Group {
                                    if moment.isVirtual {
                                        Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                                            .foregroundStyle(MoonStyle.accent)
                                    } else {
                                        ProfileBackgroundMedia(target: .avatar, paused: true)
                                    }
                                }
                                .frame(width: 38, height: 38).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(moment.authorName).font(.subheadline.weight(.semibold))
                                    HStack(spacing: 6) {
                                        Text(moment.date.formatted(date: .abbreviated, time: .shortened))
                                        if moment.isVirtual { Text("虚拟好友") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                            }
                            if !moment.text.isEmpty {
                                Text(moment.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let attachment = moment.attachment {
                                Button { onSelect(attachment) } label: {
                                    MomentAttachmentPreview(entry: attachment, isPlaying: activeVideoID == moment.id && scenePhase == .active)
                                }
                                    .buttonStyle(.moonJelly)
                                    .background {
                                        if attachment.kind == .video, attachment.remoteURL != nil {
                                            GeometryReader { geometry in
                                                Color.clear.preference(key: MomentVideoFramesKey.self,
                                                    value: [moment.id: geometry.frame(in: .named("moments-feed"))])
                                            }
                                        }
                                    }
                            }
                            HStack(spacing: 8) {
                                Button { model.toggleMomentLike(moment.id) } label: {
                                    Label("\(moment.likes)", systemImage: moment.likedByMe ? "heart.fill" : "heart")
                                }
                                .foregroundStyle(moment.likedByMe ? .pink : MoonStyle.accent).accessibilityIdentifier("moment-like-\(moment.id)")
                                if !moment.comments.isEmpty {
                                    Button {
                                        commentTargetID = moment.id
                                        showingCommentPrompt = true
                                    } label: {
                                        Label("\(moment.comments.count)", systemImage: "bubble.right")
                                    }.foregroundStyle(.secondary).accessibilityIdentifier("moment-comment-\(moment.id)")
                                } else {
                                    Button {
                                        commentTargetID = moment.id
                                        showingCommentPrompt = true
                                    } label: { Label("评论", systemImage: "bubble.right") }
                                        .foregroundStyle(.secondary).accessibilityIdentifier("moment-comment-\(moment.id)")
                                }
                                if moment.reposts > 0 {
                                    Label("\(moment.reposts)", systemImage: "arrow.2.squarepath")
                                        .foregroundStyle(.secondary)
                                }
                                Button { model.repostMoment(moment.id) } label: {
                                    Image(systemName: "arrow.2.squarepath")
                                }.foregroundStyle(.secondary).accessibilityLabel("转发动态")
                            }.font(.subheadline)
                            if let comment = moment.comments.last {
                                Text("\(moment.isVirtual ? "好友评论" : "评论")：\(comment)")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .moonGlassCard(radius: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 22))
                        .accessibilityElement(children: .contain)
                        // This is deliberately simultaneous: a vertical drag
                        // remains owned by the feed, while a stationary hold
                        // opens actions that are specific to this post.
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.48, maximumDistance: 7).onEnded { _ in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            momentActionsID = moment.id
                        })
                        .accessibilityIdentifier("moment-post-card-\(moment.id)")
                        .transition(.opacity)
                    }
                }
            }.frame(width: max(0, viewport.size.width - 36))
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 96)
        }.coordinateSpace(name: "moments-feed")
            .onPreferenceChange(MomentVideoFramesKey.self) { frames in
                let visible = CGRect(x: 0, y: 0, width: viewport.size.width, height: max(0, viewport.size.height - 80))
                activeVideoID = frames.map { (id: $0.key, area: $0.value.intersection(visible).height) }
                    .filter { $0.area > 100 }
                    .max(by: { $0.area < $1.area })?.id
            }
            .scrollIndicators(.hidden).pageBackground(.moments)
            .task(id: model.command?.id) {
                if model.command?.action == .avatar { avatarPickerPresented = true; model.command = nil }
                if model.command?.action == .cover { coverPickerPresented = true; model.command = nil }
            }
            .task(id: avatarSelection) {
                if let path = await saveProfileMedia(avatarSelection, name: "avatar") { avatarPath = path }
            }
            .task(id: coverSelection) {
                if let path = await saveProfileMedia(coverSelection, name: "cover") { coverPath = path }
            }
            .alert("评论动态", isPresented: $showingCommentPrompt) {
                TextField("写下评论…", text: $commentDraft)
                Button("取消", role: .cancel) { commentDraft = "" }
                Button("发送") {
                    if let commentTargetID { model.addMomentComment(commentTargetID, text: commentDraft) }
                    commentDraft = ""
                }.disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("动态操作", isPresented: Binding(get: { momentActionsID != nil }, set: { if !$0 { momentActionsID = nil } }), titleVisibility: .visible) {
                if let id = momentActionsID, let moment = model.moments.first(where: { $0.id == id }) {
                    Button(moment.likedByMe ? "取消点赞" : "点赞") { model.toggleMomentLike(id); momentActionsID = nil }
                    Button("评论") { commentTargetID = id; commentDraft = ""; momentActionsID = nil; showingCommentPrompt = true }
                    Button("转发") { model.repostMoment(id); momentActionsID = nil }
                    if !moment.isVirtual {
                        Button("删除动态", role: .destructive) { deletingMoment = id; momentActionsID = nil }
                    }
                }
                Button("取消", role: .cancel) { momentActionsID = nil }
            } message: {
                Text("点赞、评论和转发会作用于当前这条动态；只有自己的动态可以删除。")
            }
            .confirmationDialog("删除这条朋友圈动态？", isPresented: Binding(get: { deletingMoment != nil }, set: { if !$0 { deletingMoment = nil } }), titleVisibility: .visible) {
                Button("删除动态", role: .destructive) {
                    if let id = deletingMoment { model.deleteMoment(id) }
                    deletingMoment = nil
                }.buttonStyle(.automatic).accessibilityIdentifier("confirm-delete-moment")
                Button("取消", role: .cancel) { deletingMoment = nil }
            }
        }
    }
}

struct MomentVideoFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
func saveProfileMedia(_ item: PhotosPickerItem?, name: String) async -> String? {
    guard let item else { return nil }
    let store = BackgroundStore.shared
    guard let asset = try? await store.importSelection(item, for: name == "avatar" ? .avatar : .cover) else { return nil }
    return store.url(for: asset).path
}

struct MomentAttachmentPreview: View {
    let entry: MediaEntry
    var isPlaying = false
    var body: some View {
        GeometryReader { bounds in
        ZStack(alignment: .bottomLeading) {
            if entry.kind == .image, let url = entry.remoteURL, url.isFileURL {
                LocalMediaImage(url: url, fill: true).frame(width: bounds.size.width, height: 210).clipped()
            } else if entry.kind == .video, let url = entry.remoteURL {
                if isPlaying {
                    MomentInlineVideo(url: url, isPlaying: true)
                        .frame(width: bounds.size.width, height: 210).clipped()
                } else if url.isFileURL {
                    LocalVideoPoster(url: url).frame(width: bounds.size.width, height: 210).clipped()
                } else if let cover = entry.coverURL {
                    AsyncImage(url: cover) { image in image.resizable().scaledToFill() } placeholder: { attachmentFallback }
                        .frame(width: bounds.size.width, height: 210).clipped()
                } else { attachmentFallback.frame(height: 210) }
            } else if let cover = entry.coverURL {
                AsyncImage(url: cover) { image in image.resizable().scaledToFill() } placeholder: { attachmentFallback }
                    .frame(width: bounds.size.width, height: 210).clipped()
            } else { attachmentFallback.frame(height: 210) }
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.platform == "bili" ? "哔哩哔哩" : entry.platform == "youtube" ? "YouTube" : "月淡库")
                    .font(.caption.weight(.semibold))
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }.foregroundStyle(.white).padding(12)
            if entry.kind == .image || !isPlaying {
                Image(systemName: entry.kind == .image ? "photo" : "play.fill")
                    .font(.title3.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).moonLiquidSurface(.circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        .frame(width: bounds.size.width, height: 210).clipped()
        }.frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: isPlaying)
    }
    private var attachmentFallback: some View {
        LinearGradient(colors: [MoonStyle.accent.opacity(0.72), .indigo.opacity(0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.82)))
    }
}

struct MomentInlineVideo: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    func makeUIView(context: Context) -> MomentInlineVideoView { MomentInlineVideoView() }
    func updateUIView(_ view: MomentInlineVideoView, context: Context) { view.configure(url: url, playing: isPlaying) }
    static func dismantleUIView(_ view: MomentInlineVideoView, coordinator: ()) { view.stop() }
}

final class MomentInlineVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var playing = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        (layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(url: URL, playing: Bool) {
        if currentURL != url {
            stop()
            currentURL = url
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
            player = queue
            (layer as? AVPlayerLayer)?.player = queue
        }
        self.playing = playing
        if playing && window != nil { player?.play() } else { player?.pause() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if playing && window != nil { player?.play() } else { player?.pause() }
    }
    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        currentURL = nil
        playing = false
        (layer as? AVPlayerLayer)?.player = nil
    }
}

struct MomentComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var attachment: MediaEntry?
    let initialAttachment: MediaEntry?
    let onPublish: (String, MediaEntry?) -> Void

    var body: some View {
        NavigationStack {
            Form { Group {
                Section("此刻") { TextField("分享此刻…", text: $text, axis: .vertical).lineLimit(3...7) }
                Section("照片或视频") {
                    if let attachment {
                        MomentAttachmentPreview(entry: attachment).frame(height: 180)
                        Button("移除附件", role: .destructive) { self.attachment = nil }
                    }
                    PhotosPicker(selection: $photoPickerItem, matching: .any(of: [.images, .videos])) {
                        Label("选择照片或视频", systemImage: "photo.badge.plus")
                    }
                }
                if initialAttachment != nil {
                    Section { Text("来自内容流的条目会以可打开的链接预览显示在动态中。").font(.footnote).foregroundStyle(.secondary) }
                }
                }.listRowBackground(MoonLiquidRowBackground())
            }
            .navigationTitle("发布动态")
            .scrollContentBackground(.hidden).pageBackground(.composer)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") {
                        onPublish(text.trimmingCharacters(in: .whitespacesAndNewlines), attachment)
                        dismiss()
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil)
                }
            }
            .task { if attachment == nil { attachment = initialAttachment } }
            .task(id: photoPickerItem) { await loadAttachment() }
        }
    }

    @MainActor private func loadAttachment() async {
        guard let photoPickerItem, let data = try? await photoPickerItem.loadTransferable(type: Data.self) else { return }
        if let image = UIImage(data: data) {
            attachment = model.mediaStore.importMedia(data, title: "朋友圈照片", kind: .image, fileExtension: photoPickerItem.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")
            _ = image
        } else if let type = photoPickerItem.supportedContentTypes.first, type.conforms(to: .movie) {
            attachment = model.mediaStore.importMedia(data, title: "朋友圈视频", kind: .video, fileExtension: type.preferredFilenameExtension ?? "mov")
        }
    }
}
