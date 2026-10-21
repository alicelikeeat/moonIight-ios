# 功能对照（Android v5.0 → iOS）

状态：**done** 已有可用行为，**partial** 有一部分，**todo** 还没有。

对照的是 Android「月光」**v5.0** 的 `docs/INTERACTION.md`。iOS 按里程碑往上补，原生能力用 iOS 的做法（ReplayKit、后台 URLSession、BGAppRefreshTask、备用图标），不搬 Android 的 MediaProjection / WorkManager。

侧载约束不变：没有付费开发者账号也能装。不用推送、App Groups、iCloud、广播扩展。

## v5.0 里程碑

| 块 | iOS | 说明 |
| --- | --- | --- |
| 圆环四种动画 + 随机，星轨 v5，次级弧，⋯ 面板，标签长按，媒体上深色玻璃 | done | 0.2。星轨从天空旋转落下，速度 0.5×–2×，停稳必为原大 |
| 定时长按 / 中心按住 5 秒全部按键 | done | 0.3。读数、倒计时、5/10/自定义、各场景自动执行且不包含删除、撤销、中心 5 秒全部按键、移动取消 |
| 录屏（只录本应用） | todo | 将用 ReplayKit `RPScreenRecorder`，不是系统全屏投影 |
| 按键背景（29 个 id） | todo | |
| 朋友圈自动播放、头像封面焦点、首页背景 | partial | 赞/踩、静音小窗已有；没有「全部 / 指定 / 关闭」和焦点编辑器 |
| 碎纸机与最近删除 | todo | |
| 主动下载，杀进程后续传 | partial | 直链能下，没有后台会话和 Range 续传 |
| 备用图标 | todo | iOS 不能用任意照片当主屏幕图标，只能切换包内预设 |
| 后台刷新公开源 | todo | 将用 `BGAppRefreshTask`，系统不保证何时跑 |

## 壳与视觉

| Android | iOS | 说明 |
| --- | --- | --- |
| 五栏：首页 / 发现 / 拍摄 / 朋友圈 / 我 | done | 中间是圆点拍摄 |
| 浅色 / 深色 / 跟随系统 | done | 设置里切换 |
| 月光玻璃、暖色强调 | partial | 毛玻璃、月色强调、夜色背景已有；不是 Android 色板的逐值复刻 |
| 菜单在影像上用深色玻璃，其它地方跟主题 | done | 0.2。首页内容和正在看首页时的标签长按用深色；朋友圈、库、我跟随主题 |
| 8pt 网格、中文文案 | partial | 文案是简体中文；间距按 8pt 习惯，没有逐屏对像素 |

## 手势语言

| Android | iOS 0.1 | 说明 |
| --- | --- | --- |
| 单击 = 主操作 | done | 视频单击播放/暂停，其它单击显隐装饰 |
| 双击 = 喜欢，从不取消 | done | 首页和动态都是 `likeOnly` |
| 上滑下一条 | done | 首页纵向整页翻 |
| 左滑信息 | todo | 信息在圆环的「更多」里 |
| 捏合铺满 / 还原 | partial | 没有捏合手势。全局有智能 / 完整 / 铺满；单条可在「更多 → 播放」里在铺满、完整、跟随设置之间切换 |
| 首页空白处长按 | done | 筛选、随机一条、重新洗牌、回到顶部；更多里可以静音 |
| 圆环最多 4 项 + 中心 … | done | 超出的进底部面板 |
| 点选；拖动选择为设置 | partial | 拖动按落定后的槽位命中，不跟星轨飞行中的位置 |
| 背景：透明 / 轻度模糊 / 模糊 | done | |
| 删除只在危险分组，可撤销 | done | 不放在圆环上 |
| 触感 | done | 轻触、落地、选中、确认、警告 |
| 定时长按 | done | 0.3。默认关。到时执行该场景分配的按钮，删除不可分配，可撤销的给出撤销 |
| 屏幕中心按住 5 秒 | done | 全部按键：当前内容、页面、全局。和定时长按互斥，中心优先 |
| 手指挪开取消计时 | done | 超过 24pt 取消两层计时，圆环和拖动选择还在 |

## 长按动画

| Android | iOS | 说明 |
| --- | --- | --- |
| 星轨 v5：从天空旋转落下，螺旋加速，视差，过冲，光圈和扫光，停稳必为原大 | done | 0.2。速度 0.5×–2× |
| 旋转，可过冲，结束必为原大 | done | |
| 荷花（内 5 外 8，收起下沉） | done | 玻璃花瓣 |
| 月光（约 95% 压暗，忽略菜单背景） | done | |
| 随机 | done | |
| 减弱动态 → 淡入 | done | |
| 旧名 BLUR / FALL → 星轨，SHATTER → 荷花 | done | |
| 次级弧；超过 6 个改成列表 | done | |
| 按键背景 | todo | |

