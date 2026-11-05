# Moonlight v1.81 World Director（智能世界导演）

版本说明：任务书写的是 v1.80，但 v1.80 已经作为「界面重做 + 黑屏修复 + 删除键」发布，按项目约定每个版本独立编号，本功能以 **v1.81** 交付。
基准：tag `v1.80`（提交 `eac67a1`，即分支 `claude/v1.79-sandbox-ui` 头部）。`main` 落后 163 个提交，未使用。开发分支：`claude/v1.81-world-director`。

## 1. 仓库审计结论

| 复用 | 位置 |
|---|---|
| 确定性随机数 `SpatialRandom`、旧生成器与连通性验证 | `Features/Glass3D/Domain/SpatialGenerator.swift` |
| 建筑模板（小屋、高塔、桥、阶梯、废墟、祭坛、媒体墙、Boss 场地）、媒体网格贴图 | `SpatialBuilding.swift` |
| 世界数据、合法性校验、来源标记（generated / user）、撤销历史 | `SpatialModel.swift` |
| 寻路 / 可达性 `SpatialNavigator` | `SpatialEcology.swift` |
| 相册 / 文件导入素材库、网络素材（Poly Haven / Openverse，授权过滤并记录） | `Glass3DMediaPicker.swift`、`Glass3DAssetLibrary.swift` |
| AI 3D 模型库、生成模型作为角色外观 | `Generate3D`、`Glass3DController.characterID(forGenerated:)` |
| Claude 接口（用户自己的密钥，存钥匙串） | `Generate3DClaude.swift`、`SecureSettings` |

缺失（本版新增）：主题模板、空间规划（道路、地标、构图）、非透明结构材质、天空与光照、素材分析、候选方案与质量评估、局部重生成、蓝图存档。
风险：方块数量影响渲染 → 按设备分级预算；存档兼容 → 只加可选字段。

## 2. 模块与接口

| 文件 | 内容 |
|---|---|
| `Features/WorldDirector/Domain/WorldBlueprint.swift` | `WorldTheme`（5 种）、`WorldBlueprint`（含 schemaVersion 与 `validate()`）、`WorldGenerationRequest`、`PerformanceBudget`（按设备分级）、`WorldDirectorRecord`、`SpatialAtmosphere`、`SpatialSurface` |
| `WorldAssets.swift` | `AssetDescriptor`（任务书全部字段）、`AssetRules`（损坏、授权、面数、内存检查）、`AssetAnalyzer`（主色、风格标签、适用主题） |
| `WorldPlanner.swift` | `WorldIntent`（文字 → 结构化意图）、`WorldIntentParser`（本机关键词）、`WorldThemeStyle`（配色、白天 / 黄昏 / 夜晚光照）、`WorldPlanner.plan`（五种模板） |
| `WorldBuilder.swift` | `SpatialWorldBuilder.build`：蓝图 → 现有世界对象；按层、按区域；用户对象保护；预算 |
| `WorldDirector.swift` | `WorldQualityEvaluator`、`WorldDirectorEngine.candidates / regenerate / relight`、`WorldPlanningProvider` 协议、`LocalWorldPlanner`、`WorldIntentResolver`、`WorldPreview` |
| `WorldDirectorService.swift` | `ClaudeWorldPlanner`（结构化输出）、`WorldPlanningRunner`（超时）、`WorldAssetReader`（后台读取素材）、控制器操作 |
| `WorldDirectorView.swift` | 生成界面 |

任务书里的 `WorldDirector.generate(request)` 对应 `WorldDirectorEngine.candidates(request, intent:, base:, progress:, cancelled:)`；`WorldPlanningProvider.plan` 改为返回 `WorldIntent`：AI 只填写意图数据，布局由本机规则完成，保证结果可验证。

## 3. WorldBlueprint

`blueprintID, schemaVersion, seed, theme, palette, terrainPlan, biomeRegions, roadNetwork, landmarkPlan, buildingZones, decorationPlan, lightingProfile, assetAssignments, spawnPlan, explorationRoutes, performanceBudget, generationMetadata`，全部 `Codable`。相同请求、种子和生成器版本得到相同蓝图与相同世界（有测试）。

## 4. 生成流程

1. 素材 → `AssetDescriptor`（后台读取缩略图，算主色和标签）→ `AssetRules.partition` 跳过损坏、未授权、超大素材并给出说明。
2. 文字 → `WorldIntent`：默认本机关键词；可选 Claude（只发文字和素材类型 / 颜色，不发图片；30 秒超时；失败自动回退并提示）。
3. 每个候选：`WorldPlanner.plan` → `SpatialWorldBuilder.build` → `WorldQualityEvaluator.evaluate`；未通过硬约束的换种子重试最多 4 次。
4. 三个候选按「通过 → 总分」排序，显示俯视预览和分项评分。
5. 选中后作为一次编辑提交（物体、天空、蓝图一起可撤销），另存「生成前的世界」可一键恢复。

构图：出生点 → 前方中景的主地标；前景（16 格内）、中景（16–50）、远景（远山）三层；不做均匀随机散布。
硬约束：数据合法、无实体重叠、预算内、素材授权、出生点不被封闭、主地标与主要区域可达、主路线连通。评分权重按任务书（构图 25、协调 20、光照配色 20、探索 15、风格 10、性能 10）。

## 5. 素材管线

| 类型 | 去向 |
|---|---|
| 图片 | 画廊墙（媒体网格贴到方块正面） |
| 视频 / GIF | 影像屏、广告牌（受 `maxVideos` 限制；渲染器沿用现有的可见性暂停） |
| AI 3D 模型 | 出生点附近的雕像（中立生物 + 模型外观） |
| 网络素材 | 通过现有网络素材浏览器导入，仅允许可商用、可改编的授权，记入「素材来源与授权」 |
| 音频 | 未放入世界（记录说明） |

梦境记忆世界会用所选照片的主色作为点缀色。

## 6. 存档兼容

新增字段全部可选：`SpatialWorld.atmosphere`、`SpatialWorld.director`、`SpatialGlass.surface`、`SpatialDiff` 的天空 / 蓝图前后值、`WorldDirectorRecord.assets`。旧存档和旧撤销历史原样读取（有测试）。生成在内存中完成，确认后才提交；取消或失败不改动世界。

## 7. 已实现 / 未实现 / 待验证

已实现（有逻辑测试）：五种模板离线生成；三个候选；质量评估与硬约束；相同种子一致；局部重生成（按层、按镜头附近区域）、锁定方块、撤销（含天空）、恢复生成前世界；白天 / 黄昏 / 夜晚；石材 / 金属 / 晶体材质；素材检查与分配；AI 意图解析、校验、超时回退；存档与旧存档兼容。

未实现：
- AI 自动生成缺失素材（贴图 / 模型）：未接入；可以先在「AI 生成 3D 模型」里生成，再在世界导演里选用。
- 文件 App 导入的 GLB / USDZ 直接作为世界道具：未接入（只支持 AI 3D 库中的模型）。
- 候选方案的 3D 预览：用俯视图代替，不同时实例化三个完整场景（按任务书「轻量化预览」）。
- 阴影、反射等高级光照：只调整天空、太阳角度和强度、发光强度，使用 RealityKit 默认能力。
- 音频放入世界。

待验证（没有真机数据）：帧率、设备分级阈值（按内存粗分 4.5 GB / 7 GB）、Claude 规划效果、界面操作。
