# MusicServer Architecture Upgrade — Implementation Report

实施日期：2026-08-25

## 1. 修改了哪些文件

新增：

- `ARCHITECTURE_AUDIT.md`：现状审计、问题链路、目标架构和迁移计划。
- `MusicServer.Core.psm1`：CanonicalTrack、推荐状态、Wanted Queue、稳定 ID、本地匹配、JSON 状态、结构化事件。
- `MusicServer.Providers.psm1`：Provider 抽象、Local/Bilibili Direct/Bilibili Search、候选评分、ProviderHealth、Circuit Breaker。
- `wanted_worker.ps1`：异步处理喜欢歌曲的 worker。
- `music_api.ps1`：前端无关的本地 HTTP API。
- `register_wanted_worker.ps1`：可选的 Windows 计划任务注册/移除脚本。
- `tests\MusicServer.Core.Tests.ps1`：核心行为测试。

重构：

- `daily_recommend.ps1`：改为 metadata-only 推荐，不再下载音频。

保留不变：

- `daily_cleanup.ps1`、`fetch_lyrics.ps1`、`fix_tags.ps1`、`add_song.ps1`、收藏夹下载脚本和 `lib_playlist.ps1`。
- 这些脚本继续服务于历史 DailyMix 清理、人工导入、歌词和标签维护，不再是新日推流程的依赖。

## 2. 新增数据模型

状态写入 `DailyMix_data\state\`，使用 JSON 文件并通过临时文件原子替换：

- `tracks.json`：CanonicalTrack，主键为稳定的 `track_<sha256前24位>`。
- `recommendations.json`：当天 DailyRecommendation。
- `recommendation_history.json`：推荐历史。
- `wanted.json`：WantedTrack 队列。
- `providers.json`：ProviderHealth 和 Circuit Breaker 状态。
- `events.jsonl`：结构化事件日志。

旧的 `today.csv` 仍然会更新，增加 `TrackId`、`PlaybackSource`、`Liked`、`Status` 等列；远程推荐的 `File` 为空，表示尚未下载。既有 CSV 不会被删除。

## 3. 日推新流程

```text
accepted.csv / Navidrome / lyrics_report.csv
        -> 网易云搜索 + simiSong metadata
        -> CanonicalTrack + DailyRecommendation
        -> preview_sources + download_candidates
        -> API/UI 展示和试听
```

`daily_recommend.ps1` 不再调用 yt-dlp，也不再调用 Bilibili、ffprobe、歌词下载或 Navidrome 扫描。Bilibili 只会在 Wanted worker 处理用户明确喜欢的歌曲时调用。

试听源当前写入网易云页面和媒体 URL；`playback_source` 使用 `netease:<id>`。是否能直接播放取决于前端和网易云当前访问权限，MusicServer API 不绑定具体播放器。

## 4. 红心后的新流程

```text
POST /api/tracks/{track_id}/like
        -> liked=true
        -> WantedTrack=WANTED
        -> 立即返回

wanted_worker.ps1
        -> 本地文件匹配
        -> 已知精确候选
        -> Provider ranking
        -> Bilibili metadata search（最后兜底）
        -> 下载
        -> ffprobe 最终校验
        -> 歌词
        -> 移入 Music\
        -> Navidrome scan
        -> local_song_id 绑定
```

worker 对每首歌曲独立处理；失败只改变该 WantedTrack 状态，不阻塞其他歌曲。

## 5. Provider fallback 顺序

1. `local`：按标准化 title/artist 匹配 `Music\` 中的 MP3。
2. `bilibili_direct`：CanonicalTrack 中已有明确 BVID/URL 时使用。
3. 其他 Provider 扩展点：通过 `New-DownloadProviderRegistry` 接入。
4. `bilibili_search`：仅在没有本地/精确候选时调用 `bilisearch10` 做 metadata 搜索。

搜索结果在下载前按 title、artist、duration、provider health、请求成本和 priority 评分；duration 差异超过 45 秒的候选不会进入下载。ffprobe 仍作为下载后的第二层安全校验。

## 6. Circuit Breaker 参数

- 状态：`CLOSED`、`OPEN`、`HALF_OPEN`。
- HTTP 412：Provider-level failure，记录 `last_412_at`、`consecutive_412`、`blocked_until`。
- 首次 412 冷却 15 分钟。
- 后续 412 指数增加：15、30、60……分钟，最大 360 分钟。
- `OPEN` 期间完全禁止 Bilibili 请求，WantedTrack 进入 `RETRY_WAIT`。
- 冷却结束后只允许一个 `HALF_OPEN` 探针；成功回到 `CLOSED`，再次 412 重新 `OPEN`。
- worker 不执行“sleep 180 秒后继续下一首”的串行阻塞策略。

## 7. API

启动：

```powershell
cd E:\Project\MusicServer
.\music_api.ps1
```

默认监听 `http://127.0.0.1:8787/`：

- `GET /api/recommendations/today`
- `GET /api/tracks/{track_id}`
- `POST /api/tracks/{track_id}/like`
- `DELETE /api/tracks/{track_id}/like`
- `GET /api/wanted`
- `POST /api/wanted/{track_id}/retry`
- `GET /api/providers/status`
- `GET /health`