## 首页与播放

| Android | iOS 0.1 | 说明 |
| --- | --- | --- |
| 相册导入照片 / 视频 | done | PhotosPicker |
| Archive.org 公开 MP4 | done | advancedsearch + metadata，优先 ≥100KB 且不含 sample 的较小 mp4 |
| NASA 影像 | done | images-api，优先 `~medium.mp4`，其次 `~mobile` |
| 维基共享资源 | done | `generator=search`，`filetype:bitmap\|video` |
| Pexels / Pixabay | done | 仅当用户在设置里填写自己的密钥 |
| PeerTube | todo | |
| YouTube RSS 发现 | todo | 粘贴官方链接会打开嵌入页 |
| 哔哩哔哩热门 / WBI / playurl | todo | 故意不做。粘贴 BV 只打开 `player.bilibili.com/player.html` |
| 网页爬虫 | todo | 其它 http(s) 当作网页嵌入 |
| AVPlayer / Exo 播放 | done | 单击在结束、暂停、缓冲时都能恢复 |
| 退到后台暂停 | done | |
| 视频显示：智能 / 完整 / 铺满 | done | 智能：裁切比例 ≤ 0.08 才铺满。手机用例与 Android 单测一致 |
| 倍速、静音、循环 | done | |
| 图片停留 3 / 5 / 8 秒 | done | |
| 保存到相册、分享、下载 | partial | 直链文件用 URLSession 下载一次，没有断点续传 |
| 官方嵌入（YouTube / Vimeo / Dailymotion / 哔哩） | done | 只用官方嵌入 URL，WKWebView |
| 拒绝 m3u8 / mpd | done | |
| 首页动态背景视频 | partial | 可以把一张图设为背景，还不能播视频背景 |
| 计数跳转 | done | |

## 库与拍摄

| Android | iOS 0.1 | 说明 |
| --- | --- | --- |
| 库：全部 / 收藏 / 下载 | done | |
| 库内长按圆环 | done | |
| 多选 | todo | 点了会提示还在后面的版本 |
| 系统相机拍照、录像 | partial | `UIImagePickerController`，不是自定义相机 |
| 从拍摄页导入、发朋友圈 | done | |

## 朋友圈与聊天

| Android | iOS 0.1 | 说明 |
| --- | --- | --- |
| 虚拟好友 | done | 不会发到服务器 |
| 以自己或好友的身份发动态 | done | |
| 赞 / 踩互斥 | done | |
| 评论 | partial | 系统弹窗写一条，没有楼中楼界面 |
| 动态里静音自动播放，单击暂停，长按全屏 | done | |
| 示例好友 | done | 阿月、小林、Nova、山野、星河 |
| 本地聊天，每一句由用户写 | done | 发言人菜单 |
| LocalTransport | done | 发送后状态为已发送 |
| RemoteTransport | partial | 按协议留了路径，`active = false`，发送失败并提示只保存在本机。不发起网络请求 |
| 自动回复默认关闭，且不会连环回复 | done | |
| 未读、已读、schema 1 导入不刷未读 | done | 缺 `readAt` 时用 `Int64.max/2` |
| 消息排序 `serverAt ?? createdAt` | done | |
| 撤回、改发言人、复制 | done | |
| 聊天图片 | partial | 示例数据里有图；输入栏这版只发文字 |
| WebSocket、同步、上传、已读回执联网 | todo | 设置里的「连接」是禁用的 |
| social.json 导出 / 导入 | done | 按 id 合并，并把对方的 selfId 映射到本机 |
| 原子写入 | done | 250ms 合并，临时文件 + fsync + 替换，离开前台会立刻写 |

## 我

| Android | iOS 0.1 | 说明 |
| --- | --- | --- |
| 头像、封面照片 | done | |
| 名字、简介 | done | |
| 头像 / 封面位置 | partial | 长按可以微调一个步进，没有拖拽裁切 |
| 头像 / 封面视频循环 | todo | 长按「播放」会说明还在后面的版本 |
| 恢复上一张 | done | |
| 上面这些设置项 | done | 主题、画面、背景、点选/拖动、动画、密钥、示例数据 |

## 明确排除

- 哔哩哔哩 playurl、WBI、任何需要拆流的地址
- DRM 绕过
- 推送、App Groups、iCloud、广播扩展（侧载用的未签名包不能带这些）
