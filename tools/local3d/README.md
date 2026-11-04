# 月淡本地 3D 服务（电脑生成）

在你自己的电脑上跑开源 3D 生成模型，月淡通过同一个 Wi-Fi 上传图片、下载模型。图片不会经过任何第三方云。

## 启动

```
python server.py --backend dummy            # 先用彩色立方体测试连接
python server.py --backend triposr --triposr-path ./TripoSR
python server.py --backend hunyuan3d --mini # Hunyuan3D-2mini，显存要求较低
```

启动后会打印「在 App 里填：192.168.x.x:8765」。在月淡里打开「AI 生成 3D」→「AI 图片转完整 3D」→「电脑生成」，填上这个地址，点「测试连接」。

建议加上 `--token 你的密码`，再把同一个令牌填进 App。不加令牌的话，同一网络里的任何人都能提交任务。

## 后端

| 后端 | 安装 | 说明 |
| --- | --- | --- |
| `triposr` | `git clone https://github.com/VAST-AI-Research/TripoSR`，再按它的 requirements 安装，并 `pip install rembg` | 快；NVIDIA 显卡、Apple MPS、CPU 都能跑；输出顶点颜色 |
| `hunyuan3d` | 按 https://github.com/Tencent/Hunyuan3D-2 的说明安装 | 形体和贴图更好，需要 NVIDIA 显卡；腾讯混元社区许可，在欧盟、英国、韩国不适用 |
| `dummy` | 无需安装 | 返回彩色立方体，只用来检查连接 |

## 状态

- 服务的接口流程已用 `dummy` 后端实际测试过：创建、进度、下载、取消、删除、令牌。
- `triposr` 和 `hunyuan3d` 后端是按两个项目公开的 Python 用法编写的，没有在有显卡的电脑上实际运行过。

## 接口

| 接口 | 用途 |
| --- | --- |
| `GET /v1/health` | 检查连接，返回所用后端 |
| `POST /v1/image3d/jobs` | 上传图片（JPEG/PNG），创建任务 |
| `GET /v1/image3d/jobs/{id}` | 查询状态和进度 |
| `POST /v1/image3d/jobs/{id}/cancel` | 取消任务 |
| `GET /v1/image3d/jobs/{id}/result` | 下载结果（GLB） |
| `DELETE /v1/image3d/jobs/{id}` | 删除任务 |
