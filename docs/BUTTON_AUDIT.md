# V2.1 搜索、按钮与玻璃审计

全量静态清单覆盖 307 个控件、提交及自定义手势入口，包含 SpriteKit touches 生命周期；声明在 [CONTROL_INVENTORY.md](CONTROL_INVENTORY.md)，可由 `python3 scripts/audit_controls.py` 重建。静态定位 handler 不代表已逐个真机测试；系统照片选择器、相机、键盘、分享、原生菜单与网页播放器的内部按钮由系统/来源管理，不重复包自绘玻璃。

| 位置 / 控件 | 预期动作 | 实际 handler / 目标状态 | 本次处理 | 验证状态 |
|---|---|---|---|---|
| 首页 / 底部智能搜索输入 | 搜索功能或显式搜索媒体；其余问题进入 AI | AssistantDock.submit → AppCommand / pendingMediaSearch / onOpen | 增加精确功能名、中文媒体搜索意图；明确“问 AI”保留对话 | 41308317613 扩展搜索 UI 已通过：月藏图、定向设置、带类型媒体搜索 |
| 全局长按搜索 / 功能气泡、回车 | 同一命令路由，带回原页面 | GlobalAssistantSearchOverlay → model.send → RootView.route | 增加月藏图、定向播放、媒体搜索，统一回车语义 | 共享命令路由经底部输入 UI 验证；全局浮层独立操作待验 |
| 全局搜索目录 | 列出可在无选中媒体上下文执行的功能 | AssistantCommands.matching → AppCommand.allCases + searchTerms | 别名支持库/相册/收藏/声音/定向播放；需要具体媒体的四项操作不冒充全局入口 | 静态目录已核对；月藏图命令 UI 已通过 |
| 发现 / 搜索框、搜索按钮、清除 | 保留所选内容源；关键词、媒体类型正确 | query / kindFilter → mediaStore.searchDiscover / clearDiscoverySearch | 接收统一请求与焦点；视频类型包括合法网页视频条目 | 解析检查、图片类型/关键词传递与清除 UI 已通过 |
| 月藏图 / 定向播放选择器搜索 | 按标题或平台筛选目标，保留原列表顺序上下文 | TreasureDirectedSettings.query → matches；plan 使用完整 source 的稳定 ID | 新增原生 searchable，过滤只影响选择，不改变连续队列 | 稳定队列策略检查已通过；选择器输入过滤待人工验收 |
| 月藏图 / 定向播放入口、确认、播放已选目标 | 选择媒体/收藏/队列/文件夹，明确确认后启动 | showingDirectedSettings / pendingDirectedRequest / directedRequest | 新增；失效目标明确提示，禁止无目标启动 | 策略检查与定向播放 UI 已通过；远程来源待真机抽验 |
| 定向播放器 / 暂停、继续、下一条、停止、关闭 | 各自播放操作，不跳搜索 | TreasureSequenceSession 对应方法 | 新增并在退出/后台清理或暂停，图片无视频音轨 | 暂停/继续/下一条/停止 UI 已通过；真机音频待验 |
| 月藏图 / 自由-整理、数量、重新散落、重置 | 更新布局/投放/物理，不跳搜索 | organized / dropCount / scatterTreasures / configureScene | 保留；工具栏一个主玻璃，内部按钮透明 | 拖拽 / 网格长按通过；预览 41318796387 单独通过，41314178974 的两次超时保留记录 |
| 月藏图 / 视频自动预览开关 | 静止封面或小量静音预览 | videoAutoplay → TreasureVideoPreviews | 保留 V2.0 卡片预览，与 V2.1 连续播放数量分开 | 拖拽 / 网格长按通过；预览 41318796387 单独通过，41314178974 的两次超时保留记录 |
| 底部圆形导航 / 点击、长按、横滑 | 原标签切换与配置菜单 | PriorityTabView / NativeSlidingTabBar / RootView.selectTab | 继续由原生透明命中层接收，不添加捕获触摸的装饰层 | 27 项滚动 / 导航回归通过；真机待验 |
| 收藏 / 下载 / 库 | 正确本地筛选，不误触搜索 | MeView.commandPath → LibraryView.initialAction → filter | 原路由保留；可从全局搜索命令进入 | 既有库导航回归 |
| 播放器 / 关闭、队列推进、分享 | 播放、退出、分享至动态 | MediaPlayerView 既有 onQueueAdvance/onShareToMoments | 非搜索功能保留；现有播放器没有独立媒体搜索按钮，不新增空入口 | 既有播放回归；真机待验 |
| 相机 / 导入、系统相册 | 触发设备能力检查、系统选择器或导入 | openCamera / rootImporter / PhotosPicker | 保留独立行为；系统内部控件不包第二层玻璃 | 既有相机/相册回归 |
| 个人资料 / 设置 / 背景编辑 / 菜单设置 | 对应导航与状态写入 | 现有 NavigationLink / AppCommand / BackgroundStore | 保留；普通操作继承玻璃，已有玻璃表面显式 plain，未强制跳转搜索 | 41319398844：修正测试的懒加载 / 底栏定位后四项诊断全部通过，0 失败；真机待验 |
| 智能输入栏 / 全局搜索清除 | 清空输入，不提交或丢失焦点 | draft / query = 空字符串 | 新增明确名称与 identifier，内部透明，44pt 命中 | 发现页清除 UI 已通过；底部及浮层清除与组合输入待人工验收 |

## 单层材质与输入

- `MoonGlassBackdrop`：iOS 26+ 原生 glassEffect，iOS 16–25 系统 regularMaterial；降低透明度时改系统实色，增强对比度时加一条细边。
- `moonGlassContainer` 环境标记使玻璃面板内部按钮不叠加第二层主材质。已有底部圆形与媒体内容使用显式 plain；原生 UITabBar、系统导航栏保留系统材质。
- 搜索输入使用原生单行 TextField 处理回车，不监听文本换行自动发送；正文聊天仍保留多行，避免中文组合输入或粘贴误提交。
- 智能输入框与全局搜索框使用 `MoonSearchBubble`，只缩放背景装饰 1→1.025→1；输入布局、光标与组合文字不做 scale/offset。焦点与提交各触发一次短动画，减少动态效果时只有淡入淡出。
- 装饰层统一 `allowsHitTesting(false)` / accessibilityHidden；按钮、键盘与原有滑动手势保持原命中路径。

## 空 handler 核对

静态扫描发现 5 个空闭包均为系统对话框 `Button(..., role: .cancel)`。它们的预期动作是系统自动关闭对话框，不是失效按钮，不应改成搜索入口。头像、封面和媒体内容的 plain 控件保留清晰内容；“我”的资料/入口组改为一个共享玻璃容器，内部导航保持透明。

## 人工真机待验

系统静音键、耳机拔插、中断/后台、中文输入法组合候选、VoiceOver、减少动态/透明度、iOS 16 与 iOS 26 的材质实际外观、低性能设备的掉帧与功耗。当前不声称这些已通过。
