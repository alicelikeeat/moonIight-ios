# Moonlight 架构（RPG Framework 整合基线）

本文记录 **2026-11-07 的真实代码状态**（分支 `claude/busy-ritchie-x38lh5`，提交 `42e2099` 之后），以及 RPG 框架整合的目标边界和执行顺序。

本文不是完成声明：标为「目标」的部分还没有实现。

## 1. 分支与基线

| 分支 | 状态 | 处理 |
|---|---|---|
| `claude/busy-ritchie-x38lh5` | 主开发线。包含 v1.86 全部内容，以及之后的 Xbox HUD、深度模型预编译、小组件、USDZ 转换器，和 AI Asset Director 的领域层。 | 继续在这里开发 |
| `claude/v1.86-hybrid-regions` | 有 1 个提交 `5bfe689` 不在主开发线：区域旅行、区域存档、大陆地图（约 600 行）。它从 `8d5c239` 分出，早于月光水晶城。 | **必须合并**，不能互相覆盖。与主开发线在 6 个文件上冲突：`Glass3DController.swift`、`project.pbxproj`、`Tests/RPG/main.swift`、工作流、发布说明、控件清单。 |
| `main` | 落后主开发线 199 个提交 | 不作为开发基准 |

可回滚基准：标签 `v1.86`（`b487015`）和提交 `42e2099`。

## 2. 现有系统盘点

### 2.1 已完成、可复用

| 能力 | 位置 | 说明 |
|---|---|---|
| 权威存档 | `RPGSession` + `WorldState`（schema 7）+ `RPGWorldDiskStore` | 2D 沙盒和 3D 世界共用一份存档：`WorldState.spatial: SpatialWorld?`；原子写入，带备份 |
| 3D 世界数据 | `SpatialWorld`、`SpatialBlock`、`BuildingGroup`、`CreatureEntity` | 方块上限 3 万；有撤销历史 `SpatialHistory`；用户内容有 `origin` 保护 |
| 双视角 | `DualPerspectiveCamera`、`PerspectiveContinuity`、`GlassMaterialResolver` | 同一份数据；切换前后有状态一致性检查 |
| 混合世界 | `WorldGraph`、`WorldRegionManager`、`RegionTerrain` | 4096 大陆、256 区域、流式加载分级 |
| 世界导演 | `WorldPlanner` → `WorldBlueprint` → `SpatialWorldBuilder` → 质量门槛 | 数据驱动生成，支持局部重生成，保护用户内容 |
| 3D 战斗 | `SpatialCombat`、`SpatialBattle`、`CreatureBrain` | 攻击、技能、翻滚、锁定、生命和耐力 |
| 数据驱动技能 | `SkillDefinition`、`SkillLibrary`、`SkillCast`、`SkillEvent` | 已有技能编辑器 `Glass3DSkillEditor` |
| Boss 阶段 | `BossScript`、`BossPhase`、`BossDirector` | 已有 Boss 编辑器 |
| 2D 剧情 | `RPGStoryGraph`、`RPGStoryRuntime`、`RPGStoryAuthoring`、`RPGOfficialStory` | 条件、选择、事件，有编辑器；**只接在 2D 沙盒** |
| 模型导入 | `ModelImport`（GLB、glTF、FBX、OBJ、STL、3MF），USD 走 RealityKit | 保留骨骼和动作 |
| 自动骨骼 | `Generate3DRigging`（10 骨）、`RiggingPipeline`（27 关节） | 两套骨骼体系（见 2.3） |
| 导出 | OBJ、GLB、STL；USDZ 走自研转换器 `USDZExport`（含 UsdSkel） | `usdchecker` 通过；RealityKit 回读只在 App 内运行 |
| 手柄 | `SpatialGamepad` + 可配置映射 | 已有 Xbox 布局的触屏 HUD |

### 2.2 部分完成

