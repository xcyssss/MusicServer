# MusicServer

个人音乐服务器：B 站音频下载 + Navidrome 流媒体 + 每日自动推荐 + Tauri 桌面端。

## 架构

```
┌─ Tauri 桌面端 (WebView2) ─┐    ┌─ 音乐服务器 ──────────────┐
│                            │    │                            │
│  WebView → 127.0.0.1:8790  │───→│  start_musicserver_ui.ps1  │
│  (UI 代理层：歌词门控、     │    │    ├─ API (8787)           │
│   Range seek、心跳、库管理)  │    │    ├─ Worker (后台下载)    │
│                            │    │    └─ Watchdog (守护进程)   │
└────────────────────────────┘    └────────────────────────────┘
                                           │
                                    ┌──────┴──────┐
                                    │  Navidrome   │
                                    │  (4533)      │
                                    └─────────────┘
```

### 核心组件

| 组件 | 端口 | 职责 |
|------|------|------|
| `music_api.ps1` | 8787 | JSON API（推荐/库/下载/歌词/播放记录） |
| `start_musicserver_ui.ps1` | 8790 | UI 代理层 + WebView 静态文件服务 |
| `wanted_worker.ps1` | — | 后台下载 worker（点赞→下载→入库） |
| `watchdog_ui.ps1` | — | UI 进程守护（心跳检测，卡死自动重启） |
| Navidrome | 4533 | 音乐流媒体服务器（Subsonic 协议） |

## 快速开始

### 环境要求

- **Windows 10/11** + PowerShell 5.1（系统自带）
- **Navidrome** v0.63.2+（放在 `Navidrome/` 目录）
- **yt-dlp**（B 站下载器）
- **ffmpeg/ffprobe**（音频处理）
- **sqlite3**（数据库查询）

### 安装步骤

```powershell
cd E:\Project\MusicServer

# 1. 安装 yt-dlp（用 conda 或 pip）
pip install yt-dlp

# 2. 安装 sqlite3（可选，CI 用 choco install sqlite）
# 本地通常已有，Navidrome 内置了 SQLite

# 3. 下载 Navidrome
# 从 https://github.com/navidrome/navidrome/releases 下载 Windows 版
# 解压到 Navidrome/bin/navidrome.exe

# 4. 准备 B 站 cookies（用于下载）
# 浏览器登录 bilibili.com，导出 cookies.txt 放在项目根目录

# 5. 启动
.\start_musicserver_ui.ps1    # 启动 UI + API + Worker
# 或双击 start_musicserver_ui.bat
```

### 桌面端（Tauri）

```powershell
# 需要先安装 Rust
rustup install stable

# 构建
cd src-tauri
cargo tauri build

# 生成的 exe 在 target/release/musicserver-desktop.exe
```

## 日常使用

### 自动推荐（每日定时任务）

| 任务 | 时间 | 功能 |
|------|------|------|
| `MusicServer_DailyCleanup` | 06:30 | 清理未红心的推荐歌，更新黑名单 |
| `MusicServer_DailyRecommend` | 07:00 | 生成 30 首推荐，下载、抓歌词 |

### 手动操作

```powershell
# 下载单首歌
.\add_song.ps1    # 粘贴 BV 号

# 批量抓歌词
.\fetch_lyrics.ps1 -Force          # 重抓所有歌词
.\fetch_lyrics.ps1 -Filter "*Roselia*"  # 只抓特定歌

# 修复单首歌词
.\fix_one_lyric.ps1 -FilePattern "*若月亮还没来*" -Search "若月亮还没来"

# 查看音乐库状态
sqlite3 Navidrome\Data\navidrome.db "select count(*) from media_file;"
```

## 项目结构

```
MusicServer/
├── web/                          # Web UI（WebView2 / 桌面端）
│   ├── index.html                # 主页面
│   ├── app.js                    # 前端逻辑（播放、库、推荐、常听侧栏）
│   └── styles.css                # 样式（暗色主题、三栏布局）
├── src-tauri/                    # Tauri v2 桌面端
│   ├── src/main.rs               # Rust 后端（服务管理、窗口加载）
│   ├── tauri.conf.json           # Tauri 配置
│   └── Cargo.toml                # Rust 依赖
├── music_api.ps1                 # HTTP API 服务器（v2）
├── start_musicserver_ui.ps1      # UI 启动器（代理 + 文件服务 + Worker 管理）
├── wanted_worker.ps1             # 后台下载 worker
├── MusicServer.Core.psm1         # 核心工具函数
├── MusicServer.Database.psm1     # SQLite 数据库层
├── MusicServer.State.psm1        # 业务状态管理
├── MusicServer.Providers.psm1    # 下载渠道（网易云 + B站）
├── fetch_lyrics.ps1              # 歌词批量抓取（网易云）
├── daily_recommend.ps1           # 每日推荐管道
├── daily_cleanup.ps1             # 每日清理
├── Music/                        # 本地音乐库（.mp3 + .lrc）
│   └── DailyMix/                 # 每日推荐（自动清理）
├── Navidrome/                    # Navidrome 服务
│   ├── bin/navidrome.exe
│   ├── navidrome.toml            # 配置（端口 4533、音乐目录、ffmpeg 路径）
│   └── Data/navidrome.db         # 数据库
└── tests/                        # 测试套件
    └── MusicServer.*.Tests.ps1   # Pester 3.4（PS 5.1 兼容）
```

## 数据流

```
点赞歌曲 → wanted_queue → Worker 下载 → Music/ → Navidrome 扫描 → UI 显示
                                                              ↓
                                                        歌词匹配（fetch_lyrics）
```

## 测试

```powershell
Import-Module Pester -RequiredVersion 3.4.0 -Force
Invoke-Pester .\tests\MusicServer.Web.Tests.ps1 -PassThru
```

CI 在 `.github/workflows/core-tests.yml`，分为 `state` 和 `api` 两个并行 job。

## 关键技术点

- **PowerShell 5.1 UTF-8 BOM**：所有 `.ps1` 文件必须有 UTF-8 BOM，否则中文字符会被 ANSI 编码读取导致乱码
- **HTTP Range 支持**：音频流支持 Range 请求（206 Partial Content），浏览器 `<audio>` 元素才能 seek
- **Canonical 权威匹配**：歌词抓取优先使用数据库中已确认的网易云 song ID，避免同名不同歌的错配
- **UI 自动停机**：带 `-NoBrowser` 启动时不自动停机；不带时，无浏览器心跳 90 秒后自动关闭
