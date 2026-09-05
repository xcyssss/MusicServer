# MusicServer Architecture Audit

审计日期：2026-08-25

## 1. 当前系统架构

当前项目是 Windows 上的 PowerShell 脚本集合，Navidrome 负责本地音乐库和播放，网易云 API 负责推荐/歌词元数据，yt-dlp 负责 Bilibili 音频提取。项目没有独立的应用数据库、HTTP API、后台队列或 Provider 注册层；运行状态主要落在 `DailyMix_data\*.csv`，本地曲库落在 `Music\`。

关键运行组件：

- `daily_recommend.ps1`：每日推荐、Bilibili 搜索、下载、ffprobe 校验、歌词写入、播放列表更新。
- `daily_cleanup.ps1`：读取 Navidrome 星标，喜欢的日推移动到主库，其他日推删除并加入黑名单。
- `fetch_lyrics.ps1`：对本地文件通过网易云搜索匹配歌词。
- `add_song.ps1`、`download_bilibili_favorites.ps1`：独立的人工/收藏夹下载入口。
- `lib_playlist.ps1`：写入 Navidrome 自动导入的 m3u 播放列表。
- `Navidrome\navidrome.toml`：音乐目录为 `Music\`，监听扫描间隔为 6 小时，外部 `.lrc` 优先。

当前已有两个计划任务：`MusicServer_DailyCleanup` 06:30，`MusicServer_DailyRecommend` 07:00。

## 2. 当前推荐流程

`daily_recommend.ps1` 的实际流程为：

1. 从 `accepted.csv`、Navidrome 星标、`history.csv` 和 `lyrics_report.csv` 收集种子。
2. 调用网易云搜索和 `simiSong` API，按重复、黑名单、时长和内容关键词过滤。
3. 对每一首候选调用 `bilisearch10:<title artist>`。
4. 通过 yt-dlp 直接下载 MP3 到 `Music\DailyMix`。
5. 下载完成后用 ffprobe 检查本地时长，差值超过 45 秒才删除。
6. 调网易云歌词 API、写 `.lrc`，更新 `today.csv`/`history.csv` 和 m3u。
7. 等待 Navidrome 发现文件。

因此每日推荐是否成功依赖 Bilibili 下载是否成功，且推荐阶段已经产生音频网络请求。

## 3. 当前 Bilibili 调用链

主要调用链是：

`daily_recommend.ps1` -> `yt-dlp.exe bilisearch10:<keyword>` -> Bilibili 搜索/提取 -> 下载音频 -> ffmpeg 后处理。

`daily_recommend.ps1` 内虽然配置了最多三次尝试、sleep 和“连续 412 后停止”，但这些保护仍然位于单首歌曲循环内部，没有 Provider 级健康状态。因此 412 被当作当前歌曲失败，而不是 Bilibili Provider 被阻断。

另外两个人工入口也直接调用 yt-dlp：`add_song.ps1` 下载明确 URL，`download_bilibili_favorites.ps1` 下载收藏夹。它们属于人工导入路径，不应被日推核心依赖。

## 4. 当前下载流程

下载输出到 `Music\DailyMix`，使用视频标题生成文件名，嵌入缩略图和元数据。歌词为同名外部 `.lrc`。次日 `daily_cleanup.ps1` 通过 Navidrome 数据库副本读取星标：

- 已星标：移动到 `Music\` 根目录并写入 `accepted.csv`。
- 未星标：删除 MP3/LRC 并写入 `rejected.csv`。

这是一套“先下载、后试听、次日清理”的流程，无法表达“远程推荐但尚未下载”的状态。

## 5. 当前数据模型

目前没有稳定的逻辑歌曲 ID。`NeteaseId` 只存在于 CSV 中，文件名是下载歌曲和 Navidrome 记录之间的事实连接。

- `today.csv` / `history.csv`：`Date, NeteaseId, Title, Artist, Duration, FromSeed, File`。
- `accepted.csv`：`AcceptedAt, NeteaseId, Title, Artist, File`。
- `rejected.csv`：`RejectedAt, NeteaseId, Title, Artist, FromSeed`。
- Navidrome 的 `media_file.id` 和 `annotation.starred` 是外部系统状态，脚本只读数据库副本。

这造成远程推荐、日推文件和主库歌曲之间的身份不稳定，也使“红心”只能通过 Navidrome 的本地文件星标间接发现。

## 6. 可以直接复用的模块

- 网易云的搜索、相似歌曲和歌词 API 调用方式。
- 现有过滤规则、种子来源和 CSV 黑名单/接受记录，作为迁移兼容输入。
- `lib_playlist.ps1` 的 m3u 写入逻辑。
- `fetch_lyrics.ps1` 的歌词匹配与外部 `.lrc` 写入逻辑。
- `fix_tags.ps1`、Navidrome 配置和现有人工下载脚本。
- Navidrome 数据库“复制后查询”的安全做法。

## 7. 应重构的代码

- `daily_recommend.ps1` 的下载阶段必须移除，改为只生成 CanonicalTrack 和 DailyRecommendation。
- Bilibili yt-dlp 搜索、精确 URL 下载、时长验证应移入 Provider 层。
- `accepted.csv` 的“次日星标”机制应兼容保留，但新的主路径使用显式 like -> Wanted Queue。
- 重复的路径、工具和状态文件配置应集中到共享模块。
- 下载失败、412、重试和状态变更应改为结构化 JSONL 事件。

## 8. 应删除或废弃的行为

- 日推阶段调用 yt-dlp 下载音频。
- 日推阶段等待 Bilibili 冷却或重试 Bilibili。
- 下载完整音频后才首次判断候选时长。
- 通过创建假音频或直接修改 Navidrome 数据库伪造远程歌曲。第一版不采用这些方式。

旧的 `add_song.ps1` 和收藏夹下载脚本保留为人工导入工具；它们不再是推荐系统的依赖。旧版 `daily_cleanup.ps1` 继续作为历史 DailyMix 文件的兼容清理器。

## 9. Proposed architecture

第一版新增以下边界：

```text
NetEase recommendation metadata
          |
          v
