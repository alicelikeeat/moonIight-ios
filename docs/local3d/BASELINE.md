# v1.65 源码审计（开发前）

开发基线：标签 `v1.65`，提交 `84bb9d5`。默认分支 main 是早期版本，不能用作本任务基线。远端已有 `v1.66` 标签（许可补充），本次在 `codex/local-3d-v166` 独立分支开发，不移动已有标签。

| 能力 | v1.65 证据 | 本次处理 |
|---|---|---|
| 相册/文件图片、GIF、视频导入 | Glass3DMediaPicker / MediaStore.importLocalFile | 复用素材库选择、缩略图；独立生成导入使用文件传输，避免整段视频载入 Data |
| 内容去重 | MediaImportIndex.sha256，1 MB 分块 | 复用 SHA-256；生成资产独立内容寻址及引用回收 |
| 素材版权 | SpatialAssetLibrary / Glass3DAttributions | 保留原有逻辑；新模型许可随应用分发 |
| 本地持久化 | VersionedJSONFile / VersionedJSONWriter | 复用版本化 JSON；新资产不迁移旧数据 |
| RealityKit 世界 | Glass3DRenderer，iOS 18+，网格、灯光、材质、摄像机 | 保留；独立预览用 ARView（非 AR），保持最低 iOS 16 |
| 图片/GIF/视频角色 | SpatialMotion + Glass3DMedia，billboard/面片贴图、动作素材切换 | 维持现有功能；不能算 AI 三维重建或骨骼动画 |
| 图片主体分割 | 无 | 新增 Vision，iOS 17 前景实例遮罩；iOS 16 不支持任意主体时明确提示 |
| 深度估计及图片三维重建 | 无权重、无深度管线 | 新增捆绑离线 Depth Anything V2 Small F16，真实相对深度网格；不声称背面恢复 |
| 视频多视角重建 | 无 | 新增有界抽帧、模糊/重复/人物检查；视角覆盖仅启发式待确认，Object Capture 条件隔离 |
| 任意 3D 资产库 | 无 | Generated3D 独立目录，原素材、网格、纹理、清单和预设 |
| 自动骨骼/蒙皮/换装部件 | 无；内置角色只有 2D 动作图 | 不伪造，P2 保持未实现 |

约束：不编辑战斗、Boss、技能、地图生成、建造和物理逻辑。生成模块没有网络客户端；旧在线素材库和对话服务不参与生成。Linux 环境无 Xcode、iPhone，iOS 编译与真机测试在最终报告单独标注。
