# MusicServer 中文使用说明

MusicServer 是一个 Windows 本地音乐应用，主客户端为 **Tauri v2 桌面 APP**。底层由本地 WebView2 UI、PowerShell API、SQLite 状态库以及 Navidrome / yt-dlp / ffmpeg 等组件组成。

本文档面向日常使用和常见维护操作。当前架构、构建与开发约束以根目录 `README.md` 和 `AGENTS.md` 为准。

## 目录结构

```text
E:\Project\MusicServer\
├── Music\                          # 本地音乐
├── DailyMix_data\                  # MusicServer 状态与兼容数据
├── Navidrome\                      # Navidrome 配置、程序和数据
├── scripts\maintenance\           # 独立维护工具
│   ├── download_bilibili_favorites.ps1
│   ├── fetch_lyrics.ps1
│   ├── fix_one_lyric.ps1
│   ├── fix_tags.ps1
│   └── add_song.ps1
├── daily_recommend.ps1             # 每日推荐 metadata 生成
├── daily_cleanup.ps1               # DailyMix 清理
├── wanted_worker.ps1               # Wanted Queue 下载 worker
├── music_api.ps1                   # 本地 API
├── start_musicserver_ui.ps1        # UI 服务 + API 代理
├── start_musicserver_ui.bat        # 源码环境便捷启动入口
├── web\                            # 桌面 APP WebView2 UI
└── src-tauri\                      # Tauri 桌面壳与打包
```

---

## 1. 启动 MusicServer

### 已安装桌面版

直接从 Windows 开始菜单或桌面快捷方式启动 MusicServer。

安装版默认把可写 runtime / 状态放在：

```text
%LOCALAPPDATA%\com.musicserver.desktop\
```

如果设置了环境变量 `MUSICSERVER_APP_HOME`，则以该目录为准。

### 从源码运行

在 PowerShell 中：

```powershell
cd E:\Project\MusicServer
.\start_musicserver_ui.ps1
```

也可以使用便捷 wrapper：

```powershell
.\start_musicserver_ui.bat
```

默认：

- UI：`http://127.0.0.1:8790`
- API：`http://127.0.0.1:8787`

Tauri APP 会加载同一套 `web/` UI；浏览器页面不是另一套独立产品。

---

## 2. Navidrome

Navidrome 用于扫描和提供本地音乐库。

典型位置：

```text
E:\Project\MusicServer\Navidrome\bin\navidrome.exe
E:\Project\MusicServer\Navidrome\navidrome.toml
E:\Project\MusicServer\Navidrome\Data\
```

手动启动：

```powershell
E:\Project\MusicServer\Navidrome\bin\navidrome.exe `
    -c E:\Project\MusicServer\Navidrome\navidrome.toml
```

默认 Web 地址：

```text
http://localhost:4533
```

首次进入时按 Navidrome 页面提示创建管理员账号，然后执行 `Scan Library Now` 扫描音乐库。

> 不要在 Navidrome 正在运行时直接修改它的 live SQLite 数据库。MusicServer 需要读取 Navidrome 状态时会使用安全的只读/副本方式。

### 局域网访问

Navidrome 如果绑定在 `0.0.0.0:4533`，同一局域网中的手机或平板可以访问：

```text
http://你的电脑IP:4533
```

查看本机 IPv4 地址：

```powershell
ipconfig | Select-String "IPv4"
```

如果无法连接，检查 Windows 防火墙是否允许 4533 端口。

---

## 3. B站 Cookie 与下载

Bilibili 下载功能通常需要有效的 `cookies.txt`。Cookie 属于本地敏感数据，不应提交到 Git。

建议放在：

```text
E:\Project\MusicServer\cookies.txt
```

如果下载出现登录失效、验证失败或无法解析等问题，优先重新从已登录 B站的浏览器导出 Cookie。

### 下载收藏夹

```powershell
cd E:\Project\MusicServer

.\scripts\maintenance\download_bilibili_favorites.ps1 `
    -FavoritesUrl "https://www.bilibili.com/medialist/detail/ml你的收藏夹编号" `
    -CookieFile "E:\Project\MusicServer\cookies.txt"
```

B站存在频率限制和 HTTP 412 风控。遇到风控时不要做无界重试；MusicServer 的正式 Provider / Wanted Queue 路径会按 provider health 和退避逻辑处理。

### 单曲维护工具

`add_song.ps1` 已移动到：

```powershell
.\scripts\maintenance\add_song.ps1
```

具体参数以脚本自身 `Get-Help` / 参数定义为准。

---

## 4. 歌词功能（外部 LRC）

MusicServer 使用与音频同名的外部 LRC 文件。例如：

```text
Song.mp3
Song.lrc
```

Navidrome 会读取同名 `.lrc` 并在播放时显示歌词。添加或修复 `.lrc` 后通常不需要重建 MusicServer 状态。

### 批量抓取歌词

歌词维护脚本使用网易云音乐作为歌词来源，并结合文件名、候选标题、艺术家、时长以及 MusicServer 中已有的 canonical metadata 做匹配。

```powershell
cd E:\Project\MusicServer

# 只预览，不写文件
.\scripts\maintenance\fetch_lyrics.ps1 -DryRun

# 处理缺少歌词的歌曲
.\scripts\maintenance\fetch_lyrics.ps1

# 只处理指定文件名
.\scripts\maintenance\fetch_lyrics.ps1 -Filter "*歌曲名*"

