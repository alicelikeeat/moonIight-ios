# v1.78 触摸冲突修复说明

## 分层（自下而上）

1. RealityKit 世界（`Glass3DWorldView`）
2. 方块原生玻璃层（`Glass3DNativeGlassLayer`，`allowsHitTesting(false)`）
3. UIKit 手势层（`Glass3DGestureLayer`：捏合、旋转、双指拖动、单指拖动、轻点、长按）
4. 准星与移动手柄（`Glass3DOverlay`；准星不接收触摸，手柄接收拖动）
5. SwiftUI HUD（顶栏、工具、摇杆、按钮、面板、选中工具组）

上层控件先拿到触摸；没有被上层接收的触摸才到手势层。

## 修复

| 问题 | 修复 | 位置 |
|---|---|---|
| 玻璃面板中按钮之间的空白处点击穿透到世界，可能选中方块或平移相机 | `.panel` 玻璃加 `contentShape(形状)`，空白处由面板吸收；状态条 `.light` 和底座 `.base` 不加，仍然穿透 | `RPGHUD.swift` `RPGHUDGlassModifier` |
| 装饰玻璃使用交互玻璃 | `MoonGlassBackdrop`、准星、摇杆底盘改为非交互；它们都 `allowsHitTesting(false)` 或只做底座 | `MoonGlass.swift`、`Glass3DView.swift`、`RPGHUD.swift` |
| 移动手柄拖动被系统取消（来电、切后台）后，标签停在 “+3” | 拖动状态改为 `@GestureState`，取消时自动清空，且只有正常结束才移动 | `Glass3DOverlay` |
| 选中工具组融合期间连点会重复执行 | 同一操作 0.3 s 内只执行一次 | `Glass3DSelectionBar` |

## 保持不变（经源码核对）

- 双指捏合、旋转、双指拖动可同时识别；单指拖动、轻点、长按各自独立；轻点等待长按失败（长按 0.45 s，移动超过系统阈值即失败，不阻断滑动）。
- 摇杆用 `@GestureState`，手势结束和取消都会回中并把输入清零；世界进入后台时控制器也清零摇杆。
- 没有全局禁用任何手势。

## 未验证

以上是源码层面的修复和核对。真机上的误触、吞触摸和长按与滑动的手感没有测过，见真机清单。
