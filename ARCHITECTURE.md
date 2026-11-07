# Moonlight 架构（RPG Framework 整合基线）

本文记录 **2026-11-07 的真实代码状态**（分支 `claude/busy-ritchie-x38lh5`，提交 `42e2099` 之后），以及 RPG 框架整合的目标边界和执行顺序。

本文不是完成声明：标为「目标」的部分还没有实现。

## 1. 分支与基线

| 分支 | 状态 | 处理 |
|---|---|---|
| `claude/busy-ritchie-x38lh5` | 主开发线。包含 v1.86 全部内容，以及之后的 Xbox HUD、深度模型预编译、小组件、USDZ 转换器，区域旅行合并和 AI Asset Director。 | 继续在这里开发 |
| `claude/v1.86-hybrid-regions` | 有 1 个提交 `5bfe689` 不在主开发线：区域旅行、区域存档、大陆地图（约 600 行）。它从 `8d5c239` 分出，早于月光水晶城。 | 已于 `501c76a` 合并。原先与主开发线在 6 个文件上冲突：`Glass3DController.swift`、`project.pbxproj`、`Tests/RPG/main.swift`、工作流、发布说明、控件清单。 |
| `main` | 落后主开发线 199 个提交 | 不作为开发基准 |

可回滚基准：标签 `v1.86`（`b487015`）和提交 `42e2099`。

## 2. 现有系统盘点

### 2.1 已完成、可复用

| 能力 | 位置 | 说明 |
|---|---|---|
| 权威存档 | `RPGSession` + `WorldState`（schema 7）+ `RPGWorldDiskStore` | 一份存档：3D 世界在 `WorldState.spatial`，剧情、背包、生命也在同一份里；原子写入，带备份。旧 2D 存档照常打开 |
| 3D 世界数据 | `SpatialWorld`、`SpatialBlock`、`BuildingGroup`、`CreatureEntity` | 方块上限 3 万；有撤销历史 `SpatialHistory`；用户内容有 `origin` 保护 |
| 双视角 | `DualPerspectiveCamera`、`PerspectiveContinuity`、`GlassMaterialResolver` | 同一份数据；切换前后有状态一致性检查 |
| 混合世界 | `WorldGraph`、`WorldRegionManager`、`RegionTerrain` | 4096 大陆、256 区域、流式加载分级 |
| 世界导演 | `WorldPlanner` → `WorldBlueprint` → `SpatialWorldBuilder` → 质量门槛 | 数据驱动生成，支持局部重生成，保护用户内容 |
| 3D 战斗 | `SpatialCombat`、`SpatialBattle`、`CreatureBrain` | 攻击、技能、翻滚、锁定、生命和耐力 |
| 数据驱动技能 | `SkillDefinition`、`SkillLibrary`、`SkillCast`、`SkillEvent` | 已有技能编辑器 `Glass3DSkillEditor` |
| Boss 阶段 | `BossScript`、`BossPhase`、`BossDirector` | 已有 Boss 编辑器 |
| 剧情 | `RPGStoryGraph`、`RPGStoryRuntime`、`RPGStoryAuthoring`、`RPGOfficialStory`，3D 桥接 `RPGStorySpatial` | 条件、选择、事件，有编辑器。3D 世界的位置、击败和破坏方块驱动任务；任务地点显示为金色光柱和提示 |
| 模型导入 | `ModelImport`（GLB、glTF、FBX、OBJ、STL、3MF），USD 走 RealityKit | 保留骨骼和动作 |
| 自动骨骼 | `Generate3DRigging`（10 骨）、`RiggingPipeline`（27 关节） | 两套骨骼体系（见 2.3） |
| 导出 | OBJ、GLB、STL；USDZ 走自研转换器 `USDZExport`（含 UsdSkel） | `usdchecker` 通过；RealityKit 回读只在 App 内运行 |
| 手柄 | `SpatialGamepad` + 可配置映射 | 已有 Xbox 布局的触屏 HUD |

