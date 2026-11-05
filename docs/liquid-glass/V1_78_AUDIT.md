# Moonlight v1.78 Liquid Glass 审计报告

基准：tag `v1.77` = 提交 `f90ea38`（与分支 `claude/moonlight-ios-v160-3d` 头部、GitHub Release v1.77 的源码快照一致，工作区干净）。
开发分支：`feature/v1.78-liquid-glass`（从 `f90ea38` 创建）。
审计方式：逐个阅读下列源码；没有在真机或模拟器上运行，下面的“问题”均为源码证据，不是运行观测。

## 1. 已实现、可复用的部分

| 位置 | 现状 |
|---|---|
| `Features/RPG/UI/RPGHUD.swift` `RPGHUDGlassModifier` / `hudGlass` | iOS 26 用系统 `glassEffect`，iOS 16–25 用系统材质；按 `RPGHUDGlassStyle.resolve`（纯逻辑，有测试）在 regular / clear / 实色之间选择；跟随深色、增强对比度、降低透明度、低电量。HUD 统一入口，3D 世界和 2D 沙盒都在用。 |
| `RPGGlassGroup` | iOS 26 下包一层 `GlassEffectContainer`，低版本直接显示内容。 |
| `RPGPressStyle` | 按压缩放，遵守“减弱动态效果”。 |
| `Glass3DNativeGlass` + `SpatialFaces` | 把最近若干方块的可见面投影到屏幕，合成一条路径，用一层 `.clear` 原生玻璃绘制；角色在方块前方时从玻璃中挖掉；媒体面不覆盖；面数按画质预算（高 360 / 标准 220 / 性能 0）。 |
| `NativeGlassFade` | 相机移动或震屏时淡出原生玻璃、静止 0.2 秒后淡入，下面的 3D 玻璃方块同时加深补位。有测试。 |
| `Glass3DController.frame` | RealityKit `SceneEvents.Update` 驱动（无则 CADisplayLink），同一帧里先放相机再算玻璃投影，状态顺序正确。 |
| `Glass3DGestureLayer` | UIKit 手势：双指捏合 / 旋转 / 双指拖动可同时识别；单指拖动、轻点、长按各自独立；轻点等待长按失败。HUD 按钮在其上层，先拿到触摸。 |
| 摇杆 `RPGJoystick` / `Glass3DStick` | `@GestureState` 在手势结束和取消时都会复位；`onDisappear` 归零。世界隐藏时 `setSuspended` 清零摇杆输入。 |

## 2. 问题与证据

| # | 位置 | 证据 | 影响 |
|---|---|---|---|
| A1 | `MoonGlass.swift` `MoonGlassBackdrop` | 装饰背景 `.allowsHitTesting(false)`，却使用 `.regular.interactive()` | 交互玻璃永远收不到触摸，只是多余状态；不符合“装饰背景不得无条件使用 interactive” |
| A2 | `RPGSelectionGlass.swift` | iOS 26 上 `accessibilityValue` 报 `native`，实际只画三层描边和阴影，没有任何原生玻璃 | 状态语义不真实（UI 测试 `ScrollGestureTests` 断言该值为 `native`） |
| A3 | `Glass3DView.swift` 摇杆 | 底盘和摇杆头各一层 `.interactive` 玻璃，叠在一起，没有共享容器 | 同一控件两层原生玻璃；底盘本身不是按钮也是交互玻璃 |
| A4 | `Glass3DOverlay` 锁定准星 | `.hudGlass(.interactive)` 但 `.allowsHitTesting(false)` | 同 A1 |
| A5 | `Glass3DOverlay` 移动手柄 | 拖动状态 `dragging` 只在 `onEnded` 清空；手势被系统取消时不会清空，标签停留在 “+3” 之类 | 取消后残留错误触摸状态 |
| A6 | `Glass3DNativeGlass.update` | 相机静止时每帧都重新计算并 **发布** 新路径（即使完全相同） | SwiftUI 每帧重绘原生玻璃层，增加 CPU/GPU 成本，没有可见收益 |
| A7 | `Glass3DController` 视图尺寸 | 旋转屏幕时 `viewSize` 经 `onChange` 更新，玻璃淡出逻辑只看相机，不看尺寸 | 横竖屏切换的几帧里玻璃按旧尺寸投影，可能明显错位 |
| A8 | 世界暂停 / 恢复 | `setSuspended(false)` 没有重置 `NativeGlassFade` | 恢复时玻璃立即以旧形状全亮显示，直到下一帧更新 |
| A9 | `Glass3DRenderer.camera` | 投影按 **垂直** 视场计算，渲染相机没有显式声明视场方向 | 若系统默认不是垂直方向，竖屏时投影与渲染不一致（需真机确认；显式声明无副作用） |
| A10 | `Glass3DRenderer.showSelection` | 选中框不带方块的 `yaw` 旋转，是 30% 黄色实心盒，没有轮廓 | 旋转过的方块选中框歪斜；“清晰稳定的选中轮廓”不足 |
| A11 | `hudGlass(.panel)` 工具栏 / 面板 | 面板背景没有 `contentShape`，按钮之间的空隙点下去会穿透到下面的 `Glass3DGestureLayer` | 点玻璃面板空白处可能选中方块或平移相机 |
| A12 | 3D 选中后操作 | 选中后只有属性面板（可关闭）和移动手柄；没有就近的“编辑 / 复制 / 取消选中”玻璃操作组；没有收拢 / 展开 | 不满足 P3 5.1、P2 4.1 |
| A13 | 动画参数 | `Glass3DView` 有 3 处 `.spring(response: 0.35, dampingFraction: 0.86)`，`MoonSearchBubble`、`RPGPressStyle`、`Glass3DChipStyle` 各自硬编码时长；`Glass3DChipStyle` 不看“减弱动态效果” | 参数分散，部分不遵守 Reduce Motion |
| A14 | 性能指标 | 只有 FPS 和原生玻璃面数；没有玻璃更新次数 | 无法在真机上对比 v1.77 的玻璃成本 |

