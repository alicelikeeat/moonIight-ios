# Moonlight v1.66 本地 3D 开发报告

本次是基于 v1.65 的研发分支交付，**尚未达到“支持的 iPhone 飞行模式下图片生成、RealityKit 预览、保存及重开”的最低真机验收标准**。P2 不作为完成项。没有发布 IPA、合并分支或移动既有 v1.66 标签。

## 源码与边界

- 开发分支：`codex/local-3d-v166`，基线 `v1.65` / `84bb9d53b642a079942e2bec0301ae4ce7a2d433`。
- 先行审计：[BASELINE.md](BASELINE.md)。新模块在 `Features/Local3D/`，只改动设置、3D 菜单和本地素材选择入口、Xcode 注册及检查配置。
- 战斗、Boss、技能、地图生成、建造、物理、角色行为和旧存档格式均未修改。原素材库与世界存储保留。
- 最低部署版本维持 iOS 16。图片前景实例分割及捆绑 spec 8 深度模型隔离在 iOS 17+；Object Capture 另检查 `PhotogrammetrySession.isSupported`。原 3D 世界仍使用自己的 iOS 18 限制。

## 已编写的功能

| 优先级 | 功能 | 实现及实际边界 |
|---|---|---|
| P0 | 图片输入 | 相册文件传输、文件导入 JPG/PNG/HEIC、已有本地素材复用；ImageIO 缩图、EXIF 方向处理；图片上限 100 MB、短边至少 128px |
| P0 | 主体与深度 | iOS 17 Vision 前景实例遮罩（保留全部主体），捆绑离线 Depth Anything V2 Small F16；相对逆深度，不是真实距离 |
| P0 | 真实网格 | 遮罩内三维顶点、正面三角面、UV、深度断层裁切、孤立顶点移除；不创建背面，明确标记“深度立体模型” |
| P0 | 保存与重开 | 静态带纹理 USDZ、唯一 UUID、内容寻址原素材/PNG 纹理、版本化清单；先写文件，再实际 RealityKit 加载，最后写验证状态；失败回滚新资产 |
| P0 | 独立预览 | RealityKit 非 AR ARView，无摄像头权限；居中、归一化、360° 旋转、双指缩放、背景/补光开关、图片网格面数/贴图尺寸/文件大小 |
| P0 | 任务与保护 | 单任务、真实阶段通知、抽帧/摄影测量真实进度、取消、内存预算、内存警告处理、后台取消；serious 热状态在阶段边界等待，critical 停止；摄影测量在 serious/critical 时停止 |
| P0 | 视频前处理 | MOV/MP4 等 AVFoundation 可解码视频；文件传输而非整段 Data；2 秒至 10 分钟、最大 2 GB；最多 96 个抽帧，逐帧解码，落盘 JPEG，模糊/重复/人物检查；可选清晰单帧立体化 |
| P1 | Object Capture | 仅支持硬件、候选质量通过、无检测人物且用户确认静止环绕后尝试；系统真实 USDZ 输出并通过 RealityKit 加载后才保存为重建；**未真机验证** |
| P1 | 材质与导出 | 整体色调/粗糙度、模型专属预设保存/重开；导出原始 USDZ，预设不烘焙进导出文件；不提供独立部件/贴图替换 |
| P1 | 几何/纹理预算 | 可用内存/低电量决定网格最大边 96/160，最长纹理边 1024/2048；深度图 518×392；不声称通用拓扑简化器 |
| P2 | 研究 | [P2_RESEARCH.md](P2_RESEARCH.md)；TripoSR 未引入；完整 360° AI、骨骼、蒙皮、动画适配和服装分离均未实现 |

文件结构：`Documents/Generated3D/{Models,Textures,Skeletons,Animations,Thumbnails,Presets,Manifests,Sources}`。Skeletons/Animations/Thumbnails 当前保留目录，没有虚构对应资源。来源原文件与独立纹理按 SHA-256 去重；每个 USDZ 为可独立导出的完整包，包内纹理仍占空间。删除按清单引用回收；损坏或未来版本清单阻止自动回收以防误删。中断后的无清单模型可在库刷新时清理。

## 离线、许可与模型管理

生成模块不含网络客户端。不会发送用户图片、视频、网格或遥测；复用选择器仅显示本地已有素材，隐藏在线和重复导入入口。相册/文件提供器的云端原片需要用户先下载到本机，飞行模式下不可用会报错。