### 2.2 部分完成

| 能力 | 缺口 |
|---|---|
| AI Asset Director | 已加入 App，端到端界面测试通过（导入、分析、低置信度待确认、手动纠错、交给世界导演生成并应用城镇）。模拟器不提供真实 Vision 结果，所以评测只用实测特征（47 个 CC0 样本，Top-1 95.7%，Top-3 100%）。真实 Vision 准确率、真机性能**未验证** |
| 装备 | `RPGEquipment` 存在存档里，3D 普攻读取月刃加成；装备界面随 2D 沙盒一起删除，还没有 3D 版 |
| 动画状态机 | 3D 角色有 `CharacterAnimationState` 和 `ActionClip`（2D 精灵动作）。没有混合、取消窗口和动作事件；骨骼动画只做到播放片段 |
| 演出 | 剧情媒体节点用 `RPGCutsceneView` 播放（从 3D 的剧情面板打开）；3D 只有技能视觉 `SkillVisual`，没有通用时间轴 |

### 2.3 重复实现（整合重点）

1. **两套战斗规则**：3D 的 `SpatialCombat` / `SpatialBattle` 是唯一在运行的战斗。2D 的 `RPGCombatRules` 已没有界面和循环，只剩剧情用到的部分（生成剧情敌人、记录击败）；第 3 步把这部分收进 3D 并删除其余规则。
2. **四种动作片段格式**：`RigClip`（10 骨程序化）、`MotionClip`（27 关节引擎）、`KeyframeClip`（文件关键帧）、`ActionClip`（2D 精灵）。
3. **两套骨骼体系**：`RigSkeleton` + `SkinWeights`（2 权重），和 `SkeletonDefinition` + `SkinInfluences`（4 权重）。目前只有 USDZ 导出把两者统一了（`USDSkinnedData`）。
4. **两种敌人模型**：剧情敌人仍存为 `RPGEnemyState`，在 3D 里以 `CreatureEntity` 出现（`RPGStorySpatial.reconcile`）。
5. ~~剧情只在 2D~~：已接入 3D（v1.88）。

### 2.4 职责过重的类

| 类 | 行数 | 混在一起的职责 |
|---|---|---|
| `Glass3DController` | 1501 | 输入、相机、编辑工具、战斗推进、存档提交、通知文案、素材放置 |
| `RPGSession` | 约 330 | 存档、剧情、3D 世界桥接（2D 模拟、编辑器、玻璃实验已删除） |
| `Glass3DRenderer` | 930 | 渲染（职责单一，但承担批处理、遮挡、材质缓存） |
| `Generate3DEngine` | 887 | 模型生成管线、模型仓库、导出 |
| `WorldBuilder` | 821 | 搭建规则（职责单一，数据驱动） |

### 2.5 缺测试的关键路径

- 3D 战斗：伤害、闪避无敌帧、Boss 换阶段，缺状态变化测试
- 3D 剧情敌人的战斗手感（只有规则测试，界面测试只覆盖任务提示）
- 区域切换时的剧情：剧情地点在中央区域的网格上；在其他区域不同步位置、不显示光柱、不召唤剧情敌人，提示改为「在中央区域」。只有规则测试，没有界面测试
- 旧版存档 → 当前 schema 的完整加载、保存、再加载

## 3. 目标领域边界（逻辑领域，不拆 Swift Package）

```
Core ← World ← Gameplay ← Presentation
  ↑      ↑        ↑
  └── Character ──┘
Assets（被 World / Character / Gameplay 读取）
AI Studio → 只产出经 ContentCompiler 校验的数据 → Assets / World
```

