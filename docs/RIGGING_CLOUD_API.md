# 云端绑定服务接口（v1.73 客户端约定）

Moonlight 不内置任何云端服务或密钥。用户在「自动骨骼 → 高级设置」中填写自己的服务地址（HTTPS）和访问令牌，令牌保存在钥匙串里。每次上传前都要用户确认。

所有请求都带 `Authorization: Bearer <令牌>` 和 `Accept: application/json`。

| 接口 | 用途 | 请求 | 成功返回 |
| --- | --- | --- | --- |
| `POST /v1/rig/jobs` | 创建任务 | body 为 GLB（`Content-Type: model/gltf-binary`），选项放在 `X-Rig-Options` 头 | `{"id","status","progress"}` |
| `GET /v1/rig/jobs/{id}` | 查询 | — | `{"id","status","progress","message"}` |
| `POST /v1/rig/jobs/{id}/cancel` | 取消 | — | 任务 JSON |
| `GET /v1/rig/jobs/{id}/result` | 取回结果 | — | 结果 JSON（见下） |
| `DELETE /v1/rig/jobs/{id}` | 删除任务和上传文件 | — | 2xx |

`status` 取值：`queued`、`running`、`succeeded`、`failed`、`cancelled`、`deleted`。

错误码：401/403 表示令牌无效，404/410 表示不存在或已过期，413 表示文件过大，400/422 表示模型被拒（可附带 `{"message"}`），429 表示请求太频繁，5xx 表示服务错误。

客户端行为：
- 上传上限 64 MB，超过 150,000 面的模型先简化到 100,000 面再上传；
- 轮询间隔从 1.5 秒起递增，最长 10 秒，10 分钟后超时；
- 取消时先请求服务端取消。

## 结果格式（`moonlight-rig-1`）

```json
{
  "formatVersion": 1,
  "vertexCount": 12345,
  "skeleton": { "joints": [ {
      "jointID": "pelvis", "parentID": null,
      "restTransform": [16 个数，列主序，相对父关节],
      "inverseBindMatrix": [16 个数，列主序，模型空间],
      "jointLimit": {"min": [-60,-90,-45], "max": [60,90,45]},
      "semanticTag": "pelvis", "confidence": 0.9 } ] },
  "joints": [每个顶点 4 个关节索引，255 = 未使用],
  "weights": [每个顶点 4 个权重],
  "engine": "UniRig …", "notes": []
}
```

- 顶点顺序必须与上传的 GLB 相同。
- 父关节必须排在子关节之前。
- `semanticTag` 使用 Moonlight 的人形名称（`pelvis`、`rightUpperArm` 等）时，动作库可以直接驱动这个骨骼；其他名称会读作 `other`，标准动作驱动不了它们。

客户端会拒绝以下结果：
- 版本不符；
- 顶点数不符；
- 有环或多个根；
- 矩阵无效，或与逆绑定矩阵不一致；
- 权重为负或无效、关节索引越界、权重总和明显不为 1。

通过这些检查后，结果还要跑和本地相同的 8 项动作测试，由用户确认后才保存。

UniRig（VAST-AI-Research）等方案的发布模型与论文配置不完全相同。服务端需要把它的输出转换成上面的格式，并实际测试质量。**v1.73 没有部署或测试任何服务端。**
