# MusicServer - Agent Guide

MusicServer is a Windows-first local music application. The **Tauri v2 desktop APP is the product target**; `web/` is the shared WebView2 UI rendered inside that APP.

## Non-negotiable architecture rules

- **SQLite is the sole runtime source of truth.** JSON files are migration input, backup, or compatibility output only.
- **Do not build a second native Rust UI.** `web/index.html`, `web/app.js`, and `web/styles.css` are the desktop UI.
- **Validate user-facing UI changes in the Tauri APP**, not only in a browser.
- **Windows PowerShell 5.1 is the compatibility baseline** for formal PowerShell code and tests.
- `.ps1` / `.psm1` containing non-ASCII text must be UTF-8 BOM. `.editorconfig` enforces this.
- Never directly edit the live Navidrome DB while Navidrome is running.
- Generated runtime/build output, local music, cookies, databases, logs, and diagnostic `artifacts/` must not be committed.

## Core stack

- `MusicServer.Core.psm1` — configuration/common helpers
- `MusicServer.Database.psm1` — SQLite access
- `MusicServer.Http.psm1` — bounded UTF-8 JSON control-request reader shared by API and UI proxy
- `MusicServer.State.psm1` — canonical transactional state/schema
- `MusicServer.Providers.psm1` — local/Bilibili provider resolution and health
- `MusicServer.Migration.psm1` — explicit legacy migration only
- `MusicServer.DesiredStateWorker.psm1` — desired-state worker helpers
- `music_api.ps1` — JSON HTTP API, normally `127.0.0.1:8787`
- `start_musicserver_ui.ps1` — static WebView UI + `/api/*` proxy, normally `127.0.0.1:8790`
- `watchdog_ui.ps1` — external UI heartbeat watchdog/restart helper
- `wanted_worker.ps1` — asynchronous Wanted Queue downloader
- `web/` — shared desktop WebView2 UI
- `src-tauri/` — Tauri desktop shell, runtime deployment, lifecycle and packaging
- Navidrome — local music server/integration
- yt-dlp + ffmpeg/ffprobe — optional download/transcode integrations

External executable resolution should prefer environment overrides / PATH rather than new machine-specific absolute paths:

```text
MUSICSERVER_SQLITE
MUSICSERVER_YTDLP
MUSICSERVER_FFMPEG
MUSICSERVER_FFPROBE
MUSICSERVER_APP_HOME
```

## Desktop runtime and release model

A release must work independently of the source checkout.

Build flow:

```text
clean checkout
  -> scripts/prepare_tauri_runtime.ps1
  -> src-tauri/resources/runtime/ (generated)
  -> cargo/Tauri NSIS build
  -> installed APP
  -> packaged runtime copied to writable APP home
  -> PowerShell UI/API/worker/watchdog started from APP home
```

The packaged runtime contains only what the desktop APP needs to boot its own UI/API state layer:

- `start_musicserver_ui.ps1`
- `watchdog_ui.ps1`
- `music_api.ps1`
- `wanted_worker.ps1`
- Core/Database/Http/State/Providers modules
- `web/`
- a real `sqlite3.exe`

Do **not** package `cookies.txt`, local databases, music, logs, generated reports, yt-dlp credentials, or user-specific paths.

Installed builds default to:

```text
%LOCALAPPDATA%\com.musicserver.desktop\
```

for the writable runtime/data home. `MUSICSERVER_APP_HOME` can override it.

A release EXE built and launched from inside a source checkout may detect that checkout from its own executable ancestry and continue using the existing checkout data. This runtime discovery is allowed because it embeds no compile-time absolute path. **Do not reintroduce `CARGO_MANIFEST_DIR` as runtime state/location.**

## Repository layout

```text
MusicServer/
├─ .github/workflows/             # CI
├─ docs/                          # current docs + archived historical reports
├─ scripts/                       # build/maintenance helpers
├─ src-tauri/
│  ├─ src/main.rs
│  ├─ resources/runtime/          # generated, ignored except placeholder
│  ├─ icons/                      # Windows release assets only
│  ├─ Cargo.toml / Cargo.lock
│  └─ tauri.conf.json
├─ web/
├─ tests/
├─ MusicServer.*.psm1
├─ music_api.ps1
├─ start_musicserver_ui.ps1
├─ watchdog_ui.ps1
└─ wanted_worker.ps1
```

Historical architecture/hardening reports belong in `docs/archive/`, not in the repository root. Personal Windows file-association helpers do not belong in this product repository.

## Formal tests and CI

Formal suites are `tests/MusicServer.*.Tests.ps1`, Pester 3.4, PS5.1-compatible. Tests that depend on a real local library/API/lyrics report must use the `RequiresLocalRuntime` tag so CI can exclude them.

