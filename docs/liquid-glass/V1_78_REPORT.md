# v1.78 界面回归：与 v1.77 基线对比

目的：判断 v1.78（Liquid Glass）界面自动测试里的失败，是 v1.78 引入的，还是之前就有。

| | v1.77 基线 | v1.78 |
|---|---|---|
| 运行 | [42000854743](https://github.com/alicelikeeat/moonIight-ios/actions/runs/42000854743) | [41983108331](https://github.com/alicelikeeat/moonIight-ios/actions/runs/41983108331) |
| 源码 | `f90ea38`（分支 `claude/v1.77-ui-baseline`） | 分支 `feature/v1.78-liquid-glass` |
| 模拟器 | GitHub Actions macos-latest，Xcode 26.6 | 同左 |

## 各组结果

| 测试组 | v1.77 | v1.78 |
|---|---|---|
| RPG 舞台（16 项） | 3 项失败 | 4 项失败 |
| 寻宝浏览（3 项） | 全部通过 | 全部通过 |
| 设置界面（4 项） | 1 项失败（`testButtonBackgroundPlaylistPersists`） | 全部通过 |
| 卡片滚动（31 项） | 20 项失败 | 19 项失败 |
| 斗地主、V2.3 视频墙 | 前一组失败后跳过 | 跳过 |

## 两个版本都失败（不是 v1.78 引入）

失败信息逐条相同：

- `testSandboxLaunchControlCenterAndPortraitPages`：布局方向、控制中心遮挡。
- 卡片滚动类：
  - `testCardScrollsWithLongPressDisabled`、`testDiscoverSingleColumnCardScroll`
  - `testDiscoverTwoColumnFast/SlowCardScroll`、`testHoldOnPageAndSwipeOnHeaderButton`
  - `testStationaryHoldOpensRingAndReleaseKeepsItOpen`
  - 共同现象：滚动距离是 0。
- `testBubbleLongPressKeepsMenuInteractive`、`testShortTapStillOpensPlayer`
- `testFullBlindModeKeepsOnlyBackgroundSearchAndTripleTapExit`
- `testHiddenDockDoesNotCoverCardSwipe`
- `testHoldOnNavigationAndOrdinaryButtonDoesNotTapThrough`

推断：v1.63 起应用直接打开 3D 世界，这些测试仍按旧的首页 / 发现页流程操作。它们需要另外更新测试，与 Liquid Glass 改动无关。

## 只在 v1.77 失败

- `testBottomHoldAvoidsNavigationAndCameraOffersCaptureOptions`：系统相册选择器没有关闭按钮。
- `testButtonBackgroundPlaylistPersists`：列表项被导航栏遮住。

v1.78 中这两项通过。可能是偶发，也可能是 v1.78 的触摸修复起了作用；只跑了一次，不能确定。

## 只在 v1.78 失败

`testRPGAuthoredCutsceneProducesFramesAndResumesMuted`（`ScrollGestureTests.swift:78`）：

- 现象：25 秒内没等到过场视频的第一帧。
- v1.77：这项 69 秒通过。v1.78：用时 150 秒。
- v1.78 运行里，每次读取界面层级都要约 10 秒，整轮测试也慢了约 30%（RPG 组 849 秒对 640 秒）。
- 结论：可能是模拟器负载造成的超时，也可能是 v1.78 的玻璃效果让过场页更重，只靠这两次运行无法区分。

复查：在 `claude/v1.81-world-director`（包含 v1.78–v1.81 的全部改动）上单独重跑 RPG 组，结果见下节。

## 复查结果

运行 [42009541013](https://github.com/alicelikeeat/moonIight-ios/actions/runs/42009541013)：分支 `claude/v1.81-world-director`，提交 `c33c705`，只跑 RPG 组。

- 16 项中 15 项通过。
- `testRPGAuthoredCutsceneProducesFramesAndResumesMuted` 通过，用时 69 秒，与 v1.77 相同。
- 唯一失败的是 `testSandboxLaunchControlCenterAndPortraitPages`，失败信息与 v1.77 基线完全相同。

## 结论

- 没有发现由 v1.78 引入的界面回归。v1.78 那次的过场测试失败，是运行变慢导致的超时。
- 仍然失败的项目在 v1.77 就已失败，测试本身没有跟上 v1.63 起的启动流程（应用直接进入 3D 世界）。需要单独更新测试，本次没有修改。
- 自动测试只在模拟器上运行，不代表真机结果。
