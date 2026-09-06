# MusicServer

个人音乐服务器：本地音乐库 + 每日推荐 + Wanted 下载队列 + 歌词 + 播放统计，主客户端为 **Tauri v2 Windows 桌面 APP**。

## 当前架构

```text
Tauri APP / WebView2
        │
        ▼
127.0.0.1:8790  start_musicserver_ui.ps1
        │  静态 UI + /api/* 代理 + watchdog
        ▼
127.0.0.1:8787  music_api.ps1
        │
        ├─ SQLite 状态库（唯一运行时真源）
        ├─ Music/ 本地音乐
        ├─ Wanted worker
        └─ Navidrome / yt-dlp / ffmpeg 等本机集成
```

`web/` 是 Tauri WebView2 加载的共享 UI，不是另一套独立产品。桌面端代码位于 `src-tauri/`。

## Windows 桌面版

### 从源码构建

需要 Rust stable、Node/npm 与 Windows WebView2 构建环境：

```powershell
cd src-tauri
cargo fmt --check
cargo check --locked
npx --yes @tauri-apps/cli@2 build --bundles nsis
```

构建前 `scripts/prepare_tauri_runtime.ps1` 会自动生成 `src-tauri/resources/runtime/`，收集桌面 APP 真正需要的 PowerShell runtime（UI/API/worker/watchdog）、`web/` 和 `sqlite3.exe`。生成目录和 Rust `target/` 均不提交到 Git。

NSIS 安装包位于：

```text
src-tauri/target/release/bundle/nsis/*.exe
```

### 可移植运行时

发布版 **不再依赖 `CARGO_MANIFEST_DIR` 或编译机源码路径**。安装后的 APP 从 bundle resources 读取 runtime，并同步到可写目录：

```text
%LOCALAPPDATA%\com.musicserver.desktop\
```

可通过环境变量 `MUSICSERVER_APP_HOME` 覆盖该位置。为了不破坏现有开发机数据，从源码目录本地构建并直接运行的 EXE 会在运行时识别 checkout，并继续使用该 checkout 下已有的 `Music/`、`DailyMix_data/`、`Navidrome/` 等数据；这里不包含任何编译时绝对路径。

安装包内包含 SQLite，因此 UI/API 和状态库启动不要求用户另装 sqlite3。Bilibili 下载、转码和 Navidrome 集成仍分别需要 yt-dlp、ffmpeg/ffprobe、Navidrome；这些大型/外部组件不塞进桌面 runtime。

## 开发环境

项目仍以 Windows PowerShell 5.1 为正式脚本兼容基线。常用外部工具可从 PATH 找到，也可用环境变量覆盖：

```text
MUSICSERVER_SQLITE
MUSICSERVER_YTDLP
MUSICSERVER_FFMPEG
MUSICSERVER_FFPROBE
MUSICSERVER_APP_HOME
```

含中文的 `.ps1` / `.psm1` 必须保持 UTF-8 BOM；仓库 `.editorconfig` 已固定这一规则。

## 核心目录

```text
MusicServer/
├─ .github/workflows/             # CI
├─ docs/                          # 当前说明 + 历史审计归档
├─ scripts/                       # 构建/维护脚本
├─ src-tauri/                     # Tauri v2 Windows shell
│  ├─ src/main.rs                 # runtime 部署、服务生命周期、窗口导航
│  ├─ resources/runtime/          # 构建生成；Git 仅保留占位文件
│  ├─ icons/                      # Windows 构建所需图标
│  ├─ Cargo.toml / Cargo.lock
│  └─ tauri.conf.json
├─ web/                           # WebView2 UI
├─ tests/                         # Pester + 桌面 smoke
├─ MusicServer.Core.psm1
├─ MusicServer.Database.psm1
├─ MusicServer.Http.psm1
├─ MusicServer.State.psm1
├─ MusicServer.Providers.psm1
├─ music_api.ps1
├─ start_musicserver_ui.ps1
├─ watchdog_ui.ps1
└─ wanted_worker.ps1
```

