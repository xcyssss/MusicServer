# MusicServer — project guidance

MusicServer is a Windows music desktop application. The product is the Tauri v2 APP; `web/` is its shared WebView2 UI. Complete requested work through implementation, relevant checks and a reviewable result. Routine edits, disposable tests and fixes within the request can proceed without another approval.

## Product and data boundaries

- Keep library, discovery and the persistent player on one page. Details open within that workspace. The default view is `web/music-tree.html`; `web/index.html` is the classic view. Both use `web/app.js`. Do not build a second native UI.
- SQLite is the sole runtime source of truth. JSON is migration input, backup or compatibility output. Likes and wanted downloads must remain transactional and recoverable.
- Persistent state is independent of the checkout: `MUSICSERVER_APP_HOME` → registry pin `HKCU\Software\MusicServerRuntime\AppHome` → `%LOCALAPPDATA%\com.musicserver.desktop`. Never infer it from executable ancestry or `CARGO_MANIFEST_DIR`.
- Music location is independently resolved: `MUSICSERVER_MUSIC_DIR` → SQLite `app_settings.music_library_path` → `<APP_HOME>\Music`. Every service uses the same `Config.MusicDir`; `DailyDir` is its `DailyMix` child. A missing custom folder is unavailable, not permission to fall back or create another library. Changing settings never moves, copies or deletes music.
- Never edit a running Navidrome database. Do not commit music, cookies, databases, logs, diagnostics, generated runtime or build output.
- PowerShell 5.1 and Pester 3.4 are the compatibility baseline. Non-ASCII `.ps1`/`.psm1` files require UTF-8 BOM.

## Find the relevant code

| Work | Starting points |
| --- | --- |
| UI, tree, playback, search | `web/app.js`, `music-tree-ui.js`, `music-tree.css`, `pond-water.js` |
| State and schema | `MusicServer.Database.psm1`, `MusicServer.State.psm1` |
| Providers, identity, downloads | `MusicServer.Providers.psm1`, `MusicServer.Core.psm1`, `wanted_worker.ps1` |
| Online search | `MusicServer.Search.psm1`, `POST /api/search`, `GET /api/search/{id}` |
| HTTP and media | `MusicServer.Http.psm1`, `music_api.ps1`, `start_musicserver_ui.ps1` |
| First use, lyrics, care | `MusicServer.Onboarding.psm1`, `MusicServer.Management.psm1`, `manage_musicserver.ps1` |
| APP lifecycle, distribution | `src-tauri/src/main.rs`, `scripts/prepare_tauri_runtime.ps1`, `.github/workflows/core-tests.yml` |

Modules stay at the root because imports use `$PSScriptRoot`. Executable resolution uses existing environment overrides, verified managed components and PATH; do not add machine-specific paths.

Consult [engineering contracts](docs/engineering-contracts.md) when changing the corresponding subsystem. For user behavior see [getting started](docs/getting-started.zh-CN.md); for download failures see [download reliability](docs/download-reliability.md); for release evidence and limits see [1.0 readiness](docs/1.0-readiness.zh-CN.md). These are task-specific references, not a required reading stack.

## Verification proportional to the change

Use disposable fixtures with no production state, then fix failures caused by the requested change and rerun the affected checks. UI changes must also be exercised in the **actual Tauri APP**, including normal automatic startup, relevant interactions and small-window layout. Manually starting services or navigating the WebView to a test URL does not validate startup. Browser-only screenshots are supplementary.

| Changed surface | Relevant checks |
| --- | --- |
| Shared UI | `node --test tests/web-ui.behavior.test.cjs tests/music-tree.behavior.test.cjs tests/onboarding.behavior.test.cjs`, Web Pester, actual APP |
| A PowerShell module | Its owning suite and directly affected neighbors |
| State/schema | Database, V2, owning business suite |
| API | Http, ApiRuntime, relevant runtime suite |
| UI proxy/media | UiProxyRuntime, MediaRuntime |
| Ranking | Recommendation and directly affected dependencies |
| Search | Search, SearchRuntime, shared UI behavior |
| Rust, staging, installer, lifecycle | Full desktop gate below |

Run a single suite through the bounded runner:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run_suite.ps1 -SuiteFile tests/MusicServer.Search.Tests.ps1 -LogFile artifacts/search.log
```

When both CI groups are affected, run targeted subsets side by side:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run_groups.ps1 -StateSuites Search,Web -ApiSuites SearchRuntime,Http -LogDir artifacts/targeted
```

- Ordinary work uses targeted checks. Full regression is reserved for explicit release/final/full validation. Never serialize every suite locally; use `run_groups.ps1` for parallel state/api groups, sequential suites within each group.
- One suite has a 300-second bound; a group/background test has at most 900 seconds. Investigate a timeout instead of extending it or blindly repeating it. A missing suite result is a runner error, not a pass.
- Keep progress observable. Do not pipe long runs into `Select-Object -Last`. Child processes, ports and temporary APPs must be cleaned on success, failure and timeout. Local-runtime-dependent tests carry `RequiresLocalRuntime`.

The desktop gate consists of `cargo fmt --check`, `cargo check --locked`, `cargo test --locked`, a Tauri NSIS build, installer existence, silent temporary installation, launch with source runtime disabled and all fixed ports occupied, current UI/API markers plus matching APP-home scope and bundled SQLite, normal APP exit with owned services stopped, and installer artifact upload. Read the selected ports from `logs/desktop-startup.json` and verify its process ID and live endpoints. CI's `desktop-build` implements this gate; static source checks do not replace it. Do not run a silent installer in a user session with an active MusicServer: NSIS terminates matching processes by name. Use a clean runner for that check.

## Runtime and delivery

- Default UI/API ports are 8790/8787. Reuse only a pair with current UI and API build markers. Respect foreign listeners and existing fallback pairs. Stop only the service tree owned by the APP; validate normal close, including during setup.
- Downloader mutex/SQLite leases remain authoritative. Try usable local/direct sources first; search is bounded fallback. Provider probes have expiring SQLite claims and release them on every completed outcome; distinguish an active probe or recovery cooldown from a real HTTP 412/429. Rate limits stop provider requests and never cause unbounded retries. `UNAVAILABLE` remains terminal until an explicit retry.
- New runtime modules/assets must appear in staging, build identity, Rust manifest/watch lists, static routes where needed, and runtime fixtures. A release must boot without the checkout and contain no user data or credentials.
- Runtime logging uses `Write-MusicServerLog` under `APP_HOME\logs` (4 MB with `.1`/`.2`). Log actionable transitions and sanitized failures; avoid per-poll noise. Discarded service stdout makes `Write-Host` insufficient.
- Preserve unrelated work. Group coherent changes into local commits, push once to a `codex/` review branch after relevant local checks, then inspect CI once with `gh pr checks <PR>`. Report pending checks; never use `--watch`. Merge only with explicit user authorization.
- Deliver the result, validation evidence and material limitations. For requested APP builds, provide the installer and distinguish local validation from still-pending CI. Signing uses `scripts/signing/Sign-MusicServerArtifact.ps1`; self-signed trust is machine-dependent.

## Maintaining this guide

Keep this file a short set of project boundaries and routing hints. Put subsystem contracts in the linked reference, proof in tests, and historical outcomes in release notes or git history. Replace stale facts rather than appending incident diaries, repeated warnings or generic agent recipes. Define completion and permission boundaries concretely; do not weaken data protection or silently broaden task scope.

This organization follows [OpenAI's guidance on skills and AGENTS.md](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra): concise relevant instructions, supporting material loaded when needed, and explicit completion criteria.
