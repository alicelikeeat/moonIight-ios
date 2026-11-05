# v1.78 玻璃组件与接口说明

## 1. 材质角色（`Features/RPG/Domain/World/RPGGlassWorld.swift`）

| 角色 `MoonGlassRole` | 用途 | iOS 26+ | iOS 16–25 / 降低透明度 |
|---|---|---|---|
| `regular` | 工具栏、菜单、属性面板 | `Glass.regular` | `.regularMaterial` / 实色 |
| `clear` | 3D 世界与媒体上方的控件、状态条、底座 | `Glass.clear` | `.ultraThinMaterial` / 实色 |
| `solid` | 降低透明度时 | 不用玻璃：`secondarySystemBackground` + 细描边 | 同左 |

由 `RPGHUDGlassStyle.resolve(kind, conditions).role` 计算，条件来自系统设置（深色、增强对比度、降低透明度、低电量）和游戏状态（战斗、编辑）。不按帧采样背景，不用硬编码透明度覆盖系统适配。

## 2. HUD 玻璃种类 `RPGHUDGlassKind`

| 种类 | 交互玻璃 | 吸收空白处触摸 | 例子 |
|---|---|---|---|
| `.interactive` | 是（低电量时关闭） | 否（按钮自己接收） | 攻击、技能、摇杆头、选中工具 |
| `.panel` | 否 | **是**（v1.78） | 顶栏、工具卡、工具坞、属性面板、镜头轨 |
| `.light` | 否 | 否（穿透到世界） | 生命条、状态行 |
| `.base`（v1.78 新增） | 否 | 否 | 摇杆底盘、锁定准星 |

用法不变：`view.hudGlass(.panel, radius: 18)`、`view.hudGlass(.interactive, in: Circle())`。

## 3. 容器与融合

- `RPGGlassGroup(spacing:)`：iOS 26 下是 `GlassEffectContainer`，用于同一组工具（动作按钮簇、快捷栏、摇杆的底盘 + 摇杆头）。不同组各自一个容器，不会因靠得近而融合。
- `Glass3DSelectionBar`（`Features/Glass3D/Glass3DSelectionBar.swift`）：选中方块后的操作组。iOS 26 且未开降低透明度时，每块用 `.glassEffect(.regular.interactive(), in: Capsule())` + `.glassEffectID(id, in: namespace)`，放在一个 `GlassEffectContainer(spacing: 10)` 里；展开 / 收拢时由系统完成融合形变（Reduce Motion 下过渡为 `.identity`）。其他情况退回 `hudGlass(.interactive)`。
- `MoonGlassBackdrop` / `moonSingleGlass`：装饰背景，`regular` 非交互，`allowsHitTesting(false)`。

## 4. 动画参数 `MoonGlassMotion`

| 种类 | 正常 | 减弱动态效果 |
|---|---|---|
| `.morph`（玻璃融合、展开收拢） | spring 0.38 s / 阻尼 0.82 | 0.2 s 渐变 |
| `.panel`（面板进出、模式切换） | spring 0.35 s / 阻尼 0.86 | 0.2 s 渐变 |
| `.press`（按压缩放） | 0.1 s | 不缩放 |
| `.fade` | 0.2 s | 0.2 s |

`MoonGlassMotion.animation(kind, reduceMotion:)` 返回 SwiftUI `Animation`；`MoonGlassMotion.allows(lastAction:now:)` 让融合期间的同一操作 0.3 s 内只执行一次。

## 5. 3D 原生玻璃

- `Glass3DNativeGlass.update`：路径与上一次相同就不发布（相机静止时不再每帧重绘玻璃层）；`publishes` 记录实际发布次数。
- `Glass3DNativeGlass.reset()` + `NativeGlassFade.restart()`：视图尺寸变化（横竖屏）、世界从后台恢复、降低透明度切换时立即隐藏，等画面稳定后再淡入。
- `Glass3DController.reduceTransparency`：系统降低透明度开启时关闭方块原生玻璃（不改用户保存的开关）。
- `GlassPerfMeter`：每秒帧数和每秒玻璃路径发布次数，显示在 3D 世界状态行“原生玻璃面 N · 更新 x/s”。
- `RPGSelectionGlass`：2D 沙盒选中格。iOS 26 且未开降低透明度时是一圈 6pt 宽的原生玻璃环（`SelectionRingShape`，中间镂空），上面保留描边；`accessibilityValue` 为 `native` / `fallback`，与实际绘制一致。