CanonicalTrack + DailyRecommendation (JSON state, CSV compatibility)
          | like
          v
WantedQueue --------------------------> music_api.ps1
          |                              GET/POST/DELETE API
          v
wanted_worker.ps1
  local match -> exact candidate -> other providers -> Bilibili search fallback
          |
          v
validate -> metadata/lyrics -> Music\ -> Navidrome scan -> local_song_id
```

`MusicServer.Core.psm1` 提供稳定 track ID、状态文件、like/wanted 状态、迁移读取、结构化日志和本地匹配；`MusicServer.Providers.psm1` 提供 Provider 抽象、候选评分、ProviderHealth 与 Bilibili Circuit Breaker；`music_api.ps1` 只改变逻辑状态，不等待下载；`wanted_worker.ps1` 承担异步下载。

Preview source 与 download candidate 是两个独立字段。当前可生成一个轻量的网易云页面/媒体 URL 作为 preview source；Bilibili 仅在 worker 处理 WantedTrack 时作为候选 Provider，且搜索永远是后置兜底。

## 10. Migration plan

### Phase 1 — 本次实现

- 新增 CanonicalTrack、DailyRecommendation、WantedTrack JSON 状态，并从旧 CSV 兼容迁移。
- 重写日推脚本：只请求推荐元数据，不调用 yt-dlp、Bilibili 下载、ffprobe、歌词下载或 Navidrome 扫描。
- 提供 like/wanted/provider status 的本地 HTTP API。

### Phase 2 — 本次实现

- 新增 LocalProvider、BilibiliDirectProvider、BilibiliSearchProvider。
- 新增统一候选评分、下载前 duration/identity 过滤和结构化 worker 日志。

### Phase 3 — 本次实现

- 新增 ProviderHealth 和 Bilibili CLOSED/OPEN/HALF_OPEN Circuit Breaker。
- 412 只打开 Bilibili Provider；其他 WantedTrack 不被串行 sleep 阻塞。

### Phase 4 — 后续增强

- 接入真实第三方 preview provider 或自研前端播放器。
- 增加其他下载 Provider，并将 Navidrome 扫描/歌曲 ID 绑定改为 API 优先。
- 将 JSON 状态迁移到 SQLite（当前 JSON 文件通过原子替换保持实现简单且不改动 Navidrome DB）。

本次迁移刻意不删除旧 CSV，也不自动改写已有 Navidrome 数据库；旧的历史 DailyMix 可继续由 `daily_cleanup.ps1` 清理。
