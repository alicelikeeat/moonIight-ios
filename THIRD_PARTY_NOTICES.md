# 第三方素材与服务说明 / Third-Party Notices

本项目的源代码使用 [MIT 许可证](LICENSE)。下列素材和服务**不受** MIT 许可证约束，各自适用自己的授权。

The source code of this project is under the [MIT License](LICENSE). The assets and services below are **not** covered by it; each keeps its own terms.

## 内置素材 / Bundled assets（`Resources/Glass3DStarter/`）

| 素材 | 作者 | 授权 | 来源 |
|---|---|---|---|
| Platformer Characters 1（5 个角色的姿势图，行走、攻击、欢呼由本项目合成为 GIF） | Kenney（kenney.nl） | CC0 1.0 | https://opengameart.org/content/platformer-characters-1-5-characters |
| 12 张贴图（缩小为 512×512） | Poly Haven 作者，见 `manifest.json` | CC0 1.0 | https://polyhaven.com |

CC0 作品已进入公有领域，可自由使用、修改、分发和商用，无需署名。授权原文见同目录的 `LICENSE-Kenney.txt`、`LICENSE-PolyHaven.txt`。

CC0 works are in the public domain: free to use, change, share and sell, no credit required. Licence texts: `LICENSE-Kenney.txt`, `LICENSE-PolyHaven.txt` in the same folder.

## 通用角色底模 / Universal character base body（`Resources/HumanBase/`）

| 素材 | 作者 | 授权 | 来源 |
|---|---|---|---|
| MakeHuman hm08 基础网格、默认骨骼、默认蒙皮权重和体型 target（由 `tools/humanbase/build_humanbase.py` 处理成中性 T-Pose 人台、三级 LOD 和 18 个体型通道） | MakeHuman 项目（Data Collection AB、Joel Palmius、Jonas Hauquier 等） | CC0 1.0 | https://github.com/makehumancommunity/makehuman（提交 `a8bc2d5`） |

只使用 MakeHuman 的素材（CC0），不包含其 AGPL 程序代码。授权原文见 `Resources/HumanBase/LICENSE-MakeHuman-CC0.md`，来源和构建方法见 `Resources/HumanBase/SOURCE.md`。

Only MakeHuman's assets (CC0) are used, none of its AGPL program code. Licence text: `Resources/HumanBase/LICENSE-MakeHuman-CC0.md`; source and build steps: `Resources/HumanBase/SOURCE.md`.

## 本地 AI 模型 / On-device AI model（`Resources/DepthModel/`）

| 模型 | 作者 | 授权 | 来源 |
|---|---|---|---|
| Depth Anything V2 Small（Apple Core ML 转换版 `DepthAnythingV2SmallF16`） | Lihe Yang 等；Core ML 转换：Apple | Apache License 2.0 | https://huggingface.co/apple/coreml-depth-anything-v2-small |

只在 iPhone 本地运行，用于从单张图片估计深度。权重文件在构建时按固定版本下载并校验 SHA-256，授权全文见 `Resources/DepthModel/LICENSE-Apache-2.0.txt`。

Runs only on the device to estimate depth from one picture. The weights are downloaded at build time from a pinned revision and checked by SHA-256; the licence text is in `Resources/DepthModel/LICENSE-Apache-2.0.txt`.

## 在线服务 / Online services

- **Poly Haven API**（api.polyhaven.com）：按其[服务条款](https://github.com/Poly-Haven/Public-API/blob/master/ToS.md)，请求带有本应用的 User-Agent，界面中注明 “Powered by Poly Haven”。贴图本身为 CC0。本项目只调用其接口，不包含其 AGPL 代码。
- **Openverse API**（api.openverse.org）：只用于搜索。图片由用户在应用内自行下载，不随本项目分发；默认只显示 CC BY、CC BY-SA、CC0 和公有领域作品，不包含“禁止改编（ND）”和“非商业（NC）”授权。每个导入的图片会记录作者、授权和署名文字，可在应用的「素材来源与授权」页面查看。授权信息由 Openverse 提供，以原始页面为准；照片中的人像、商标不在 CC 授权范围内。

Poly Haven is used under its API terms (app User-Agent, "Powered by Poly Haven" credit). Openverse is used for search only; images are downloaded by users, not distributed with this project, and limited to BY, BY-SA, CC0 and public domain (no ND / NC). Each import records its author, licence and credit line, shown on the in-app Credits page.

Kenney、Poly Haven、Openverse 的名称仅用于注明来源，不表示这些项目认可或背书本应用。

The names Kenney, Poly Haven and Openverse are used only to credit sources and do not imply endorsement.