模型来源固定为 Apple `coreml-depth-anything-v2-small` 提交 `cfef6f6f2a70783dedc0bfae40cecbc2052285d3`；Small F16，24.8M 参数，包约 49.8 MB。模型卡、Apache-2.0 许可和 SHA-256 在 `Resources/Local3D/`，构建校验脚本验证每个文件。未引入 Base/Large 非商业权重及远程依赖。模型原始包随应用分发，首次在本机离线编译到可丢弃缓存，加载失败会清除缓存供重试；一次推理结束释放 MLModel，不长期持有模型。

## 已执行检查与证据

- Swift 6.0.3 / Linux：31 项新领域检查通过，涵盖非共面几何、三角面朝向、UV、遮罩孔洞、非法/空/平深度、网格预算、清单重开、静态能力标记、视频质量规则、任务取消。
- 独立 Python ZIP 校验：CRC、无压缩、64 字节对齐及网格/纹理存在通过。
- 独立 OpenUSD：载入实际 USDZ，4,096 顶点、7,938 三角面、Z 变化 > 0.25，材质绑定和包内纹理可解析。**不是 RealityKit 测试，也不是图片推理测试。**
- v1.65 原有 RPG/Glass3D 领域：4,166 项逻辑检查通过；原持久化：25 项通过。没有据此声明旧 UI 或游戏真机已通过。
- 捆绑权重 SHA-256、Apache 许可、所有新源码 Xcode 注册、最低 iOS 16、模块内无网络客户端检查通过。Swift 语法解析与 `git diff --check` 通过。
- 模型 protobuf 检查：[MODEL_INSPECTION.json](MODEL_INSPECTION.json)；输入 RGB 518×392，输出 Float16 灰度 518×392，specificationVersion 8。没有在 Linux 执行 Core ML 推理。
- 算法测试耗时和 RSS：[ALGORITHM_TEST_RESULT.json](ALGORITHM_TEST_RESULT.json)，只对应合成深度/文件测试，不代表 App 或 iPhone 生成性能。
- macOS / Xcode 和模拟器集成结果：见本报告后续 CI 记录。新增测试检查真实 USDZ 的 RealityKit 加载、资产重开、内容去重、删除共享引用、原文件保留及超大输入拒绝；这些是合成几何测试，不替代图片推理与真机测试。

## 尚未交付或验证

1. 没有连接的 iPhone；12 项真机矩阵均未运行：[DEVICE_VALIDATION.md](DEVICE_VALIDATION.md)、[DEVICE_VALIDATION.json](DEVICE_VALIDATION.json)。实际设备、iOS、输入格式、耗时、峰值、输出类型和加载结果全部保留空值，禁止填造数据。
2. 图片推理质量、Vision 遮罩与 UV 上下方向、动漫/透明 PNG 轮廓、首轮离线模型编译、实际内存/热状态和取消延迟均需设备检查。
3. 视频相似度只是画面变化启发式，不能验证相机姿态或 360° 覆盖；模糊/重复/人物阈值待真机校准。普通动态人物不允许冒充静态物体重建；存在漏检风险，所以还需用户确认拍摄条件。
4. Object Capture 设备兼容不等于任意视频可重建；本次没有成功真机重建证据。重建结果面数/贴图尺寸当前显示“暂不可用”。
5. 不支持恢复背面、完整角色体积、骨骼动画、独立服装/头发/饰品或自由换装。生成资产仅在独立模块中预览/编辑/导出，没有改动旧游戏角色或世界实体绑定。
6. Core ML 同步预测/模型编译不可被立即中断，取消在系统调用结束后处理；不能保证系统内存终止前总能收到警告，采样和预算不能代替设备压力测试。
7. 整体材质预设不改变原始 USDZ，导出不含色调修改；通用模型简化、纹理替换和已有骨骼动画预览未实现。

## 复现

在 Mac/Xcode：运行 `.github/workflows/local3d-validation.yml` 的两类 Swift 测试与 simulator 编译/集成命令。独立逻辑可执行：

```sh
mkdir -p build/local3d
swiftc -swift-version 6 Features/Local3D/Domain/*.swift Shared/Persistence/VersionedJSONFile.swift tests/local3d/main.swift -o build/local3d/tests
build/local3d/tests build/local3d/fixture.usdz
python3 scripts/validate_local3d.py build/local3d/fixture.usdz
```

完整验收仍需按真机矩阵操作并附 Instruments、截图/录像、清单和 USDZ。只有对应证据齐备后，才能更新本报告的完成状态。
