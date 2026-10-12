# 原生/UX 立即对齐的契约

P0 候选，尚未部署；当前云端仍 API v14。SwiftUI 主工程无需新增依赖。

1. POST `/catpaw/chat/v1/scopes/{scope}/conversations/{cid}/turns` 仍使用 v1 text 请求与 SSE 事件。新的 `turn_started` sequence=1 与 user message/冻结 turn 同事务提交；它的 `data.request_hash`、`data.conversation_revision` 和 envelope.grant_epoch 是持久受理回执，不代表回答成功。本地 user echo 应立即持久化，排队/发送中/已受理分别展示。
2. 候选新增 GET `…/turns/{tid}/events?after_sequence=N` 返回同一 v1 SSE；GET `…/turns/{tid}?after_sequence=N` 返回状态＋事件尾部。新 HTTP 请求重新鉴权；保留 tid/request hash/epoch/last durable sequence。EOF 不算完成，断线读原 tid，不重发 POST；gap 读快照，terminal/unknown 以明确回执为准。无 Last-Event-ID 自动重放承诺。GET cursor 错误在响应前返回 422，scope/撤权错误返回 403/409，不重放旧内容。
3. `(turnID,callID)` 一个工具 pill。tool_call 更新为处理中，tool_result 更新同一 pill；两种 wire/history 都保留。原生目前将已完成调用行和结果行都显示“任务进展已读取”，应在展示层合并。状态查询不是用户回答。服务器 readonly capability 声明 `image_input/live_weather/web_search=false`；当前天气/实时信息无法查询，不能用 agent_status 代替。
4. footer：服务连通/Auth/readiness 与最近一轮结果分开。连接已建立可以显示“已连接”；部分回答、未完成、读取原请求分别可见。“停止观察”只断开本机 stream，不取消云端工作。明确云端 turn_failed 后说明本轮回复未完成；真正受理未知才说明发送结果未确认。

## 图片契约（下一切片，P0 默认不支持外发）

提案 schema_version=2，message.parts 顺序冻结：`{type:'text',text}` 或 `{type:'image_attachment',attachment_id,version,sha256}`。attachment 由服务器验证 subject/scope/conversation 归属、MIME、尺寸、bytes/hash、去 EXIF 后生成不可变版本。拒绝任意 URL/跨 scope 引用；HTTP v1 不接收图片/base64，不能靠 UI 图片按钮宣称已支持。

首个短期 demo 可只处理 request-scoped data URI：用户主动选图→本地预览/缩图/去 EXIF→服务端再次验证→请求结束释放。限制建议 JPEG/PNG/WebP、1张、5MiB、最长边2048；这些是产品/后端待冻结的上限。无持久图片历史承诺；历史图片必须另建私有 bucket、归属校验、保留/删除契约。正文/base64/EXIF/签名 URL 不进日志。当前文字授权不能复用为图片：需要新 consent_version/route_hash、image字段、处理者名称、用途、保留期和删除边界；默认拒绝外发。

父任务只读候选：`google/gemma-4-31b-it:free`，备选 `google/gemma-4-26b-a4b-it:free`，provider tag `google-ai-studio`。父任务核实官方表 No training 但约55天 retention；实际 deny 过滤兼容未验。Dots `dots-studio/dots-3-note-preview:free` 的 `atlas-cloud/fp8` 保留 prompts，required/named tool_choice 支持不足。保留 deny/require_parameters=true/allow_fallbacks=false/zero max_price；不放宽隐私。当前 Novita/Apodex 路线未改，图片 consent 未新增。[官方端点](https://openrouter.ai/api/v1/models/google/gemma-4-31b-it:free/endpoints)、[providers](https://openrouter.ai/providers) 为父任务独立核实来源，本修复未重复调研或真实试接。

## 天气契约（下一切片，当前未实现）

建议 `get_weather({place,date_range,time_zone,units})`：用户给出城市，不读手机定位；服务器解析“这周”的明确日期/时区，地名歧义先询问。结果含 `place/range/timezone/fetched_at/source_url/forecast/units/data_version`，错误是 typed unavailable/unsupported。回答必须基于实际返回并标预报/来源，不用旧知识填空。Open-Meteo 是可信只读候选，免费非商业原型有额度/署名要求，商业上线需评估许可。工具未启用时明确无法查实时天气，不委托空依据报告。[官方文档](https://open-meteo.com/en/docs)、[许可/价格](https://open-meteo.com/en/pricing)。

P0 只添加 capability 声明和对应模型指令，没有天气请求、搜索接入、图片上传/模型调用或新第三方授权。