API 只负责快速更新状态，不等待下载。

## 8. 如何启动 worker

手动处理一轮：

```powershell
.\wanted_worker.ps1 -Once
```

常驻轮询：

```powershell
.\wanted_worker.ps1 -PollSeconds 30
```

注册每分钟处理一次的 Windows 计划任务：

```powershell
.\register_wanted_worker.ps1
```

移除该任务：

```powershell
.\register_wanted_worker.ps1 -Unregister
```

现有 `MusicServer_DailyRecommend` 计划任务可以继续使用；它现在只生成推荐 metadata。现有 `MusicServer_DailyCleanup` 仍负责清理旧版 `Music\DailyMix` 文件。

## 9. 测试和验证

已通过：

- Pester：8 个测试全部通过。
- PowerShell 脚本/模块语法检查：`daily_recommend.ps1`、`wanted_worker.ps1`、`music_api.ps1`、计划任务脚本和两个模块全部通过。
- API 冒烟：`/health` 返回 `{"status":"ok"}`。
- API like 冒烟：POST 后立即返回 `liked=true`，Wanted 状态为 `WANTED`。
- worker 本地匹配冒烟：已有本地文件直接变为 `LOCAL`，没有触发远程 Provider。
- 真实项目 DryRun：`daily_recommend.ps1 -DryRun -Count 1 -SeedCount 1` 完成，输出确认无 yt-dlp/Bilibili/ffprobe/歌词/Navidrome 调用。

测试命令：

```powershell
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester .\tests\MusicServer.Core.Tests.ps1
```

## 10. 已废弃的旧逻辑

- 日推阶段 Bilibili 搜索和完整音频下载。
- 日推阶段的 Bilibili 重试、sleep、连续 412 中止逻辑。
- 下载后才第一次判断候选时长的流程。
- 用 Navidrome 数据库伪造远程歌曲或假 MP3 的方案。

人工 `add_song.ps1` 和收藏夹批量下载仍可使用，但它们不应被当作推荐系统的 Provider 调度入口。

## 11. 当前仍未完成的问题

- 当前只有 Local 和 Bilibili 两类实际 Provider；其他 Provider 只有注册扩展点，没有具体实现。
- 网易云 preview URL 受地区、登录和接口策略影响，尚未提供自有音频代理。
- API 暂以 `HttpListener` 运行，尚未加入认证、跨域策略和多用户权限。
- Navidrome 的 `local_song_id` 在扫描尚未完成时可能暂为空；worker 会在扫描后再次查询，未查到时仍保留本地文件和 `LOCAL` 状态。
- 状态存储第一版使用 JSON；多个 worker 并发写入时还需要文件锁或迁移到 SQLite。
- 旧版 `daily_cleanup.ps1` 仍通过 Navidrome 星标清理历史 DailyMix，尚未完全迁移为 CanonicalTrack like 状态。

## 12. 下一步建议

1. 先运行 API、注册 Wanted worker，然后用一个测试推荐验证 like -> queue -> local/download 全链路。
2. 为 preview 增加前端适配层或稳定的预览 Provider。
3. 接入第二个合法下载 Provider，验证 Bilibili OPEN 时的真正跨 Provider fallback。
4. 将 JSON 状态迁移到带事务和锁的 SQLite，同时保留 CSV 兼容导出。
5. 为 API 加认证，并把 Navidrome scan/绑定改成可重试的独立步骤。

---

# 第二阶段增量（2026-08-25）

## 用户体验闭环

新增 `web\index.html`、`web\styles.css`、`web\app.js`，由 `music_api.ps1` 同源提供：

- 展示今日推荐列表、推荐原因、时长、喜欢状态和 Wanted/本地化状态。
- 远程歌曲点击即可使用 preview source 播放。
- 已本地化歌曲优先使用 `/api/tracks/{track_id}/stream` 本地播放桥接，并保留 Navidrome song ID。
- ❤️ 操作乐观更新，API 完成后自动同步 Wanted 状态。
- 页面每 15 秒刷新，worker 状态会自动从“待下载/解析/下载中/等待重试/已本地化”变化。

`GET /api/recommendations/today` 现在返回聚合后的 `track`、`preview_source`、`playback_source`、`liked`、`local_status` 和 `wanted`。

## 一致性保护

- 同一 CanonicalTrack 再次被推荐时，保留已有 `LOCAL` 状态、`local_song_id` 和历史下载候选，不会生成第二个逻辑歌曲。
- Live 标记保留在 track identity 中，不会与 studio 版本自动合并。
- like 重复调用不会创建多个 WantedTrack。
- worker 使用跨进程 named mutex；计划任务重叠时后启动实例会跳过，进程崩溃后 mutex 自动释放，不会留下永久 stale lock 文件。

## 第二阶段验证

- Pester：10 个测试全部通过。
- API 静态页面：`GET /` 返回 200。
- 推荐聚合：返回嵌入 CanonicalTrack 和 playback source。
- API like：立即返回 `liked=true` 和 `WANTED`。
- 本地音频桥接：完整响应 200，Range 请求响应 206。

