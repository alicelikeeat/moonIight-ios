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
        XCTAssertLessThanOrEqual(first.scale, 0.08)
        XCTAssertEqual(first.lift, 1, accuracy: 0.0001)
        XCTAssertEqual(first.rot, RingMotion.starSpin, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(first.ang, 360)
        let step: Float = 0.05
        let deltas = (0..<14).map { k in
            RingMotion.starTravel((Float(k) + 1) * step) - RingMotion.starTravel(Float(k) * step)
        }
        for pair in zip(deltas, deltas.dropFirst()) {
            XCTAssertGreaterThan(pair.1, pair.0)
        }
        XCTAssertGreaterThan(RingMotion.starSpeed(0.7), RingMotion.starSpeed(0.1))
        XCTAssertEqual(RingMotion.starScale(RingMotion.starLand), RingMotion.starOvershoot, accuracy: 0.001)
        let land = RingMotion.pose(.star, RingMotion.starLand + 0.001, 1, false)
        XCTAssertGreaterThan(land.scale, 1.1)
        let mid = RingMotion.pose(.star, RingMotion.starLand + 0.12, 1, false)
        XCTAssertGreaterThan(mid.fx2, 0.3)
        XCTAssertLessThan(mid.rf, 1)
        XCTAssertGreaterThan(RingMotion.pose(.star, 0.93, 1, false).fx3, 0.3)
        for i in 0..<8 {
            let rest = RingMotion.pose(.star, 1, 1, false, depth: RingMotion.starDepth(i))
            XCTAssertTrue(rest.isRest, "button \(i)")
            XCTAssertEqual(rest.fx2, 0, accuracy: 0)
            XCTAssertEqual(rest.fx3, 0, accuracy: 0)
        }
        let depths = (0..<12).map { RingMotion.starDepth($0) }
        XCTAssertTrue(depths.allSatisfy { $0 >= 0.8 && $0 <= 1.2 })
        XCTAssertGreaterThan(Set(depths.map { Int($0 * 1000) }).count, 6)
        let far = RingMotion.pose(.star, 0.2, 1, false, depth: 0.8)
        let near = RingMotion.pose(.star, 0.2, 1, false, depth: 1.2)
        XCTAssertLessThan(far.scale, near.scale)
        XCTAssertGreaterThan(far.lift, near.lift)
        XCTAssertLessThan(far.alpha, near.alpha)
    }

    func testStarCloseReverses() {
        let gone = RingMotion.pose(.star, 1, 0, true)
        XCTAssertLessThanOrEqual(gone.scale, 0.08)
        XCTAssertEqual(gone.lift, 1, accuracy: 0.0001)
        XCTAssertEqual(gone.rot, -RingMotion.starSpin, accuracy: 0.01)
        XCTAssertEqual(gone.alpha, 0, accuracy: 0.0001)
        let lifts = (0...100).reversed().map { RingMotion.pose(.star, 1, Float($0) / 100, true).lift }
        for pair in zip(lifts, lifts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1, pair.0)
        }
    }

    func testStarTiming() {
        let standard = RingMotion.openMs(.star, 4)
        XCTAssertEqual(standard, RingMotion.starFlightMs + 3 * RingMotion.starStaggerMs(4))
        XCTAssertEqual(RingMotion.openMs(.star, 4, 2), standard / 2)
        XCTAssertEqual(RingMotion.openMs(.star, 4, 0.5), standard * 2)
        XCTAssertEqual(RingMotion.openMs(.star, 4, 9), RingMotion.openMs(.star, 4, 2))
        XCTAssertGreaterThan(RingMotion.settleDeadlineMs(.star, 4, 1, 0.5), RingMotion.openMs(.star, 4, 0.5))
        XCTAssertEqual(RingMotion.openMs(.lotus, 4), RingMotion.openMs(.lotus, 4, 2))
        for n in 2...6 {
            let ms = RingMotion.openMs(.star, n)
            XCTAssertGreaterThanOrEqual(ms, 850)
            XCTAssertLessThanOrEqual(ms, 1200)
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
        XCTAssertEqual(FeedTapRule.onTap(isVideo: true, active: true, chromeVisible: false, autoHide: true), .revealChrome)
        XCTAssertEqual(FeedTapRule.onTap(isVideo: true, active: true, chromeVisible: true, autoHide: true), .togglePlay)
        XCTAssertEqual(FeedTapRule.onTap(isVideo: false, active: true, chromeVisible: false, autoHide: true), .toggleChrome)
        XCTAssertTrue(ChromeTiming.shouldHide(autoHide: true, playing: true, quiet: 3, limit: 3))
        XCTAssertFalse(ChromeTiming.shouldHide(autoHide: true, playing: true, quiet: 2.9, limit: 3))
        XCTAssertFalse(ChromeTiming.shouldHide(autoHide: false, playing: true, quiet: 9, limit: 3))
        XCTAssertFalse(ChromeTiming.shouldHide(autoHide: true, playing: false, quiet: 9, limit: 3))
        XCTAssertEqual(ChromeTiming.clamp(0.1), 0.5, accuracy: 0.001)
        XCTAssertEqual(ChromeTiming.clamp(99), 30, accuracy: 0.001)
        XCTAssertEqual(ChromeTiming.seconds(3), 3, accuracy: 0.001)
        XCTAssertFalse(FeedAutoplay.allowed(wifiOnly: true, pauseOnLowPower: false, expensive: true, lowPower: false, pathKnown: true))
        XCTAssertTrue(FeedAutoplay.allowed(wifiOnly: true, pauseOnLowPower: false, expensive: true, lowPower: false, pathKnown: false))
        XCTAssertFalse(FeedAutoplay.allowed(wifiOnly: false, pauseOnLowPower: true, expensive: false, lowPower: true, pathKnown: true))
        XCTAssertTrue(FeedAutoplay.allowed(wifiOnly: false, pauseOnLowPower: true, expensive: false, lowPower: false, pathKnown: true))
        let window = CGRect(x: 0, y: 0, width: 390, height: 844)
        XCTAssertTrue(TabChrome.contains(CGPoint(x: 12, y: 800), tabTop: 760, window: window))
        XCTAssertTrue(TabChrome.contains(CGPoint(x: 200, y: 843), tabTop: 760, window: window))
        XCTAssertFalse(TabChrome.contains(CGPoint(x: 200, y: 400), tabTop: 760, window: window))
        XCTAssertFalse(TabChrome.contains(CGPoint(x: 10, y: 759), tabTop: 760, window: window))
        XCTAssertTrue(TabChrome.region(tabTop: 900, window: window).isNull)
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
        let empty = RemoteTransport(config: ChatServerConfig())
        XCTAssertFalse(empty.active)
        let refused = await empty.send(message: message, conversation: conv)
        XCTAssertEqual(refused.status, .failed)
        XCTAssertEqual(refused.error, "还没有填写聊天服务器")
        XCTAssertEqual(ChatServerConfig(baseURL: "https://chat.example/").wsURL(), "wss://chat.example/v1/ws")
        let sync = await empty.sync(cursor: "abc")
        XCTAssertEqual(sync.cursor, "abc")
        XCTAssertTrue(sync.messages.isEmpty)
        XCTAssertNil(sync.error)

        let posted = await RemoteTransport(config: ChatServerConfig(baseURL: "https://chat.example"), exchange: { _ in
            (200, #"{"id":"srv","serverAt":42}"#.data(using: .utf8), nil)
        }).send(message: message, conversation: conv)
        XCTAssertEqual(posted.status, .sent)
        XCTAssertEqual(posted.serverAt, 42)

        let down = await RemoteTransport(config: ChatServerConfig(baseURL: "https://chat.example"), exchange: { _ in
            (nil, nil, "offline")
        }).sync(cursor: "abc")
        XCTAssertEqual(down.error, "offline")
        XCTAssertEqual(down.cursor, "abc")
    }

    func testSwipePinchAndThreads() {
        XCTAssertTrue(SwipeInfo.opensInfo(translationX: -80, translationY: 10))
        XCTAssertFalse(SwipeInfo.opensInfo(translationX: -20, translationY: 4))
        XCTAssertFalse(SwipeInfo.opensInfo(translationX: -80, translationY: 90))
        XCTAssertEqual(PinchRule.override(scale: 1.3, current: nil), true)
        XCTAssertNil(PinchRule.override(scale: 0.7, current: true))
        XCTAssertEqual(PinchRule.override(scale: 1, current: true), true)
        let parent = Comment(id: "p", authorId: "me", text: "根", createdAt: 1)
        let child = Comment(id: "c", authorId: "me", text: "回", replyToId: "p", createdAt: 2)
        let lines = CommentTree.flat([child, parent])
        XCTAssertEqual(lines.map(\.comment.id), ["p", "c"])
        XCTAssertEqual(lines.map(\.depth), [0, 1])
        XCTAssertEqual(CommentTree.removing([parent, child], id: "p").map(\.id), [])
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

    func testTimedHoldTiers() throws {
        let w: Float = 1080
        let h: Float = 2400
        let off = (Float(300), Float(600))
        func machine(timedOn: Bool = true, timedMs: Int64 = 5000, autoFire: Bool = true, centerOn: Bool = true) -> HoldMachine {
            HoldMachine(cfg: HoldConfig(longMs: 500, timedOn: timedOn, timedMs: timedMs, autoFire: autoFire, centerOn: centerOn, slopPx: 24))
        }

        let tap = machine()
        tap.down(0, off.0, off.1, w, h)
        XCTAssertNil(tap.tick(300))
        XCTAssertEqual(tap.up(400), .tap)

        let long = machine()
        long.down(0, off.0, off.1, w, h)
        XCTAssertNil(long.tick(499))
        XCTAssertEqual(long.tick(500), .long)
        long.ring(.feedItem, nil)
        XCTAssertEqual(long.up(2000), .long)

        let timed = machine()
        timed.down(0, off.0, off.1, w, h)
        _ = timed.tick(500)
        timed.ring(.feedItem, "fav")
        XCTAssertTrue(timed.showing)
        XCTAssertEqual(timed.tier(), .timed)
        XCTAssertNil(timed.tick(4999))
        XCTAssertEqual(timed.tick(5000), .timed(.feedItem, "fav", false))
        XCTAssertNil(timed.tick(6000))
        XCTAssertEqual(timed.up(6500), .timed)

        let bare = machine()
        bare.down(0, off.0, off.1, w, h)
        _ = bare.tick(500)
        bare.ring(.tab, nil)
        XCTAssertEqual(bare.tick(5000), .timed(.tab, nil, false))
        let noFire = machine(autoFire: false)
        noFire.down(0, off.0, off.1, w, h)
        _ = noFire.tick(500)
        noFire.ring(.tab, "random")
        XCTAssertEqual(noFire.tick(5000), .timed(.tab, nil, false))

        for (_, opts) in TimedActions.byContext {
            for opt in opts {
                XCTAssertFalse(opt.titles.contains { $0.contains("删除") }, opt.key)
            }
        }
        let blocked = machine()
        blocked.down(0, off.0, off.1, w, h)
        _ = blocked.tick(500)
        blocked.ring(.feedItem, "delete")
        XCTAssertEqual(blocked.tick(5000), .timed(.feedItem, nil, false))
        let evil = RingItem(title: "收藏", systemImage: "heart", key: "fav", destructive: true)
        XCTAssertNil(TimedActions.resolve(items: [evil], groups: [], context: .feedItem, key: "fav"))
        let ok = [
            RingItem(title: "删除", systemImage: "trash", destructive: true),
            RingItem(title: "收藏", systemImage: "heart"),
        ]
        XCTAssertEqual(TimedActions.resolve(items: ok, groups: [], context: .feedItem, key: "fav")?.title, "收藏")
        XCTAssertNil(TimedActions.resolve(items: ok, groups: [], context: .tab, key: "fav"))
        XCTAssertEqual(TimedActions.resolve(items: ok, groups: [], context: .player, key: "fav")?.title, "收藏")
        XCTAssertEqual(TimedActions.sanitize(["FEED_ITEM": "delete", "TAB": "random"]), ["TAB": "random"])

        let centre = machine(timedMs: 3000)
        centre.down(0, w / 2 + 40, h / 2 - 30, w, h)
        XCTAssertTrue(centre.inCenter)
        _ = centre.tick(500)
        centre.ring(.feedItem, "fav")
        XCTAssertEqual(centre.tier(), .center)
        XCTAssertNil(centre.tick(3000))
        XCTAssertEqual(centre.tick(5000), .center)
        XCTAssertEqual(centre.up(5200), .center)

        let onlyCentre = machine(timedOn: false)
        onlyCentre.down(0, w / 2, h / 2, w, h)
        XCTAssertEqual(onlyCentre.tick(500), .long)
        XCTAssertEqual(onlyCentre.tick(5000), .center)

        let radius = w * 0.30 / 2
        let inside = machine()
        inside.down(0, w / 2 + radius - 1, h / 2, w, h)
        XCTAssertTrue(inside.inCenter)
        inside.down(0, w / 2 + radius + 2, h / 2, w, h)
        XCTAssertFalse(inside.inCenter)
        let centreOff = machine(centerOn: false)
        centreOff.down(0, w / 2, h / 2, w, h)
        _ = centreOff.tick(500)
        XCTAssertEqual(centreOff.tier(), .none)
        centreOff.ring(.feedItem, "fav")
        XCTAssertEqual(centreOff.tier(), .timed)

        let slop = machine()
        slop.down(0, w / 2, h / 2, w, h)
        XCTAssertNil(slop.move(w / 2 + 10, h / 2 + 10))
        _ = slop.tick(500)
        slop.ring(.feedItem, "fav")
        XCTAssertEqual(slop.move(w / 2 + 30, h / 2), .cancelled)
        XCTAssertNil(slop.tick(5000))
        XCTAssertNil(slop.tick(9000))
        XCTAssertFalse(slop.showing)
        XCTAssertEqual(slop.up(9100), .cancelled)

        let nowhere = machine()
        nowhere.down(0, off.0, off.1, w, h)
        _ = nowhere.tick(500)
        XCTAssertFalse(nowhere.showing)
        XCTAssertNil(nowhere.tick(20_000))
        XCTAssertEqual(nowhere.up(20_001), .long)

        let deferred = machine()
        deferred.down(0, off.0, off.1, w, h)
        _ = deferred.tick(500)
        deferred.ring(.momentVideo, "mv_mute", deferred: true)
        deferred.ring(.feedItem, "fav")
        XCTAssertEqual(deferred.tick(5000), .timed(.momentVideo, "mv_mute", true))

        let progress = machine()
        progress.down(1000, off.0, off.1, w, h)
        _ = progress.tick(1500)
        progress.ring(.tab, nil)
        XCTAssertEqual(progress.progress(1500), 0, accuracy: 0.0001)
        XCTAssertEqual(progress.progress(1000 + 500 + 2250), 0.5, accuracy: 0.001)
        XCTAssertEqual(progress.progress(99_999), 1, accuracy: 0)
        XCTAssertEqual(progress.elapsed(4200), 3200)
        XCTAssertEqual(HoldConfig.timedMs(seconds: 3), 3000)
        XCTAssertGreaterThanOrEqual(HoldConfig.timedMs(seconds: 3), 1000)
        XCTAssertEqual(HoldConfig.timedMs(seconds: 99), 15_000)

        let parent = RingItem(title: "保存", systemImage: "square.and.arrow.down", children: [
            RingItem(title: "保存到相册", systemImage: "a"),
            RingItem(title: "下载", systemImage: "b"),
        ])
        let tiles = PanelFlatten.tiles(items: [RingItem(title: "播放", systemImage: "play"), parent], groups: [])
        XCTAssertEqual(tiles.map(\.title), ["播放", "保存 · 保存到相册", "保存 · 下载"])

        let raw = #"{"timedOn":true,"timedSeconds":99,"timedAssign":{"FEED_ITEM":"delete","TAB":"random"},"centerPanel":false,"starSpeed":9}"#
        let loaded = try XCTUnwrap(AppSettings.load(Data(raw.utf8)))
        XCTAssertEqual(loaded.timedSeconds, 15, accuracy: 0.001)
        XCTAssertEqual(loaded.timedAssign["TAB"], "random")
        XCTAssertNil(loaded.timedAssign["FEED_ITEM"])
        XCTAssertFalse(loaded.centerPanel)
        XCTAssertEqual(loaded.starSpeed, 2, accuracy: 0)
        XCTAssertFalse(AppSettings().timedOn)
        XCTAssertTrue(AppSettings().centerPanel)
        XCTAssertEqual(loaded.momentAutoplay, .all)
        XCTAssertTrue(loaded.buttonSkins.isEmpty)
        XCTAssertEqual(loaded.iconPreset, IconPreset.primary.rawValue)
        XCTAssertTrue(loaded.bgRefreshOn)
        XCTAssertEqual(loaded.menuSelect, .tap)
        XCTAssertFalse(loaded.dropSelect)
        XCTAssertEqual(AppSettings().menuSelect, .tap)
        XCTAssertFalse(AppSettings().dropSelect)
        XCTAssertTrue(AppSettings().tabLens)
        XCTAssertTrue(AppSettings().feedMuted)
        XCTAssertTrue(AppSettings().chromeAutoHide)
        XCTAssertEqual(AppSettings().chromeHideSeconds, 3, accuracy: 0.001)
        XCTAssertFalse(FeedChromeRule.shown(playing: true, autoHide: true, revealed: false))
        XCTAssertTrue(FeedChromeRule.shown(playing: true, autoHide: true, revealed: true))
        XCTAssertTrue(FeedChromeRule.shown(playing: false, autoHide: true, revealed: false))
        XCTAssertTrue(FeedChromeRule.shown(playing: true, autoHide: false, revealed: false))
        XCTAssertGreaterThanOrEqual(TinyClip.seconds, 30)
        XCTAssertTrue(AppSettings().pauseOnLowPower)
        XCTAssertFalse(AppSettings().autoplayWifiOnly)
        XCTAssertEqual(AppSettings.load(Data(#"{"tabLens":false}"#.utf8))?.tabLens, false)
        XCTAssertEqual(try XCTUnwrap(AppSettings.load(Data(#"{"chromeHideSeconds":99}"#.utf8))).chromeHideSeconds, 30, accuracy: 0.001)
        let opted = AppSettings.load(Data(#"{"menuSelect":"DROP"}"#.utf8))
        XCTAssertEqual(opted?.menuSelect, .tap)
        XCTAssertEqual(opted?.dropSelect, true)
        let spin = RingMotion.openMs(.spin, 4, 1)
        XCTAssertEqual(spin, RingMotion.spinFlightMs + 3 * RingMotion.spinStaggerMs)
        XCTAssertGreaterThanOrEqual(spin, 250)
        XCTAssertLessThanOrEqual(spin, 350)
        XCTAssertEqual(RingMotion.openMs(.spin, 4, 2), spin / 2)
        XCTAssertEqual(RingMotion.openMs(.spin, 4, 0.5), spin * 2)
        XCTAssertEqual(BubbleMotion.influence(distance: 0), 1, accuracy: 0.001)
        XCTAssertEqual(BubbleMotion.influence(distance: 400), 0, accuracy: 0.001)
        XCTAssertGreaterThan(BubbleMotion.influence(distance: 30), BubbleMotion.influence(distance: 120))
        XCTAssertEqual(BubbleMotion.scaleBoost(0), 1, accuracy: 0.001)
        XCTAssertEqual(BubbleMotion.scaleBoost(1), 1.25, accuracy: 0.001)
        XCTAssertEqual(DropAim.decide(hit: nil, destructive: false, hasUndo: false, moved: 0), .stay)
        XCTAssertEqual(DropAim.decide(hit: nil, destructive: false, hasUndo: false, moved: 40), .cancel)
        XCTAssertEqual(DropAim.decide(hit: 1, destructive: true, hasUndo: false, moved: 40), .stay)
        XCTAssertEqual(DropAim.decide(hit: 1, destructive: true, hasUndo: true, moved: 4), .fire(1))
    }

    func testV1ParityRules() {
        XCTAssertEqual(ButtonSkinID.allCases.count, 29)
        XCTAssertEqual(ButtonSkins.count, 29)
        XCTAssertEqual(ButtonSkins.identify(key: "record", title: "别的"), .record)
        XCTAssertEqual(ButtonSkins.identify(key: nil, title: "已收藏"), .fav)
        XCTAssertEqual(ButtonSkins.identify(key: "mv_save", title: "保存到相册"), .save)

        var skins: [String: ButtonSkin] = [:]
        let photo = ButtonSkin(path: "/tmp/a.jpg", video: false)
        ButtonSkins.assign([.fav, .mute], skin: photo, into: &skins)
        XCTAssertEqual(skins.count, 2)
        let video = ButtonSkin(path: "/tmp/a.mov", video: true)
        ButtonSkins.assignAll(video, into: &skins)
        XCTAssertEqual(skins.count, 29)
        XCTAssertTrue(skins.values.allSatisfy(\.video))
        ButtonSkins.clear([.fav], skins: &skins)
        XCTAssertNil(skins[ButtonSkinID.fav.rawValue])

        let ids = (0..<8).map { "b\($0)" }
        XCTAssertEqual(SkinPlayBudget.playing(ids).count, 4)
        XCTAssertEqual(SkinPlayBudget.playing(["a", "a", "b"]).count, 2)

        XCTAssertFalse(MomentPlay.allows(mode: .off, momentID: "m", picked: [], already: 0))
        XCTAssertTrue(MomentPlay.allows(mode: .all, momentID: "m", picked: [], already: 5))
        XCTAssertFalse(MomentPlay.allows(mode: .all, momentID: "m", picked: [], already: 6))
        XCTAssertTrue(MomentPlay.allows(mode: .picked, momentID: "m", picked: ["m"], already: 0))
        XCTAssertFalse(MomentPlay.allows(mode: .picked, momentID: "x", picked: ["m"], already: 0))

        var bin: [TrashItem] = []
        let entry = MediaEntry(kind: .image, title: "月亮")
        TrashBin.shredEntry(entry, into: &bin, now: 10)
        XCTAssertEqual(bin.count, 1)
        let moment = Moment(authorId: "me", text: "晚安")
        TrashBin.shredMoment(moment, into: &bin, now: 11)
        XCTAssertEqual(bin.count, 2)
        let back = TrashBin.take(bin[0].id, from: &bin)
        XCTAssertEqual(back?.moment?.text, "晚安")
        XCTAssertEqual(bin.count, 1)
        XCTAssertEqual(bin[0].entry?.title, "月亮")

        XCTAssertTrue(DownloadLane.active.listsInLibrary)
        XCTAssertFalse(DownloadLane.auto.listsInLibrary)
        let url = URL(string: "https://archive.org/download/film/a.mp4")!
        let ranged = ResumePlan.request(url: url, receivedBytes: 2048)
        XCTAssertEqual(ranged.value(forHTTPHeaderField: "Range"), "bytes=2048-")
        XCTAssertNil(ResumePlan.request(url: url, receivedBytes: 0).value(forHTTPHeaderField: "Range"))
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSURLSessionDownloadTaskResumeData: Data([1, 2, 3])])
        XCTAssertEqual(ResumePlan.resumeData(from: ns), Data([1, 2, 3]))
        XCTAssertEqual(TransferRestart.choose(received: 10, hasResume: true, hasPartial: true), .resume)
        XCTAssertEqual(TransferRestart.choose(received: 10, hasResume: false, hasPartial: true), .range(10))
        XCTAssertEqual(TransferRestart.choose(received: 10, hasResume: false, hasPartial: false), .full)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("a.bin")
        let part = dir.appendingPathComponent("b.bin")
        try? Data([1, 2]).write(to: dest)
        try? Data([3]).write(to: part)
        try? FileJoin.append(part: part, onto: dest)
        XCTAssertEqual(try? Data(contentsOf: dest), Data([1, 2, 3]))

        XCTAssertEqual(IconPreset.allCases.map(\.alternateName), [nil, "IconInk", "IconPaper", "IconCrescent"])
        let kept = MediaEntry(kind: .video, title: "old", remoteURL: "https://example.com/a.mp4")
        let extra = MediaEntry(kind: .video, title: "new", remoteURL: "https://example.com/b.mp4")
        let dup = MediaEntry(kind: .video, title: "again", remoteURL: "https://example.com/a.mp4")
        let merged = PublicRefresh.merge(existing: [kept], incoming: [extra, dup])
        XCTAssertEqual(merged.map(\.title), ["old", "new"])
    }

    func testPublicSources() {
        XCTAssertEqual(PublicLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .youtubeVideo("dQw4w9WgXcQ"))
        XCTAssertEqual(PublicLink.parse("https://youtu.be/dQw4w9WgXcQ"), .youtubeVideo("dQw4w9WgXcQ"))
        XCTAssertEqual(PublicLink.parse("https://www.youtube.com/channel/UCxxxxxxxxxxxxxxxxxxxxxx"), .youtubeChannel("UCxxxxxxxxxxxxxxxxxxxxxx"))
        XCTAssertEqual(PublicLink.parse("https://www.bilibili.com/video/BV1xx411c7mD"), .biliBV("BV1xx411c7mD"))
        XCTAssertEqual(PublicLink.parse("https://www.bilibili.com/video/av170001"), .biliAid("170001"))
        if case .peertube(let host, let id) = PublicLink.parse("https://tube.example.com/w/abc123xyz") {
            XCTAssertEqual(host, "tube.example.com")
            XCTAssertEqual(id, "abc123xyz")
        } else {
            XCTFail("PeerTube 链接没有认出来")
        }
        let space = PublicLink.follow(from: "https://space.bilibili.com/42", instance: "")
        XCTAssertNil(space.0)
        XCTAssertNotNil(space.1)
        let yt = PublicLink.media("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(yt?.kind, .embed)
        XCTAssertTrue(yt?.embedURL?.contains("youtube.com/embed/dQw4w9WgXcQ") == true)
        XCTAssertFalse(yt?.embedURL?.contains("googlevideo") == true)
        let bili = PublicLink.media("BV1xx411c7mD")
        XCTAssertEqual(bili?.embedURL, BiliLinks.player(bvid: "BV1xx411c7mD"))
        XCTAssertFalse(bili?.embedURL?.contains("playurl") == true)
        XCTAssertFalse(DownloadPolicy.canDownload(bili ?? MediaEntry(kind: .embed, title: "b")).ok)

        let xml = """
        <feed><entry>
          <title>月亮 &amp; 海</title>
          <yt:videoId>abcdefghijk</yt:videoId>
          <name>频道</name>
        </entry></feed>
        """
        let videos = FeedXML.youtube(xml)
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos[0].title, "月亮 & 海")
        XCTAssertEqual(videos[0].id, "yt-abcdefghijk")
        XCTAssertEqual(videos[0].kind, .embed)
        let biliXML = "<rss><item><title>片子</title><link>https://www.bilibili.com/video/BV1xx411c7mD</link></item></rss>"
        XCTAssertEqual(FeedXML.bili(biliXML).first?.biliBvid, "BV1xx411c7mD")

        let api = """
        {"items":[{"id":{"videoId":"abcdefghijk"},"snippet":{"title":"检索","channelTitle":"人"}}]}
        """
        XCTAssertEqual(YouTubeAPI.entries(json: api).first?.embedURL?.contains("/embed/abcdefghijk"), true)

        let pt = """
        {"data":[
          {"uuid":"11111111-2222-3333-4444-555555555555","name":"公开","downloadEnabled":true,"files":[{"fileUrl":"https://tube.example.com/a.mp4"}]},
          {"uuid":"nsfw-1","name":"跳过","nsfw":true}
        ]}
        """
        let rows = PeerTubeAPI.entries(json: pt, host: "tube.example.com")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].remoteURL, "https://tube.example.com/a.mp4")
        XCTAssertEqual(rows[0].downloadURL, "https://tube.example.com/a.mp4")
        XCTAssertTrue(DownloadPolicy.canDownload(rows[0]).ok)
        let locked = MediaEntry(kind: .video, title: "yt", platform: PlatformID.youtube, downloadURL: "https://tube.example.com/a.mp4")
        XCTAssertFalse(DownloadPolicy.canDownload(locked).ok)

        XCTAssertNil(PublicLink.media("https://tube.example.com/w/abc123xyz"))
        let pending = LinkResolver.resolve("https://tube.example.com/w/abc123xyz")
        XCTAssertNil(pending.entry)
        XCTAssertNotNil(pending.message)
        let watch = MediaEntry(kind: .video, title: "页", remoteURL: "https://tube.example.com/w/abc123xyz", platform: PlatformID.peertube)
        XCTAssertNil(watch.playbackURL)
        let file = MediaEntry(kind: .video, title: "片", remoteURL: "https://tube.example.com/a.mp4", platform: PlatformID.peertube)
        XCTAssertEqual(file.playbackURL?.absoluteString, "https://tube.example.com/a.mp4")

        let streams = """
        {"data":[
          {"uuid":"hls-1","name":"流","downloadEnabled":true,"streamingPlaylists":[{"playlistUrl":"https://tube.example.com/a.m3u8"}]},
          {"uuid":"empty-1","name":"空","url":"https://tube.example.com/w/empty-1"},
          {"uuid":"dash-1","name":"dash","streamingPlaylists":[{"playlistUrl":"https://tube.example.com/a.mpd"}]}
        ]}
        """
        let extra = PeerTubeAPI.entries(json: streams, host: "tube.example.com")
        XCTAssertEqual(extra.count, 1)
        XCTAssertEqual(extra[0].remoteURL, "https://tube.example.com/a.m3u8")
        XCTAssertNil(extra[0].downloadURL)
        XCTAssertFalse(DownloadPolicy.canDownload(extra[0]).ok)
    }

    func testSmartFillUnderEightPercent() {
        let viewW: Float = 1000
        let viewH: Float = 2000
        let just = viewW / Float(0.92)
        XCTAssertEqual(VideoFit.cropFraction(videoW: just, videoH: viewH, viewW: viewW, viewH: viewH), 0.08, accuracy: 0.002)
        XCTAssertTrue(VideoFit.fill(mode: .smart, videoW: just, videoH: viewH, viewW: viewW, viewH: viewH))
        let over = viewW / Float(0.91)
        XCTAssertGreaterThan(VideoFit.cropFraction(videoW: over, videoH: viewH, viewW: viewW, viewH: viewH), VideoFit.smartMaxCrop)
        XCTAssertFalse(VideoFit.fill(mode: .smart, videoW: over, videoH: viewH, viewW: viewW, viewH: viewH))
        XCTAssertEqual(VideoFit.smartMaxCrop, 0.08, accuracy: 0.0001)
    }

    func testRememberPlaceAndBackdropPages() {
        XCTAssertEqual(FeedPlace.index(enabled: false, savedID: "a", savedIndex: 3, ids: ["a", "b"]), 0)
        XCTAssertEqual(FeedPlace.index(enabled: true, savedID: "b", savedIndex: 0, ids: ["a", "b", "c"]), 1)
        XCTAssertEqual(FeedPlace.index(enabled: true, savedID: "gone", savedIndex: 4, ids: ["a", "b"]), 0)
        XCTAssertEqual(FeedPlace.index(enabled: true, savedID: "", savedIndex: 1, ids: ["a", "b", "c"]), 1)
        var settings = AppSettings()
        settings.rememberPlace = true
        settings.feedMemoryID = "clip"
        settings.feedMemoryIndex = 2
        settings.feedMemorySeconds = 12.5
        let data = try! JSONEncoder().encode(settings)
        let back = try! XCTUnwrap(AppSettings.load(data))
        XCTAssertTrue(back.rememberPlace)
        XCTAssertEqual(back.feedMemoryID, "clip")
        XCTAssertEqual(back.feedMemoryIndex, 2)
        XCTAssertEqual(back.feedMemorySeconds, 12.5, accuracy: 0.01)
        XCTAssertTrue(back.resumeOnReturn)
        XCTAssertTrue(back.revealBlur)
        XCTAssertEqual(ImageHold.label(0), "永久")
        XCTAssertEqual(ImageHold.seconds(0), 0)

        let all = try! XCTUnwrap(AppSettings.load(Data(#"{"backdropAllPages":true}"#.utf8)))
        XCTAssertEqual(all.backdropPages, BackdropPage.allCases.map(\.rawValue))
        let home = try! XCTUnwrap(AppSettings.load(Data(#"{"backdropAllPages":false}"#.utf8)))
        XCTAssertEqual(home.backdropPages, ["home"])
        let kept = try! XCTUnwrap(AppSettings.load(Data(#"{"backdropAllPages":true,"backdropPages":["moments","home"]}"#.utf8)))
        XCTAssertEqual(kept.backdropPages, ["home", "moments"])
        XCTAssertEqual(BackdropPages.summary(["home", "moments"]), "首页、朋友圈")
        XCTAssertEqual(BackdropPages.summary(BackdropPage.allCases.map(\.rawValue)), "全部页面")
        XCTAssertEqual(BackdropPages.summary(["home"]), "仅首页")
        XCTAssertFalse(BackdropPages.shows(.settings, mode: .video, pages: ["home"]))
        XCTAssertTrue(BackdropPages.shows(.home, mode: .video, pages: ["home"]))
        XCTAssertFalse(BackdropPages.shows(.home, mode: .theme, pages: BackdropPages.selectAll()))
        XCTAssertFalse(FanAim.firesOnRelease(select: .tap, drop: false))
        XCTAssertTrue(FanAim.firesOnRelease(select: .tap, drop: true))
        XCTAssertTrue(FanAim.firesOnRelease(select: .slider, drop: false))
    }

    func testBiliHotStubAndSkinPath() throws {
        let json = """
        {"code":0,"data":{"list":[{"bvid":"BV1xx411c7mD","title":"月亮","pic":"https://i0.hdslb.com/a.jpg","owner":{"name":"阿月"},"stat":{"view":1200}}]}}
        """.data(using: .utf8)!
        let parsed = BiliHot.parse(json)
        guard case .success(let items) = parsed else { return XCTFail("热榜没有解析出来") }
        XCTAssertEqual(items.first?.biliBvid, "BV1xx411c7mD")
        XCTAssertEqual(items.first?.title, "月亮")
        XCTAssertEqual(items.first?.embedURL, BiliLinks.player(bvid: "BV1xx411c7mD"))
        XCTAssertFalse(items.first?.embedURL?.contains("playurl") == true)
        XCTAssertTrue(items.first?.author.contains("阿月") == true)
        let denied = BiliHot.parse(Data(#"{"code":-400,"message":"request error"}"#.utf8))
        guard case .failure(let message) = denied else { return XCTFail("错误码应该失败") }
        XCTAssertEqual(message, "热榜暂时无法获取")
        let robots = "User-agent: *\nDisallow: /private\nAllow: /private/ok\n"
        XCTAssertFalse(RobotsRule.allowed(robots: robots, path: "/private/no"))
        XCTAssertTrue(RobotsRule.allowed(robots: robots, path: "/private/ok"))
        XCTAssertTrue(RobotsRule.allowed(robots: robots, path: "/video/1"))

        let folder = MediaStore.skins
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("skin-\(UUID().uuidString).heic")
        try Data([0, 1, 2, 3, 4]).write(to: source)
        let copied = try XCTUnwrap(MediaStore.copy(from: source, folder: folder, ext: "heic"))
        let resolved = try XCTUnwrap(MediaStore.resolve(copied.lastPathComponent, folder: folder))
        XCTAssertEqual(resolved, copied.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved))
        XCTAssertFalse(resolved.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(resolved.contains("Application Support") || resolved.contains("Application%20Support"))
        try? FileManager.default.removeItem(at: copied)
        try? FileManager.default.removeItem(at: source)
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
