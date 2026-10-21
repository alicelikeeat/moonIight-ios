import XCTest
@testable import Moonlight

final class LogicTests: XCTestCase {
    func testRestingPoseIsFullSize() {
        for style in RingAnim.allCases {
            let pose = RingMotion.pose(style, 1, 1, false)
            XCTAssertTrue(pose.isRest, "\(style)")
            XCTAssertEqual(pose.scale, 1, accuracy: 0)
            XCTAssertEqual(pose.alpha, 1, accuracy: 0)
            XCTAssertTrue(RingMotion.pose(style, 1, 0.3, false).isRest)
            if style != .spin {
                XCTAssertTrue(RingMotion.pose(style, 1.02, 1, false).isRest)
            }
        }
    }

    func testFullyClosedIsInvisible() {
        for style in RingAnim.allCases {
            XCTAssertEqual(RingMotion.pose(style, 1, 0, true).alpha, 0, accuracy: 0.0001)
        }
    }

    func testScaleStaysInRange() {
        for style in RingAnim.allCases {
            for k in 0...100 {
                let pose = RingMotion.pose(style, Float(k) / 100, 1, false)
                XCTAssertGreaterThanOrEqual(pose.scale, 0.05)
                XCTAssertLessThanOrEqual(pose.scale, 1.25)
                XCTAssertGreaterThanOrEqual(pose.alpha, 0)
                XCTAssertLessThanOrEqual(pose.alpha, 1)
            }
        }
    }

