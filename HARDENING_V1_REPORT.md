# MusicServer Hardening v1

日期：2026-08-27

分支：`review/musicserver-hardening-v1`

## 本轮目标

本轮不做大规模存储迁移或 UI 重写，优先修复会污染推荐数据、下载错误歌曲、错误恢复 Provider、以及用户取消无效的问题。

## 已完成

### 1. 推荐反馈闭环

- `recommendation_history` 不再因为“曾经展示过”就自动成为下一轮种子。
- 强正反馈来自：显式 like、已接受/已本地化歌曲、Navidrome starred。
- 普通本地库仅作为低权重 fallback seed。
- 最近 14 天已经展示过的网易云歌曲进入推荐冷却，降低推荐自我强化和重复曝光。
- like 字段兼容 bool 与常见字符串表示，避免字符串 `False` 被 PowerShell 错当成真值。

### 2. 下载候选身份校验

- Bilibili `uploader` 不再被错误视为歌曲 Artist。
- 搜索候选必须通过 title / artist evidence / duration 的前置身份门槛。
- 普通歌曲的时长容差从固定 45 秒收紧为自适应阈值：`max(8s, min(20s, duration * 5%))`。
- 下载后的 ffprobe 校验使用同一自适应阈值。
- 下载源由 `worstaudio/worst` 改为 `bestaudio/best`。

### 3. Bilibili Circuit Breaker

- 将原来的单一 `bilibili` 健康状态拆成：
  - `bilibili_search`
  - `bilibili_download`
- 搜索成功不再清除下载端的 412 连续失败计数。
- direct candidate 的解析阶段不再提前消费 HALF_OPEN 探针；真正媒体请求才消费探针。
- 下载端处于 OPEN 时，不再额外浪费 Bilibili 搜索请求。

### 4. Wanted Queue 取消语义

- unlike 对 `WANTED / RETRY_WAIT / UNAVAILABLE` 立即移除队列。
- unlike 对 `RESOLVING / DOWNLOADING / VALIDATING` 写入 `CANCEL_REQUESTED`。
- worker 在解析、下载、校验和入库等关键边界重新检查取消状态。
- 下载完成但尚未本地化时收到取消，会删除暂存音频而不是继续写入主音乐库。
- 修复 CanonicalTrack 状态保护逻辑，显式取消可以真正回到 `REMOTE`，同时重复推荐仍会保留已有 `LOCAL` 状态。

### 5. 本地绑定与机器可移植性

- Navidrome song id 优先按相对路径精确绑定；仅当文件名唯一时才允许 leaf-name fallback。
- yt-dlp / ffprobe / ffmpeg / sqlite 解析顺序调整为：环境变量 -> PATH -> 当前机器旧路径 fallback。
- 支持：`MUSICSERVER_YTDLP`、`MUSICSERVER_FFPROBE`、`MUSICSERVER_FFMPEG`、`MUSICSERVER_SQLITE`。

### 6. 回归验证

新增 Windows GitHub Actions 核心回归流程，使用 Windows PowerShell + Pester 3.4，覆盖：

- stable canonical identity；
- like 幂等与取消；
- 本地误匹配保护；
- Bilibili 搜索候选身份 gate；
- 自适应时长校验；
- search/download circuit 隔离；
- HALF_OPEN probe；
- 环境变量工具路径；
- 日推不触发下载；
- 推荐不把中性 history 当正反馈；
- bestaudio；
- worker cancellation guard。

## 刻意留到 v2 的问题

### SQLite 状态迁移

当前 JSON 使用原子替换，但 API、worker 和日推之间仍没有跨文件事务。下一阶段建议迁移到 SQLite，并把 like + queue + track status 放在同一事务中。

### API / Navidrome 查询性能

`music_api.ps1` 仍是同步 HttpListener，Navidrome 查询仍通过复制 DB + sqlite3 进程完成。音乐库继续扩大后，应加入 snapshot cache 或直接使用只读 SQLite 连接，并减少 15 秒全量刷新成本。

### 真正的第二下载 Provider

目前 `bilibili_direct` 与 `bilibili_search` 仍属于同一个 Bilibili failure domain。Provider 抽象已经存在，但还需要一个真正独立的合法来源才能形成跨 Provider fallback。

### 更强的 recording identity

当前 CanonicalTrack 主要按 title + artist 建立逻辑 ID。后续可单独引入 Recording/Release identity，并根据可用条件增加外部 ID、tag metadata 或音频 fingerprint，进一步区分 remaster、acoustic、radio edit 等版本。
