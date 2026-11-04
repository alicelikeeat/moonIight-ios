# P2 研究记录：未实现、未通过设备验证

## TripoSR

核查来源（2026-11-04）：

- https://github.com/VAST-AI-Research/TripoSR/blob/main/README.md （读取 blob `b52bfb251b850f13a8b8565b52914f2bc9ede2e3`）
- https://github.com/VAST-AI-Research/TripoSR/blob/main/LICENSE

官方 README 声明源代码、预训练模型和 demo 为 MIT；LICENSE 版权为 2024 Tripo AI & Stability AI。该声明允许商业使用，但本项目没有下载、引入或再分发 TripoSR 权重或运行依赖，不能据此认为未来移植的所有依赖都已核查。

上游默认单图设置约需 6 GB VRAM，A100 上的耗时不能外推为 iPhone 性能。不能直接在 iPhone 运行 Python/CUDA 路径。Core ML 移植至少需：

1. 固定模型、权重和依赖版本/哈希，逐项核查许可；与现有 Small 深度模型分别管理。
2. 分离图像编码器、三平面解码器、隐式场采样，验证 PyTorch → Core ML 每个算子、张量布局和 FP16 精度。
3. 用有界网格采样及本地 Metal/CPU marching cubes 提取完整表面，并完成纹理烘焙、法线、UV 和 USDZ 导出。
4. 在多档 iPhone 上记录应用物理内存、峰值、温度、耗时、取消延迟和离线行为；通过 RealityKit 加载检查实际几何质量。
5. 将前后/侧面多视角误差纳入测试；完整拓扑也不意味着隐藏表面是真实恢复。

没有执行上述转换或 iPhone 实测，**不得标记为正式依赖或已完成 360° 图片生成**。

## 自动骨骼、蒙皮与动画

现有角色动作是图片/GIF/视频 billboard 素材切换，不是骨骼。单图深度表面没有背面、完整肢体截面或可靠体积，不能直接宣称可绑定。未来需完整人形几何、3D 关节检测、骨架生成、蒙皮权重求解、穿插/关节测试以及实际动作播放。失败时保留静态模型；当前清单固定记录 `notImplemented` / `staticOnly`。

## 服装、头发、独立部件

主体分割仅移除主体外背景，不推导独立服装结构。当前只有整体材质色调与粗糙度预设，没有自由换装、独立贴图替换或部件替换。未来需要真实多部件拓扑、可替换接口和蒙皮兼容验证，不能把图像区域标签充当独立三维部件。