# 覆盖已有 .lrc
.\scripts\maintenance\fetch_lyrics.ps1 -Force
```

运行后会生成：

```text
E:\Project\MusicServer\lyrics_report.csv
```

常见 `Status`：

| Status | 含义 |
|---|---|
| `OK` | 匹配置信度足够高；非 DryRun 时可写入歌词 |
| `SUSPECT` | 匹配存在疑点，建议人工确认 |
| `NO_LYRIC` | 找到了候选歌曲，但没有可用的时间轴歌词 |
| `NO_MATCH` | 没有找到可靠候选 |

### 单曲歌词修复

先搜索候选：

```powershell
.\scripts\maintenance\fix_one_lyric.ps1 `
    -FilePattern "*歌曲名*" `
    -Search "歌曲名 艺术家"
```

确认网易云 Song ID 后写入：

```powershell
.\scripts\maintenance\fix_one_lyric.ps1 `
    -FilePattern "*歌曲名*" `
    -SongId 1234567890
```

---

## 5. 每日推荐

当前 `daily_recommend.ps1` 的职责是：

> **生成推荐 metadata，并写入 SQLite；不直接下载音频。**

推荐状态以 SQLite 为唯一运行时真源。脚本会综合 MusicServer 中的推荐反馈、已有本地歌曲和 Navidrome 星标等信息生成候选，同时使用近期推荐冷却避免重复推荐。

默认目标数量为 20 首。

### 预览推荐

```powershell
cd E:\Project\MusicServer
.\daily_recommend.ps1 -DryRun
```

DryRun 只读取已有 SQLite 状态并打印结果，不写 recommendation state，也不会触发 legacy migration。

### 正式生成推荐

```powershell
.\daily_recommend.ps1
```

指定数量：

```powershell
.\daily_recommend.ps1 -Count 10
```

生成结果会写入 SQLite 中的 CanonicalTrack / DailyRecommendation 等正式状态，由桌面 UI/API 展示。真正需要下载的歌曲通过 Wanted Queue / worker 路径处理，而不是由 `daily_recommend.ps1` 直接下载。

### Legacy migration

旧 JSON/CSV → SQLite 迁移已经是兼容功能，默认不会自动执行。只有确实需要导入旧数据时才显式运行：

```powershell
.\daily_recommend.ps1 -MigrateLegacy
```

正常日常运行不要加这个参数。

---

## 6. DailyMix 清理

`daily_cleanup.ps1` 用于处理已经存在于 `Music\DailyMix\` 中的日推音频：

- Navidrome 中已点 ♥ 的歌曲：移入主音乐库，并记录为正向反馈；
- 未点 ♥ 的旧日推歌曲：删除并记录为负向反馈；
- 默认保留当天歌曲，给用户留出试听时间；
- 会同步重建相关播放列表。

先用 DryRun 查看计划：

```powershell
.\daily_cleanup.ps1 -DryRun
```

确认无误后再执行：

```powershell
.\daily_cleanup.ps1
```

> `daily_cleanup.ps1` 会移动或删除真实音乐文件。不要跳过 DryRun 检查，也不要在不确定 DailyMix 内容时直接执行。

`accepted.csv` / `rejected.csv` 仍可能作为兼容输出存在，但推荐决策的正式状态在 SQLite 中。

---

## 7. Wanted Queue

需要把远程推荐真正变成本地歌曲时，下载任务进入 Wanted Queue，由：

```text
wanted_worker.ps1
```

异步处理。

Worker 会优先检查本地候选，再解析 provider 候选；需要 Bilibili 下载时会使用 provider health、lease、CAS 和有界重试机制，避免重复 worker、重复下载或无限重试。

手工只执行一轮：

```powershell
.\wanted_worker.ps1 -Once
```

DryRun 查看待处理项目：

```powershell
.\wanted_worker.ps1 -Once -DryRun
```

Windows Scheduled Task 的注册入口为：

```powershell
.\register_wanted_worker.ps1
```

---

## 8. 常用维护命令

```powershell
# 推荐
.\daily_recommend.ps1 -DryRun
.\daily_recommend.ps1

# DailyMix 清理
.\daily_cleanup.ps1 -DryRun

# 歌词
.\scripts\maintenance\fetch_lyrics.ps1 -DryRun
.\scripts\maintenance\fetch_lyrics.ps1 -Force

# 单曲歌词
.\scripts\maintenance\fix_one_lyric.ps1 -FilePattern "*歌曲名*" -Search "歌曲名"

# Wanted Queue
.\wanted_worker.ps1 -Once -DryRun
```

---

## 9. 常见问题

### 下载突然大量失败或出现 412

B站风控通常是服务端限制。停止高频重试，等待 provider block / cooldown 结束后再继续。不要为了追求成功率加入无限循环。

### Cookie 失效

重新从已登录 B站的浏览器导出 `cookies.txt`，覆盖本地文件即可。不要把 Cookie 提交到 Git。

### Navidrome 看不到新歌曲

先确认音乐文件已经进入 Navidrome 配置的音乐目录，然后在 Navidrome 中执行 `Scan Library Now`。

### 歌词时间轴明显不对

先运行：

```powershell
.\scripts\maintenance\fetch_lyrics.ps1 -DryRun -Filter "*歌曲名*"
```

如果结果是 `SUSPECT`，使用 `fix_one_lyric.ps1` 手动指定正确的网易云 Song ID。

### 源码目录和安装版数据在哪

源码 checkout 默认使用项目目录中的本地数据。正式安装版默认使用：

```text
%LOCALAPPDATA%\com.musicserver.desktop\
```

也可以通过 `MUSICSERVER_APP_HOME` 覆盖。

---

## 10. 数据安全

以下内容都属于本地数据或敏感内容，不要随意删除，也不要提交 Git：

```text
Music\
DailyMix_data\
Navidrome\Data\
cookies.txt
*.db
logs\
backups\
```

SQLite 是 MusicServer 唯一运行时状态真源。JSON/CSV 只用于 migration、backup 或兼容输出。

如果只是开发代码，不要为了“清理仓库”删除音乐、数据库、Cookie 或用户历史状态。