| 领域 | 数据所有者 | 现有代码 |
|---|---|---|
| Core | `RPGSession` 持有唯一 `WorldState`。目标：命令 → 事务 → 事件 | `WorldState`、`SpatialHistory`、`RPGWorldDiskStore` |
| World | `SpatialWorld`、区域存档 | Glass3D/Domain、HybridWorld |
| Character | `CharacterTemplate`。目标：统一资源描述，包括模型、骨骼、动画集合和挂点 | Glass3D/Domain/SpatialSkills、Rigging、Generate3D |
| Gameplay | `SpatialCombat` 和 `SkillLibrary` 作为唯一规则来源；2D 改为调用同一套规则 | Glass3D/Domain、RPG/Domain/Combat、RPG/Domain/Story |
| Presentation | 只读世界快照 | `Glass3DRenderer`、SpriteKit 场景、HUD |
| Assets | 素材库、模型库、`AssetLibraryState` | MediaStore、Generated3DStore、AssetDirector |
| AI Studio | 不拥有运行时状态 | WorldDirector、AssetDirector、ClaudeMotion |

规则：

- 渲染不改规则
- AI 输出只能引用已注册的组件、行为和资源，绝不作为代码执行
- 只有一份权威状态

## 4. 执行顺序（每一步都可构建、可测试、可回滚）

1. ✅ **合并区域旅行分支**（解决 6 处冲突，补上区域切换的角色状态测试）
2. ✅ **完成 AI Asset Director**（平台层已加入目标，UI 测试和模拟器评测已通过；Vision 准确率待真机）
3. ✅ **统一战斗规则**：2D 战斗引擎已删除，战斗只在 3D（`SpatialCombat` / `SpatialBattle`）。装备统一为 `RPGGear`（月刃攻击 +8、石甲每次受击 −4，至少 1）；剧情敌人在 3D 里放到最近的空地；`RPGCombatRules` 只剩剧情记账（事件、战斗标记）
4. ✅ **命令和事件层**（事件部分）：3D 世界向存档报告的事情统一为 `GameEvent`（移动、击败、移除方块），由纯函数 `GameEventRules` 应用并决定是否保存、任务条件是否达成。编辑仍走 `Glass3DController.edit`（单一入口，带撤销），没有另建 `GameCommand` 类型
5. ✅ **剧情接入 3D**（与删除 2D 沙盒一起提前完成）：位置、击败、破坏方块来自 3D；任务地点显示金色光柱；剧情、剧情编辑器、世界与存档在 3D 的 ⋯ 菜单
6. ✅ **动画状态机**（状态机部分）：一次性动作按自己的长度结束、60% 后可连击、一个输入缓冲、效果时刻和结束事件；动作长度和命中时刻来自角色片段。**四种片段格式的播放接口还没有合并**，也没有动作混合
7. ✅ **演出时间轴**：`CinematicTimeline`（镜头、字幕、特效提示）＋纯函数播放器；第一次遇到 Boss 播放 2.6 秒登场演出，可跳过，减少动态效果时只显示字幕
8. ✅ **ContentCompiler**：内容包（技能、Boss、剧情 JSON）和世界导演的 AI 规划走同一道检查：大小、格式、编辑器规则、交叉引用、不能覆盖内置内容；逐项说明拒绝原因。3D ⋯ 菜单可导入内容包
9. ✅ **最小可玩验收场景**：`DemoLevel` 在月光水晶城旁放战斗区（6 个敌人）和带围墙的 Boss 场地（三阶段 Boss、奖励宝箱），用寻路确认都能从出生点走到

以上都通过了云端领域测试（4853 项检查）和完整模拟器界面回归（提交 `94a4e4c`；一项助手输入栏测试偶发失败，单独重跑通过）。**真机上的手感、帧率、发热都还没有验证**。

## 5. 兼容要求

- `WorldState` 只做可选字段扩展。每次 schema 变化都要有「旧存档加载 → 保存 → 再加载」测试
- 用户建造（`origin == .user`）在任何重生成和迁移中都保留
- 旧的 `AssetDescriptor`、`GoldenTownIntent`、`SpatialWorld` 都有解码兼容测试（见 `Tests/RPG`）