CI: `.github/workflows/core-tests.yml` on `windows-latest`.

| Job | Responsibility |
|---|---|
| `state` | Core, Database, V2, WorkerConcurrency, Recommendation, LegacyRetirement, Listening, Web, Tauri |
| `api` | Http, UiProxyRuntime, ApiTransaction, ApiRuntime |
| `desktop-build` | real Rust/Tauri compile, NSIS installer, installed-app portability smoke, installer artifact |

The desktop gate must include at least:

```text
cargo fmt --check
cargo check --locked
Tauri NSIS build
installer exists
silent temporary install
source runtime disabled during launch
installed UI/API build markers reachable
bundled sqlite/runtime staged
APP-owned services stop after APP exits
installer artifact upload
```

Do not replace this with a static grep/Pester-only check.

## Runtime behavior rules

- Default UI/API ports: 8790 / 8787.
- Fallback pairs exist for stale/foreign listeners; do not compete with unidentified port owners.
- Tauri verifies the UI `app.js` and API `/health` build marker before reusing a service pair.
- APP shutdown must stop only the launcher/service tree that this APP owns.
- Wanted worker uses its mutex/SQLite lease logic; do not introduce duplicate workers or bypass lease ownership.
- `bilibili_direct` candidates must not trigger an unnecessary Bilibili search. Search is fallback when no usable local/direct candidate exists.
- Bilibili 412/rate-limit handling must remain bounded and health-aware; do not add unbounded retry loops.
- SQLite CLI calls enable foreign keys before caller SQL and stop on the first error; connection-local settings must be applied per invocation. Keep the existing effective synchronous default unless a separate durability change is reviewed.
- API/proxied JSON control bodies are limited to 64 KiB and a 5-second total read deadline. Empty bodies remain supported; nonempty bodies must be UTF-8 JSON objects. Reject unsupported chunked/compressed bodies before state writes or forwarding.

## Common local operations

```powershell
# Formal examples
Import-Module Pester -RequiredVersion 3.4.0 -Force
Invoke-Pester .\tests\MusicServer.Core.Tests.ps1 -PassThru

# Desktop release
cd src-tauri
cargo fmt --check
cargo check --locked
npx --yes @tauri-apps/cli@2 build --bundles nsis
```

For live desktop smoke, use `tests/verify_tauri_desktop.ps1` and exercise the actual Tauri APP.

## Change workflow

For non-trivial work:

1. inspect current branch/files before modifying;
2. preserve unrelated local/user work;
3. make the smallest coherent change;
4. add/update regression coverage;
5. run the relevant local tests when possible;
6. push to a feature/review branch;
7. verify GitHub CI rather than assuming it is green;
8. do not merge unless the user explicitly authorizes merge.

### Checkpoint rule

After completing a meaningful task, update this `AGENTS.md` checkpoint when the task changes architecture, release behavior, test gates, or important operating rules. Keep only current durable facts; do not accumulate transient debugging notes.

## Current checkpoint — 2026-09-05

- P0 closed: `music_api.ps1` is PS5.1/BOM-safe and provider direct-candidate fallback no longer leaks into unwanted Bilibili search.
- P1-A closed: CI has a real `desktop-build` gate on a clean Windows runner.
- P1-B closed: release runtime is bundled, SQLite and the UI watchdog are included, `CARGO_MANIFEST_DIR` runtime dependency is removed, installed runtime uses a writable APP home, and local checkout builds preserve existing checkout data via runtime path discovery.
- `desktop-build` produces an NSIS setup executable and uploads `musicserver-windows-installer`.
- CI performs an installed-app portability smoke with the checkout runtime disabled; it verifies packaged runtime staging, current UI/API markers, SQLite state creation and owned-service shutdown.
- GitHub Actions run #74 passed `state`, `api`, and `desktop-build`, including the source-independent installed-APP smoke and installer artifact upload.
- P2 closed: historical reports moved to `docs/archive/`, Chinese user guide moved to `docs/`, committed validation logs removed, personal Markdown-association scripts removed, `.editorconfig` added, and Tauri icons reduced to Windows release/source assets.
- The local main baseline includes PR #10's merge commit `a63cfef`. Subsequent optimization work uses new feature/review branches; merging any new PR still requires explicit user authorization.
- The HTTP input module is packaged with the desktop runtime and covered by real PS5.1 API/proxy socket tests in the `api` CI group.
- `scripts/measure_musicserver_backend.ps1` measures isolated service readiness, endpoint latency and state SQLite process counts with synthetic metadata. It omits the downloader, writes only under `artifacts/`, and does not substitute for Tauri rendering/playback validation.
