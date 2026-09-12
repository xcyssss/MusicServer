# 下载链路与排查

LIKE 的成功以 SQLite 事务为准：收藏反馈、WANTED 状态和队列一起提交。重复 LIKE 不重置活跃下载的租约或尝试次数；本地歌曲只记录偏好。

处理顺序：本地匹配 → 已知候选 → 已知资源均失败后最多一次搜索兜底。搜索结果仍需通过身份和时长验证；同一 URL 每轮只尝试一次。Bilibili 搜索和下载分别检查熔断状态，不影响其他健康来源。网易云同名同长度的其他歌手不能靠时长获得身份认可。

失败进入 RETRY_WAIT，遵循指数退避或来源冷却；达到 max_attempts 后进入 UNAVAILABLE，由用户明确重试。取消请求和租约丢失优先终止处理。诊断日志不改变 SQLite 的权威地位。

下载动态显示失败原因、已尝试次数和预计重试时间。APP_HOME/logs/musicserver-worker.log 中用 track= 关联 [candidate]、[fallback]、[transition]、[processed]；最后一项含耗时，异常记录处理阶段。STATE_TRANSITION 等 SQLite events 保留状态审计。推荐摘要在 musicserver-recommendation.log 中记录候选数、最终数量、关联降权和多歌手分散策略。日志经统一轮转函数写入。

验证：tests/MusicServer.DownloadPipeline.Tests.ps1 使用真实临时 SQLite 与真实 worker 函数，仅替换网络下载和最终文件写入；不能据此声称第三方在线音源永远可用。正式候选还需用有下载权限的真实歌曲检查完整下载、校验、入库和重新播放。
