# TripoSR → Core ML（手机本机生成 3D）

把开源的 TripoSR（VAST AI / Stability AI，MIT 许可）转换成 iPhone 能跑的格式，供月淡「AI 图片转完整 3D → 手机本机」使用。

**需要**
- 一台 Mac（建议 Apple 芯片、16 GB 内存）。
- 一台 8 GB 内存的 iPhone（iPhone 15 Pro 及以后）。

**步骤**
1. 准备环境：
   ```
   git clone https://github.com/VAST-AI-Research/TripoSR
   python3 -m venv venv && . venv/bin/activate
   pip install torch coremltools omegaconf einops trimesh huggingface-hub transformers pillow
   ```
2. 转换：
   ```
   python convert.py --triposr ./TripoSR --out ./TripoSR-CoreML
   ```
   脚本会从 Hugging Face 下载权重（约 1.7 GB）。输出文件夹约 0.8 GB，里面有 `TripoSREncoder.mlpackage` 和 `triposr_decoder.bin`。
3. 把整个 `TripoSR-CoreML` 文件夹用 AirDrop 或 iCloud 云盘放进 iPhone 的「文件」。
4. 在月淡里打开「AI 生成 3D」→「AI 图片转完整 3D」→「手机本机」→「导入模型文件夹」，选这个文件夹。

**工作方式**
- 图片编码这个重的部分由 Core ML 在神经网络引擎上运行。
- 解码、表面提取、上色这些轻的部分由月淡用 Swift 在本机完成。

**状态**

这个脚本是按 TripoSR 源码编写的，月淡开发环境没能实际运行它（构建机器不允许执行下载的模型代码）。脚本自带两道检查：
- 转换前，确认包装后的模型和 TripoSR 原版输出一致；
- 在 Mac 上转换后，对比 Core ML 和 PyTorch 的结果。

任何一步不一致都会停下来提示你。手机端的速度、内存和发热也都还没有实测。