## 3. 修改计划（按阶段）

- **P1 统一玻璃系统**：在 `RPGGlassWorld.swift` 增加纯逻辑的材质角色 `MoonGlassRole`（regular / clear / solid）和 `RPGHUDGlassKind.base`（非交互底座：摇杆底盘、准星）；`MoonGlassBackdrop` 去掉 interactive（A1）；摇杆底盘改用 `.base` 并与摇杆头放进同一 `GlassEffectContainer`（A3）；准星改 `.base`（A4）；面板类玻璃加 `contentShape` 吸收空白处触摸（A11）；`RPGSelectionGlass` 改为真正的环形原生玻璃（中间留空，不遮内容），降低透明度时报 `fallback`（A2）。
- **P2 融合动画**：`MoonGlassMotion` 集中管理动画参数并统一处理 Reduce Motion（A13）；新增 3D 选中操作组 `Glass3DSelectionBar`：收拢为一个玻璃胶囊，展开为编辑 / 复制 / 删除 / 取消选中，使用 `GlassEffectContainer` + `glassEffectID` + `glassEffectTransition` 原生融合（A12）；切换期间禁止重复触发。
- **P3 3D 与玻璃**：选中轮廓带旋转并加边线（A10）；投影只在路径变化时发布（A6）；尺寸变化、暂停恢复时重置淡入淡出（A7、A8）；渲染相机显式垂直视场（A9）；“复制”对独立方块按选区宽度平移复制、对建筑沿用已有 `copyGroup`，都可撤销。
- **P4 触摸**：A5、A11 修复；检查手势委托；后台 / 中断清理。
- **P5 无障碍**：新组件补 VoiceOver 标签、动态字体上限、降低透明度实色、增强对比度描边。
- **P6 回归与性能**：逻辑测试新增 P43；性能计数 `GlassPerfMeter`（每秒玻璃路径发布次数）显示在 3D 世界状态行，供真机 A/B 记录；云端编译与 UI 回归（模拟器）；真机清单。

## 4. 回归风险

| 风险 | 缓解 |
|---|---|
| 面板 `contentShape` 改变命中区域，可能挡住原本能点到世界的地方 | 只加在 `.panel`（工具栏、面板）上；状态条 `.light`、底座 `.base` 仍然穿透 |
| 选中环改成原生玻璃后再次遮挡格子内容 | 环形路径中间镂空，只有 4–6pt 宽的边带玻璃；描边保留保证对比度 |
| `glassEffectID` 动画与按钮命中 | 展开状态下按钮直接是可点的 Button；动画期间用标志防止重复触发 |
| 相机视场方向 API 若在当前 SDK 不可用会编译失败 | 云端编译验证；失败则回退并在报告中说明 |
| 修改 `RPGSelectionGlass` 影响 2D 沙盒 UI 测试 | 保持标识和 `native` / `fallback` 取值约定，UI 测试断言不需要改 |

本次不改：AI 建模、骨骼与动作、战斗、Boss、世界生成、存档格式、媒体解码与播放、业务规则。
