# 月光 · iOS

这是 Android 版「月光」（`com.moonlight.feed`）的 iOS 原生 SwiftUI 版本，当前是 **0.3.1**。界面是简体中文。包名 `com.moonlight.feed`，最低系统 iOS 16。

0.3.1 修了一个真机问题：启动后每个按钮都点不动。全屏背景不再参与命中测试，也不再把安全区撑出更新环；按住识别只挂在按钮自己那么大的视图上，不会盖住整页。

0.3 补上定时长按和屏幕中心按住 5 秒的「全部按键」。定时长按默认关闭，到时只执行分配好的、非破坏性的按钮，并可以撤销。0.2 的长按圆环还在：旋转、荷花、星轨、月光和随机。和 Android v5.0 还差什么见 [FEATURE_PARITY.md](FEATURE_PARITY.md)。

这个仓库打出来的是**未签名**的 `.ipa`。没有 Mac、也没有付费 Apple 开发者账号时，用 AltStore 或 Sideloadly，用你自己的 Apple ID 在安装时重新签名，就可以装到自己的 iPhone 上。

应用图标是双马尾、月牙头饰、公主裙的月光女孩。

## 下载未签名 ipa

1. 打开本仓库的 **Actions**。
2. 点进最近一次成功的 **iOS** 工作流（绿色勾）。
3. 在页面底部的 **Artifacts** 里下载 **`Moonlight-unsigned.ipa`**。
4. 把这个文件传到你用来签名的电脑（Windows / Mac 都可以；Sideloadly 和 AltServer 都支持 Windows）。

打了 `v*` 标签（例如 `v0.1.0`）时，同一次工作流会把这个 ipa 挂到对应的 **GitHub Release** 上，也可以从 Release 页面直接下载。

工作流不需要任何密钥。它在 `macos-latest` 上选择当前镜像里最新的稳定版 Xcode，用 XcodeGen 生成工程，在模拟器上跑单元测试，再用 `CODE_SIGNING_ALLOWED=NO` 为通用 iOS 设备打 Release，把 `Payload/Moonlight.app` 打成未签名 ipa。包里不含描述文件，也不申请推送、App Groups、iCloud 或广播扩展。

## 用 Sideloadly 安装

1. 安装 [Sideloadly](https://sideloadly.io)。iPhone 用数据线连上电脑，并在手机上点「信任」。
2. 把 `Moonlight-unsigned.ipa` 拖进 Sideloadly。
3. 填你的 Apple ID。免费 Apple ID 即可，不需要付费开发者计划。
4. 点 Start。Sideloadly 会用你的 Apple ID 重新签名并安装。
5. 手机上如果提示不受信任的开发者：打开 **设置 → 通用 → VPN 与设备管理**，信任你的 Apple ID。
6. 免费证书大约 7 天过期。过期后用同一套步骤再装一次即可。

## 用 AltStore 安装

1. 按 [AltStore 的说明](https://altstore.io) 在电脑上安装 AltServer，在 iPhone 上安装 AltStore。
2. 把 `Moonlight-unsigned.ipa` 传到手机（隔空投送、文件、或网盘均可）。
3. 在手机上用「分享」把这个 ipa 交给 AltStore，或在 AltStore 里点 **+** 选择该文件。
4. 用你的 Apple ID 登录。AltStore 会重新签名并安装「月光」。
5. AltServer 开着时，AltStore 可以在证书快过期时帮你刷新。

安装后的显示名称是「月光」。首次打开会向你要相册、相机和麦克风权限，分别用于导入、拍摄和录像。

## 0.1 里有什么

五个底栏：**首页 · 发现 · ● · 朋友圈 · 我**。首页是上下翻页的全屏影像，可以导入相册，也可以从 Archive.org、NASA、维基共享资源拉取公开内容。Pexels / Pixabay 只有在「我 → 设置」里填了你自己的密钥时才会请求。

长按是圆环菜单。默认动画是**星轨**（按钮从高处沿螺旋飞入，由小变大，带着星尾，落地略微过冲，停稳后一定是完整大小）。设置里可以改成旋转、荷花、月光，或随机。点选是默认；拖动选择在设置里打开。背景可以是透明、轻度模糊或模糊。删除只出现在「危险」分组里，并可以撤销。

朋友圈里的好友是虚拟的，每一句聊天都由你来写。数据保存在本机的 JSON 里。聊天服务器按协议留了空接口，**连接**按钮是关着的，不会联网。

和 Android 版逐项对照见 [FEATURE_PARITY.md](FEATURE_PARITY.md)。

## 明确不做的事

不调用哔哩哔哩的 playurl / WBI，不解析、不下载别人的直播流，不绕过 DRM。YouTube、Vimeo、Dailymotion、哔哩哔哩只打开官方嵌入页。`.m3u8` / `.mpd` 会被拒绝。

## 本地开发

需要 Mac 和 Xcode 16 或更新版本：

```bash
brew install xcodegen
xcodegen generate
open Moonlight.xcodeproj
```

`Moonlight.xcodeproj` 不入库，由 `project.yml` 生成。单元测试在 `MoonlightTests`。