历史架构审计和加固报告已移到 [`docs/archive/`](docs/archive/)。中文详细使用说明见 [`docs/USER_GUIDE.zh-CN.md`](docs/USER_GUIDE.zh-CN.md)。

## 启动与日常操作

源码 checkout 中可直接：

```powershell
.\start_musicserver_ui.ps1
```

常用维护：

```powershell
# 推荐
.\daily_recommend.ps1 -DryRun
.\daily_recommend.ps1

# 清理
.\daily_cleanup.ps1 -DryRun

# 歌词
.\scripts\maintenance\fetch_lyrics.ps1 -DryRun
.\scripts\maintenance\fetch_lyrics.ps1 -Force

# 单曲歌词修复
.\scripts\maintenance\fix_one_lyric.ps1 -FilePattern "*歌曲名*" -Search "歌曲名"
```

## CI 与发布门禁

`.github/workflows/core-tests.yml` 在 `windows-latest` 上运行三个独立 gate：

| Job | 验证内容 |
|---|---|
| `state` | Core / Database / V2 / WorkerConcurrency / Recommendation / LegacyRetirement / Listening / Web / Tauri Pester |
| `api` | Http / UiProxyRuntime / ApiTransaction / ApiRuntime Pester |
| `desktop-build` | `cargo fmt --check`、`cargo check --locked`、真实 NSIS 构建、安装包脱离源码 runtime 启动 smoke、artifact 上传 |

`desktop-build` 不只检查源码字符串：它会在干净 GitHub runner 上真正生成安装 EXE，然后静默安装到临时目录，临时禁用 checkout 中的 launcher/API/web，再启动已安装 APP。只有 bundle runtime 能自行部署、UI/API build marker 正常、SQLite 状态库建立且 APP 退出后所拥有的服务树全部停止，才算通过。

成功构建会上传名为：

```text
musicserver-windows-installer
```

的 GitHub Actions artifact。

## 运行规则

- SQLite 是 MusicServer 唯一运行时状态真源；JSON 仅用于迁移输入、备份或兼容输出。
- 不要在 Navidrome 运行时直接写其 live DB。
- `artifacts/`、日志、音乐、cookies、本机数据库和生成的 Tauri runtime 都不应提交。
- `web/` 的 UI 改动必须以 Tauri APP 实际行为作为最终验收，不以浏览器单独可用作为桌面验收。
- 下载侧遇到 Bilibili 风控时遵守 Provider health/circuit-breaker 逻辑，不做无界重试。

## 性能基线与请求契约

优化进度见 [`docs/OPTIMIZATION_PLAN.zh-CN.md`](docs/OPTIMIZATION_PLAN.zh-CN.md)。可用 Windows PowerShell 5.1 运行隔离后端基线：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/measure_musicserver_backend.ps1
```

默认测量空库、1,000 和 10,000 条合成元数据，每个端点 30 个后续请求样本、5 次服务启动。测试元数据共用一段静音 WAV，不启动下载 worker；临时服务退出后清理测试库，JSON 报告和 CSV 样本保存在 `artifacts/performance/`。这衡量的是服务与元数据路径；Tauri 窗口、搜索渲染和不同真实音频文件的扫描成本需另行测量。

`MUSICSERVER_DIAGNOSTICS=1` 可让 API JSON 响应携带 `X-MusicServer-State-Sqlite-Calls`，表示该请求经状态库包装器启动的 sqlite3 进程数；它不包括 Navidrome 只读查询，默认关闭。

API 与 UI 代理的 JSON 控制请求最多 64 KiB，完整请求体须在 5 秒内到达。空请求体继续兼容；非空请求体必须是 UTF-8 JSON 对象。非法/不完整 JSON 返回 400，超时返回 408，chunked 请求返回 411，超限返回 413，不支持的压缩编码返回 415；连接已断开时可能无法返回错误正文。