    func testStarFlight() {
        let first = RingMotion.pose(.star, 0, 1, false)
        XCTAssertLessThanOrEqual(first.scale, 0.15)
        XCTAssertEqual(first.lift, 1, accuracy: 0.0001)
        XCTAssertEqual(first.ang, RingMotion.starSweep, accuracy: 0.001)
        XCTAssertGreaterThan(first.rf, 1.5)
        let flight = (0...82).map { RingMotion.pose(.star, Float($0) / 100, 1, false) }
        for pair in zip(flight, flight.dropFirst()) {
            XCTAssertGreaterThan(pair.1.scale, pair.0.scale)
            XCTAssertLessThanOrEqual(pair.1.ang, pair.0.ang)
            XCTAssertLessThanOrEqual(pair.1.lift, pair.0.lift)
        }
        XCTAssertEqual(RingMotion.starScale(RingMotion.starLand), 1.06, accuracy: 0.001)
        let settle = (82...100).map { RingMotion.pose(.star, Float($0) / 100, 1, false).scale }
        for pair in zip(settle, settle.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1, pair.0)
        }
        XCTAssertEqual(settle.last ?? 0, 1, accuracy: 0)
        XCTAssertGreaterThan(RingMotion.pose(.star, 0.3, 1, false).fx, 0.3)
        XCTAssertEqual(RingMotion.pose(.star, 1, 1, false).fx, 0, accuracy: 0)
    }

    func testStarCloseReverses() {
        let gone = RingMotion.pose(.star, 1, 0, true)
        XCTAssertLessThanOrEqual(gone.scale, 0.15)
        XCTAssertEqual(gone.ang, RingMotion.starSweep, accuracy: 0.001)
        XCTAssertEqual(gone.lift, 1, accuracy: 0.0001)
    }

    func testStarTiming() {
        XCTAssertEqual(RingMotion.openMs(.star, 4), 635)
        for n in 2...6 {
            let ms = RingMotion.openMs(.star, n)
            XCTAssertGreaterThanOrEqual(ms, 500)
            XCTAssertLessThanOrEqual(ms, 700)
        }
    }

    func testLegacyRingNames() {
        XCTAssertEqual(RingAnimPick.normalize("FALL"), "STAR")
        XCTAssertEqual(RingAnimPick.normalize("BLUR"), "STAR")
        XCTAssertEqual(RingAnimPick.encodeSet(RingAnimPick.parseSet("FALL,SHATTER")), "LOTUS,STAR")
        XCTAssertEqual(RingAnim.star.short, "星轨")
        XCTAssertEqual(RingAnimPick.pick(setting: "SPIN", enabled: Set(RingAnim.choices), animatorScale: 0), .fade)
        XCTAssertEqual(RingAnimPick.pick(setting: "RANDOM", enabled: [.spin], animatorScale: 1) { 0 }, .spin)
    }

    func testPlayToggle() {
        let paused = FakePlay()
        XCTAssertFalse(PlayToggle.toggle(paused))
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(FeedTapRule.onTap(isVideo: true, active: true), .togglePlay)
        XCTAssertTrue(PlayToggle.toggle(paused))
        XCTAssertTrue(paused.isPlaying)

        let suppressed = FakePlay(supp: true)
        XCTAssertFalse(PlayToggle.showsPlaying(suppressed))
        XCTAssertTrue(PlayToggle.toggle(suppressed))
        XCTAssertTrue(suppressed.isPlaying)
        XCTAssertEqual(suppressed.focus, 1)

        let ended = FakePlay(state: PlayToggle.ended, pwr: true)
        XCTAssertTrue(PlayToggle.toggle(ended))
        XCTAssertTrue(ended.isPlaying)

        let idle = FakePlay(state: PlayToggle.idle, pwr: false)
        XCTAssertTrue(PlayToggle.toggle(idle))
        XCTAssertTrue(idle.isPlaying)

        let buffering = FakePlay(state: PlayToggle.buffering)
        XCTAssertTrue(PlayToggle.showsPlaying(buffering))
        XCTAssertFalse(PlayToggle.toggle(buffering))
        XCTAssertFalse(buffering.playWhenReady)

        XCTAssertEqual(FeedTapRule.onTap(isVideo: false, active: true), .toggleChrome)
        XCTAssertEqual(FeedTapRule.onTap(isVideo: true, active: false), .toggleChrome)
        XCTAssertEqual(FeedTapRule.onTap(isVideo: true, active: true, hasError: true), .toggleChrome)
    }

    func testFeedNav() {
        let src = ["哔哩", "本地", "哔哩", "YouTube", "本地"]
        XCTAssertEqual(FeedNav.nextSameSource(src, 0), 2)
        XCTAssertEqual(FeedNav.nextSameSource(src, 1), 4)
        XCTAssertEqual(FeedNav.nextSameSource(src, 4), 1)
        XCTAssertNil(FeedNav.nextSameSource(src, 3))
    }

    func testVideoFit() {
        let w: Float = 1080
        let h: Float = 2340
        XCTAssertFalse(VideoFit.fill(mode: .smart, videoW: 1920, videoH: 1080, viewW: w, viewH: h))
        XCTAssertFalse(VideoFit.fill(mode: .smart, videoW: 1080, videoH: 1080, viewW: w, viewH: h))
        XCTAssertTrue(VideoFit.fill(mode: .smart, videoW: 1080, videoH: 2340, viewW: w, viewH: h))
        XCTAssertTrue(VideoFit.fill(mode: .smart, videoW: 1080, videoH: 2400, viewW: w, viewH: h))
        XCTAssertFalse(VideoFit.fill(mode: .smart, videoW: 1080, videoH: 1920, viewW: w, viewH: h))
        XCTAssertFalse(VideoFit.fill(mode: .smart, videoW: 900, videoH: 1200, viewW: w, viewH: h))
        XCTAssertEqual(VideoFit.cropFraction(videoW: 1080, videoH: 1920, viewW: w, viewH: h), 0.18, accuracy: 0.01)
        XCTAssertFalse(VideoFit.fill(mode: .smart, videoW: 0, videoH: 0, viewW: w, viewH: h))
        XCTAssertFalse(VideoFit.fill(mode: .fit, videoW: 1080, videoH: 2340, viewW: w, viewH: h))
        XCTAssertTrue(VideoFit.fill(mode: .fill, videoW: 1920, videoH: 1080, viewW: w, viewH: h))
        XCTAssertTrue(VideoFit.fill(mode: .fit, videoW: 1920, videoH: 1080, viewW: w, viewH: h, override: true))
        XCTAssertFalse(VideoFit.fill(mode: .fill, videoW: 1920, videoH: 1080, viewW: w, viewH: h, override: false))
        XCTAssertEqual(VideoFit.of(nil), .smart)
        XCTAssertEqual(VideoFit.of("bogus"), .smart)
        XCTAssertEqual(VideoDisplay.allCases.map(\.label), ["智能", "完整显示", "铺满"])
    }

    func testRadialGeometry() {
        XCTAssertEqual(RadialGeometry.stepDeg(2), 56, accuracy: 0.01)
        XCTAssertEqual(RadialGeometry.stepDeg(4), 110.0 / 3, accuracy: 0.01)
        let res = RadialGeometry.layout(originX: 540, originY: 1140, n: 7, left: 24, top: 80, right: 1056, bottom: 2200, radius: 260, itemR: 110)
        XCTAssertEqual(res.dir, -90, accuracy: 0.01)
        let step = RadialGeometry.stepDeg(6)
        let six = RadialGeometry.layout(originX: 540, originY: 1500, n: 6, left: 24, top: 80, right: 1056, bottom: 2200, radius: 260, itemR: 110)
        for pair in zip(six.angles, six.angles.dropFirst()) {
            XCTAssertEqual(pair.1 - pair.0, step, accuracy: 0.01)
        }
    }

    func testSocialRoundTripAndReactions() {
        let now: Int64 = 1_760_000_000_000
        let seeded = DemoSocial.seed(.fresh(), now: now)
        let back = try! SocialJSON.decode(SocialJSON.encodeString(seeded))
        XCTAssertEqual(seeded, back)
        XCTAssertThrowsError(try SocialJSON.decode("not json"))
        XCTAssertThrowsError(try SocialJSON.decode("{\"foo\":1}"))

        let moment = seeded.moments[0]
        let who = seeded.friends.last!.id
        let liked = SocialOps.toggleLike(seeded, moment.id, who)
        XCTAssertTrue(liked.moments.first { $0.id == moment.id }!.likes.contains(who))
        let unliked = SocialOps.toggleLike(liked, moment.id, who)
        XCTAssertFalse(unliked.moments.first { $0.id == moment.id }!.likes.contains(who))
        let disliked = SocialOps.toggleDislike(seeded, moment.id, who)
        let target = disliked.moments.first { $0.id == moment.id }!
        XCTAssertTrue(target.dislikes.contains(who))
        XCTAssertFalse(target.likes.contains(who))
        let kept = SocialOps.likeOnly(liked, moment.id, who)
        XCTAssertTrue(kept.moments.first { $0.id == moment.id }!.likes.contains(who))
    }

    func testDeleteContactAndChat() {
        let now: Int64 = 1_760_000_000_000
        let seeded = DemoSocial.seed(.fresh(), now: now)
        let lin = seeded.friends.first { $0.name == "小林" }!
        let yue = seeded.friends.first { $0.name == "阿月" }!
        let deleted = SocialOps.deleteContact(seeded, lin.id)
        XCTAssertNil(deleted.contact(lin.id))
        XCTAssertTrue(deleted.moments.allSatisfy { $0.authorId != lin.id })
        XCTAssertTrue(deleted.conversations.contains { $0.title == "夜跑小队" && $0.memberIds.count == 3 })
        XCTAssertFalse(deleted.conversations.contains { $0.memberIds.contains(lin.id) })
        XCTAssertEqual(seeded, SocialOps.deleteContact(seeded, seeded.selfId))

        let (same, conv) = SocialOps.conversationFor(seeded, members: [yue.id, seeded.selfId])
        XCTAssertEqual(same.conversations.count, seeded.conversations.count)
        XCTAssertEqual(Set(conv.memberIds), Set([seeded.selfId, yue.id]))
        let (_, group1) = SocialOps.conversationFor(seeded, members: [seeded.selfId, yue.id, seeded.friends.last!.id])
        let (_, group2) = SocialOps.conversationFor(seeded, members: [seeded.selfId, yue.id, seeded.friends.last!.id])
        XCTAssertTrue(group1.isGroup)
        XCTAssertNotEqual(group1.id, group2.id)
    }

    func testAutoReplyDoesNotLoop() {
        let seeded = DemoSocial.seed(.fresh(), now: 1_760_000_000_000)
        let yue = seeded.friends.first { $0.name == "阿月" }!
        let conv = seeded.conversations.first { $0.memberIds.contains(yue.id) && !$0.isGroup }!
        let mine = Message(conversationId: conv.id, senderId: seeded.selfId, text: "在吗")
        XCTAssertTrue(AutoReply.replies(msg: mine, conv: conv, contacts: seeded.contacts).isEmpty)
        let on = seeded.contacts.map { $0.id == yue.id ? Contact(id: $0.id, name: $0.name, bio: $0.bio, avatarColor: $0.avatarColor, isVirtual: true, autoReplyOn: true, autoReplies: $0.autoReplies, createdAt: $0.createdAt, updatedAt: $0.updatedAt) : $0 }
        let replies = AutoReply.replies(msg: mine, conv: conv, contacts: on, now: 10, pick: { _ in 0 })
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].senderId, yue.id)
        XCTAssertTrue(replies[0].auto)
        XCTAssertTrue(yue.autoReplies.contains(replies[0].text))
        XCTAssertTrue(AutoReply.replies(msg: replies[0], conv: conv, contacts: on).isEmpty)
        var remote = conv
        remote.remote = true
        XCTAssertTrue(AutoReply.replies(msg: mine, conv: remote, contacts: on).isEmpty)
    }

    func testSchema1DoesNotFloodUnread() {
        let json = """
        {"schema":1,"app":"moonlight","selfId":"self","contacts":[{"id":"self","name":"我","isSelf":true,"isVirtual":false},{"id":"f","name":"阿月","isVirtual":true}],"moments":[{"id":"m","authorId":"f","text":"hi","createdAt":10}],"conversations":[{"id":"c","memberIds":["self","f"],"createdAt":1}],"messages":[{"id":"msg","conversationId":"c","senderId":"f","text":"hey","createdAt":20,"status":"SENT"}]}
        """
        let state = try! SocialJSON.decode(json)
        XCTAssertEqual(state.moments[0].dislikes, [])
        XCTAssertEqual(state.conversations[0].readAt, Int64.max / 2)
        XCTAssertEqual(state.unread("c"), 0)
        XCTAssertEqual(state.messages[0].orderKey, 20)
        let ordered = SocialOps.putMessage(state, Message(id: "later", conversationId: "c", senderId: "self", text: "x", createdAt: 5, serverAt: 100, status: .sent))
        XCTAssertEqual(ordered.messagesOf("c").map(\.id), ["msg", "later"])
    }

    func testTransportsStayOffline() async {
        let message = Message(conversationId: "c", senderId: "me", text: "hi", status: .sending)
        let conv = Conversation(id: "c", memberIds: ["me", "f"])
        let local = await LocalTransport().send(message: message, conversation: conv)
        XCTAssertEqual(local.status, .sent)
        XCTAssertNil(local.error)
        let remote = await RemoteTransport(config: ChatServerConfig(baseURL: "https://chat.example")).send(message: message, conversation: conv)
        XCTAssertEqual(remote.status, .failed)
        XCTAssertEqual(remote.error, "聊天服务器即将推出，消息仅保存在本机")
        XCTAssertFalse(RemoteTransport(config: ChatServerConfig()).active)
        XCTAssertEqual(ChatServerConfig(baseURL: "https://chat.example/").wsURL(), "wss://chat.example/v1/ws")
        let sync = await RemoteTransport(config: ChatServerConfig()).sync(cursor: "abc")
        XCTAssertEqual(sync.cursor, "abc")
        XCTAssertTrue(sync.messages.isEmpty)
    }

    func testDownloadPolicyAndLinks() {
        var stream = MediaEntry(kind: .video, title: "s", remoteURL: "https://cdn.example/a.m3u8", platform: PlatformID.url)
        XCTAssertFalse(DownloadPolicy.canDownload(stream).ok)
        var bili = MediaEntry(kind: .embed, title: "b", remoteURL: "https://www.bilibili.com/video/BV1xx411c7mD", platform: PlatformID.bili, embedURL: EmbedLinks.bili("BV1xx411c7mD", mute: true))
        XCTAssertFalse(DownloadPolicy.canDownload(bili).ok)
        XCTAssertTrue(bili.embedURL?.contains("player.bilibili.com/player.html") == true)
        XCTAssertFalse(bili.embedURL?.contains("playurl") == true)
        var archive = MediaEntry(kind: .video, title: "a", remoteURL: "https://archive.org/download/id/file.mp4", platform: PlatformID.archive)
        XCTAssertTrue(DownloadPolicy.canDownload(archive).ok)
        let resolved = LinkResolver.resolve("https://www.bilibili.com/video/BV1xx411c7mD")
        XCTAssertEqual(resolved.entry?.kind, .embed)
        XCTAssertEqual(resolved.entry?.biliBvid, "BV1xx411c7mD")
        let blocked = LinkResolver.resolve("https://cdn.example/live.m3u8")
        XCTAssertNil(blocked.entry)
        XCTAssertNotNil(blocked.message)
        _ = stream
        _ = bili
        _ = archive
    }

    func testParsers() {
        let nasa = """
        {"collection":{"items":[
          {"href":"https://images-assets.nasa.gov/video/x/x~orig.mp4"},
          {"href":"https://images-assets.nasa.gov/video/x/x~medium.mp4"},
          {"href":"https://images-assets.nasa.gov/video/x/x~mobile.mp4"}
        ]}}
        """
        XCTAssertEqual(NASAAPI.pickMP4(assetJSON: nasa), "https://images-assets.nasa.gov/video/x/x~medium.mp4")
        let meta = """
        {"files":[
          {"name":"preview.mp4","size":"1000"},
          {"name":"sample.mp4","size":"500000"},
          {"name":"film.mp4","size":"2000000"}
        ],"metadata":{"creator":"IA"}}
        """
        let entry = ArchiveAPI.resolve(metadataJSON: meta, id: "film", titleHint: "胶片", creator: "档案")
        XCTAssertEqual(entry?.remoteURL, "https://archive.org/download/film/film.mp4")
        XCTAssertEqual(entry?.platform, PlatformID.archive)
        XCTAssertEqual(entry?.kind, .video)
        let commons = """
        {"query":{"pages":{"1":{"title":"File:Moon.jpg","imageinfo":[{"mime":"image/jpeg","url":"https://upload.wikimedia.org/moon.jpg","thumburl":"https://upload.wikimedia.org/thumb.jpg"}]}}}}
        """
        let parsed = CommonsAPI.parse(json: commons)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].kind, .image)
        XCTAssertEqual(parsed[0].title, "Moon.jpg")
        XCTAssertEqual(parsed[0].author, "Wikimedia")
    }

    func testAtomicWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moon-atomic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try AtomicFile.write(Data("one".utf8), to: url)
        try AtomicFile.write(Data("two".utf8), to: url)
        XCTAssertEqual(String(data: AtomicFile.read(url) ?? Data(), encoding: .utf8), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".tmp"))
    }
}

final class FakePlay: Playable {
    var playWhenReady: Bool
    var playbackState: Int
    var suppressed: Bool
    var hasMedia = true
    var focus = 0
    init(state: Int = PlayToggle.ready, pwr: Bool = true, supp: Bool = false) {
        playbackState = state
        playWhenReady = pwr
        suppressed = supp
    }
    func play() {
        if !playWhenReady { playWhenReady = true; focus += 1; suppressed = false }
    }
    func pause() { playWhenReady = false }
    func prepare() { if playbackState == PlayToggle.idle { playbackState = PlayToggle.ready } }
    func seekToStart() { if playbackState == PlayToggle.ended { playbackState = PlayToggle.ready } }
    var isPlaying: Bool { playWhenReady && playbackState == PlayToggle.ready && !suppressed }
}
