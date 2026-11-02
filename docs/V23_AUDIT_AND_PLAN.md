# 月藏图 V2.3 审计与实施记录

基线：V2.1 开发分支 aa0d691（PR #6，尚未合并 main）；独立分支 `feature/treasure-map-v2-3`。最低 iOS 16，Swift 6，当前 SDK 对 iOS 26 原生玻璃使用可用性分支。先阅读 AGENTS.md、任务书、源码和工作流，再实施以下修改。

## 原有实现及依赖

| 范围 | 原入口 / 状态 | V2.3 处理 |
|---|---|---|
| 自由散落 | MoonTreasureMapView → MoonTreasureScene；CoreMotion 重力、shake、碰撞、惯性；touches 长按 0.5 秒、移动 >10pt 取消；每指保存物理属性 | 保留场景实现；常驻 SKView，墙模式暂停而不重建，数据变更才同步 |
| 整理与数量 | treasure-organized；treasure-count；6/12/20/30/42 张，物理上限 42 | 独立于视频墙 10 个上限，保留 |
| 自由卡片预览 | TreasureVideoPreviews → AVQueuePlayer/AVPlayerLooper，最多 3 路，全静音 | 独立保留，墙模式停止并断开 SpriteKit 视频节点 |
| 普通媒体播放 | RootView.MediaPlayerView / FillVideoPlayer，普通队列、图片、网页 | 保留，不调用墙的队列或选择状态 |
| 旧复杂播放 | TreasureDirectedPlayback.swift、TreasurePlaybackPlan.swift；目标范围、确认自动播、重进自动播、图片定时、声音组合，仅月藏图使用 | 删除这两个运行文件及调用；历史文档不改写。背景类型分离并只迁移背景值，不迁移旧播放状态 |
| 导航 | 库内嵌月藏图入口；全局 treasureMap / treasurePlayback 命令 | “我”页面库下方独立全屏 NavigationStack；移除库内嵌入口。旧命令 raw value 保留兼容已保存菜单，显示名及路由改为“视频墙” |
| 搜索 | AppCommand 别名、MediaSearchIntent、发现页 | 搜索“视频墙”直接进入墙；媒体搜索和普通库保持原路径 |
| 旧 15 引用 | random15、虚拟动态最小 15 分钟、导航 15 秒等 | 均为其他功能，不是墙上限，保留；墙的唯一选择上限为 10 |

## 文件职责与决策

- `TreasureVideoSelectionModel.swift`：Foundation 纯策略；默认目标 4、空选择、不自动填充；去重、选择第 11 个拒绝、恢复超限截断并提示、删除剔除。顺序队列、无重复洗牌与跨轮避重、列数和可见项预算共享给测试。
- `TreasurePlaybackCoordinator.swift`：顺序 / 随机单播放器；同时模式只加载可见交集，按内存、低电量、热状态限流（1–6 路预算），选择仍可保留 10 个。单项 540p / 800kbps 偏好及 2 秒前向缓冲为系统建议，不保证远端必定提供该码率。
- 同时模式通过非交互 UIView marker 观察原生滚动视口交集判断可见性，不能将 LazyVGrid 预加载的 onAppear 当作真正可见。放大时只保留聚焦项播放器，返回网格按可见项恢复。
- 所有播放器先静音再分配唯一音轨；soloAmbient 尊重静音键。暂停保持已加载视频位置，切模式 / 停止 / 退出清理播放器、异步任务、KVO 和通知，并恢复进入前的共享音频会话配置；后台 / 中断 / 耳机拔出 / 远程网络断开暂停并释放，用户显式点击恢复（从当前视频开头）。
- `TreasureVideoWallView.swift`：原生可搜索选择器，显示已选序号、清空、上限反馈；三模式、循环、统一控制、滚动网格、聚焦和音轨；复用 MoonGlass，不新增一套视觉组件。
- `TreasureAppearance.swift`：系统 / 纯色 / 黑紫背景独立保留；升级只读取旧 JSON 中的背景字段。
- 自由卡片只读导出物理位置，原生玻璃底层独立刷新，触摸仍交给 SpriteKit。动态字体适当放大物理卡片；VoiceOver 使用整理布局的逐项打开与操作。
- `RootView.swift`：独立个人页入口和真实 H264 DEBUG 资源；普通媒体库、播放器无业务改写。
- PBX 显式注册新文件；GitHub 工作流编译纯模型与专项 UI，旧 V2.1 测试替换为 V2.3 语义，物理、搜索和其他页面回归保留。

## 目前验证

发布快照 4ff14ba 已通过 GitHub 模拟器编译、358 项策略检查及 36 项 UI；设备归档与未签名 IPA 的版本 / 架构已核对。完整证据、历史失败和真机项见 [V23_VALIDATION.md](V23_VALIDATION.md)。本地 Linux 无 Xcode，未在本地编译 iOS，未宣称真机验收。