## 一键启动

- 桌面「Navidrome 音乐服务器.lnk」现在直接调用 `wscript.exe` 和 `start_musicserver.vbs`，三个组件后台启动，不创建可见 PowerShell 控制台。
- 启动器只使用现有 PowerShell 脚本，不使用 `ExecutionPolicy Bypass`；等待约 5 秒后打开 `http://127.0.0.1:8787/`。
- 当前快捷方式修改前的版本备份为 `Navidrome 音乐服务器.lnk.before-vbs`；早期版本仍保存在 `Navidrome 音乐服务器.lnk.before-musicserver`。
- 为兼容 Windows PowerShell 5.1，新增/修改的 PowerShell 模块和脚本已统一保存为 UTF-8 BOM；已验证模块导入成功、API 200、日推页面标题正确。

## 音乐库整合（2026-08-25）

- 日推页面改为桌面端双栏：左侧本地音乐库，右侧今日推荐；音乐库支持搜索、顺序/随机播放和已标星提示。
- `music_api.ps1` 新增 Navidrome 数据库读取、`/api/library`、`/api/library/{id}/stream` 和歌词接口；数据库只读复制后查询，不修改运行中的 Navidrome DB。
- 本地播放继续由 MusicServer 音频桥接提供 Range 响应；相邻 `.lrc` 优先于 `.txt`，前端支持时间轴高亮和滚动。
- 已验证：API 返回 165 首实际存在的本地歌曲；歌词返回 `.lrc`；音频 Range 返回 206；页面返回 200；Pester 10/10 通过。

## 歌词与播放控制修复（2026-08-25）

- 歌词接口现在读取精确本地文件；日推已本地化歌曲优先返回对应 Navidrome media ID 的音频和歌词地址，不再只靠标题+艺术家模糊匹配。
- `lyrics_report.csv` 中标记为 `SUSPECT`、`NO_MATCH` 或 `NO_LYRIC` 的歌词不会再显示为正常歌词；页面会提示“匹配度不足，已暂不显示”。
- `fetch_lyrics.ps1` 现在要求标题、时长和可靠艺术家信息同时足够匹配，低置信度结果不会写入 `.lrc`；筛选运行时会合并报告，不会覆盖其他歌曲的记录。
- 播放器新增上一首/下一首按钮；顺序模式支持循环切换，随机模式随机选择，播放超过 3 秒点击上一首会先重置当前歌曲。
- 完整 Pester 回归测试：12/12 通过；歌词报告已重建 164 条，其中 23 条低置信度匹配被保护性隐藏。

## 推荐本地匹配修复（2026-08-26）

- 修复 `Find-LocalTrack` 的误匹配：旧逻辑只要歌手出现在文件名中就可能判定为本地歌曲，导致 `Lucky / EXO-K` 错绑到 `EXO-K《mama》`，以及 `吹灭小山河 / 国风堂,司南` 错绑到 `国风堂&哦漏《知我》`。
- 现在必须先匹配标准化后的歌曲标题，歌手只用于提高候选排序分数；找不到标题匹配时保持 `REMOTE`，不会再把另一首本地歌曲当成当前推荐。
- 重启 API 后已验证今日前两首均返回 `REMOTE`，播放源为对应的网易云 preview，不再指向错误的 Navidrome 本地文件。
- 新增“同歌手、不同标题不得本地匹配”回归测试；完整 Pester 回归测试：14/14 通过。

## 单字歌名误匹配修复（2026-08-27）

- 继续修复同一类问题：`过 / 王嘉尔、林俊杰` 会因为标题只有一个字，被误判为文件名句子中包含“过”的另一首本地视频。
- 单字标题现在只接受标准化文件名等于歌名，或等于完整“歌名-歌手”；普通文本中偶然出现该字的文件不会再被本地化。
- 已重载 API 验证该推荐返回 `REMOTE`，播放源为对应网易云 preview；核心回归测试扩展为 12/12 通过。

## 同名不同艺术家误绑定修复（2026-08-27）

- 修复“只要标题相同就本地化”的剩余问题：`Follow Your Heart / 塞壬唱片-MSR、真名辺あや、TMKJ` 曾被绑定到 `《明日方舟》EP - Follow Your Heart.mp3`（本地标签艺术家为“明日方舟”）。
- 本地候选现在要求标准化后的完整艺术家信息也出现在文件名中；同名但艺术家不同的版本保持远程试听，不再显示“已本地化”。
- API 重载后该条已验证为 `REMOTE`，今日推荐当前只有艺术家信息也匹配的歌曲才显示 `LOCAL`。
- 新增同名不同艺术家回归测试；完整 Pester 回归测试：16/16 通过。

## 播放列表交互调整（2026-08-25）

- 随机播放改为固定的洗牌队列：只有点击“↻ 重新随机”才会重新排列；刷新页面或后台同步不会重新洗牌，切回顺序也不会隐式洗牌。
- 页面本身固定在视口内；左侧音乐库列表和右侧推荐歌曲列表分别滚动，顶部导航、统计和播放器保持固定。