| 能力 | 缺口 |
|---|---|
| AI Asset Director | 领域层、测试和世界导演接入已完成。设备端分析器、协调器和工作台界面**已写好，还没加入 App 目标**（提交 `62dc3a3`） |
| 区域旅行 | 在另一个分支上，未合并 |
| 装备 | 只有 2D 版 `RPGEquipment`，3D 战斗不读取 |
| 动画状态机 | 3D 角色有 `CharacterAnimationState` 和 `ActionClip`（2D 精灵动作）。没有混合、取消窗口和动作事件；骨骼动画只做到播放片段 |
| 演出 | 2D 有 `RPGCutsceneView`；3D 只有技能视觉 `SkillVisual`，没有通用时间轴 |

### 2.3 重复实现（整合重点）

1. **两套战斗规则**：2D 的 `RPGCombatRules` / `RPGCombatState` / `RPGEnemyState`，和 3D 的 `SpatialCombat` / `SpatialBattle`。生命、耐力、月晶通过 `applySpatialVitals` 在两边同步。
2. **四种动作片段格式**：`RigClip`（10 骨程序化）、`MotionClip`（27 关节引擎）、`KeyframeClip`（文件关键帧）、`ActionClip`（2D 精灵）。
3. **两套骨骼体系**：`RigSkeleton` + `SkinWeights`（2 权重），和 `SkeletonDefinition` + `SkinInfluences`（4 权重）。目前只有 USDZ 导出把两者统一了（`USDSkinnedData`）。
4. **两种敌人模型**：2D 的 `RPGEnemyState`，和 3D 的 `CreatureEntity` + `CreatureBrain`。
5. **剧情只在 2D**：3D 世界不能触发 `RPGStoryRuntime` 的节点。

### 2.4 职责过重的类

| 类 | 行数 | 混在一起的职责 |
|---|---|---|
| `Glass3DController` | 1501 | 输入、相机、编辑工具、战斗推进、存档提交、通知文案、素材放置 |
| `RPGSession` | 1149 | 2D 模拟、存档、媒体调度、剧情、3D 世界桥接 |
| `Glass3DRenderer` | 930 | 渲染（职责单一，但承担批处理、遮挡、材质缓存） |
| `Generate3DEngine` | 887 | 模型生成管线、模型仓库、导出 |
| `WorldBuilder` | 821 | 搭建规则（职责单一，数据驱动） |

### 2.5 缺测试的关键路径

- 3D 战斗：伤害、闪避无敌帧、Boss 换阶段，缺状态变化测试
- 2D 与 3D 战斗结果一致性
- 区域切换时角色状态保持（功能还在另一个分支）
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

1. **合并区域旅行分支**（解决 6 处冲突，补上区域切换的角色状态测试）
2. **完成 AI Asset Director**（把已写好的平台层加入目标，跑 UI 测试和真实评测）
3. **统一战斗规则**：2D 战斗改为调用 `SpatialCombat` 和 `SkillDefinition`，删除重复规则，加一致性测试
4. **命令和事件层**：在 `RPGSession` 上建立 `GameCommand` 和类型化事件，`Glass3DController` 的编辑和战斗改走命令
5. **剧情接入 3D**：`RPGStoryRuntime` 的条件和动作读取 3D 世界事件
6. **统一角色资源描述和动画状态机**：合并四种片段格式的播放接口，加入取消窗口和动作事件
7. **演出时间轴**：复用 `SkillVisual` 和 `RPGCutsceneView`
8. **ContentCompiler**：把世界导演、技能、Boss、剧情的 AI 输出统一经过 Schema 校验
9. **最小可玩验收场景**：城镇 + 战斗区 + Boss 场地

## 5. 兼容要求

- `WorldState` 只做可选字段扩展。每次 schema 变化都要有「旧存档加载 → 保存 → 再加载」测试
- 用户建造（`origin == .user`）在任何重生成和迁移中都保留
- 旧的 `AssetDescriptor`、`GoldenTownIntent`、`SpatialWorld` 都有解码兼容测试（见 `Tests/RPG`）
