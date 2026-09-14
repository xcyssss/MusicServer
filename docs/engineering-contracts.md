# Engineering contracts

Read the relevant section when changing that subsystem. Code and regression suites hold implementation details; this page records decisions that are easy to accidentally reverse.

## SQLite and PowerShell

- Use `ConvertFrom-MusicServerJsonArray` for SQLite JSON arrays. Bare PS5.1 `ConvertFrom-Json -InputObject` can add a wrapper array; scalar member enumeration hides that error. Do not compensate with local flattening guesses.
- Every SQLite CLI invocation uses batch mode, foreign keys and `.bail on`. The SQL splitter separates unquoted terminators while preserving literals, comments and trigger bodies. Preserve the existing synchronous durability setting.
- Adding a column needs an idempotent `PRAGMA table_info` / `ALTER TABLE` upgrade; `CREATE TABLE IF NOT EXISTS` only covers new tables. Expand `Get-NowIso` before passing timestamps to SQL templates.
- Bounded test children set UTF-8 console encoding. Use a retained process handle to read a real exit code; null exit codes and missing suite results are errors. Timeout cleanup kills the test's entire process tree.
- `MusicServer.Migration.psm1` is deprecated compatibility code. Legacy migration is explicit; JSON/CSV compatibility outputs never become runtime input again.

## HTTP, media and startup

- Shared control-body parsing in `MusicServer.Http.psm1` accepts empty bodies or UTF-8 JSON objects, caps at 64 KiB and a 5-second total deadline, and rejects unsupported chunking/compression before writes or forwarding.
- Slow media/provider work runs outside the control listener. Isolated media runspaces need Database parsing helpers, SQLite binding and `Get-LibraryFolderArtist`; cold Range requests must work before the owner library cache is warmed.
- Library availability uses the configured path and actual file existence, not Navidrome's stale `missing` flag. Installed builds do not install or run Navidrome.
- Rust passes the resolved APP_HOME to the launcher, which exports the same value for all children. The registry pin survives uninstall; tests use an isolated `MUSICSERVER_APP_HOME_PIN_KEY`. WebView2's separate cache directory is not runtime state.
- A missing daily mix self-heals even when scheduled-task registration fails. Task identity includes APP_HOME. Direct generation uses its existing bounded lease so restarts do not duplicate work.
- The API preflight probe is 400 ms; owned-child readiness uses a monotonic 27-second budget with bounded probes and early child-exit detection. Optional startup traces measure script phases, not rendered UI readiness, and never overwrite existing reports.
- Reclaim owned services on both main-window destruction and `RunEvent::Exit`; forced tree termination is test cleanup, not proof of normal shutdown. Minimize retains the taskbar and tray; tray click restores/unminimizes/focuses.

## Identity, library presentation and lyrics

- `raw` is the default display mode; `canonical` is opt-in Beta stored in SQLite. Preserve raw title/artist/album alongside resolved fields. `formatTrackDisplay` owns display decisions across views. Changing mode only re-renders; search indexes both vocabularies. An unreadable setting preserves raw mode.
- Bilibili uploader metadata is not singer evidence. NetEase artist matching requires the file name to vouch for every credited artist; duration is only a tie-breaker. `Resolve-DisplayArtist` is shared by UI/API overlays. Cached NetEase matches are reused; title-derived guesses are recomputed so improved parsing heals old rows.
- `local_track_artists` caches both successful and negative outcomes. Backfill is bounded and disableable. Runtime test children disable network artist backfill. Flat library roots are not artist folders.
- `Get-TitleDeclaredArtist`, shared prefix detection and `cleanSongName` distinguish series/marketing labels from credits. Strip branding only at boundaries. A quoted title keeps meaningful punctuation (`青玉案·元夕`); collaboration separators identify a credit list, not a song. Only remove the row's own singer from a title.
- Release year is NetEase `album.publishTime`, never an upload/encode year from local tags. Unknown/implausible values are 0 and hidden. Re-saving without a year must not erase a known year; older unresolved cache rows can be backfilled.
- Local lyrics prefer adjacent `Song.lrc`, then `Lyrics/Song.lrc` or `歌词/Song.lrc` in the same directory. Automatic lyrics are SQLite-cached by path/fingerprint, using a 60-second owner lease and bounded cooldowns. Missing identity is not permission to guess; READY works offline. Lyrics never delay audio/control requests.

## Recommendations, search and downloads

- Daily recommendations are remote discovery by default (`LocalCount=0`). Optional local rediscovery is preference-led, carries a playable library ID, diversifies artists and respects the listening cooldown. It must not dump an untouched library into recommendations.
- Dislike is a soft graded penalty, never an exclusion or file/download deletion. The latest like/dislike event wins by `(created_at, id)`; only the strongest TRACK/ARTIST/ALBUM/SIMILAR/SEED relation applies. Normalize both sides of exclusion keys and apply penalties before selection. Bounded similarity lookup respects the NetEase circuit.
- First-use starter tracks are metadata-only, inserted only if the day is still empty inside the transaction. They never overwrite personalized recommendations or mark personalized generation complete. Existing preferences/history remain authoritative.
- Online discovery uses SQLite `online_searches` / `online_search_results`, at most two background requests, 20-second deadlines and a ten-minute cache keyed by query **and source**. New sources use explicit adapters; same title/artist cannot collapse distinct provider recordings. Search itself does not like, enqueue, or modify the daily mix.
- Bilibili discovery reads one bounded metadata request through the shared search circuit, without download components. Preserve the exact BV identity and direct download candidate; display the uploader as UP attribution. Video preview uses Bilibili's official player; downloaded audio uses the shared local player. No guessed singer or expiring remote media URL is stored as canonical identity. The anonymous session initialization follows [yt-dlp's BiliBiliSearchIE](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/bilibili.py); 412/429 stop further requests through the circuit.
- Like uses the existing atomic preference/wanted transaction. Worker mutex and SQLite leases prevent duplicate ownership. Missing components preserve WANTED without spending attempts. Known sources precede one explicit search fallback; attempted URLs are not retried twice in a pass. Provider health is checked per source, so Bilibili failure does not discard NetEase.
- A HALF_OPEN probe is an atomic SQLite claim with a 15-minute default lease, longer than the bounded provider request. Reclaim abandoned claims once; completed failures release the claim and reopen a finite cooldown. HTTP 412/429 use the existing exponential cooldown. Search reports active probes, recovery cooldowns and actual rate limits separately, including the retry time when available. A process crash must not permanently disable discovery.
- Identity gates and full decoding precede publication; duration cannot substitute for singer evidence. Direct sources retain their explicit identity. NetEase discovery fallback is one circuit-charged lookup, disableable by `MUSICSERVER_DISABLE_NETEASE_SEARCH=1`; terminal UNAVAILABLE never automatically retries.
- Downloads stage under APP_HOME outside the scanned music tree. Cross-volume publication copies to an unindexed `.part` then renames; existing music/lyrics get a unique new filename, not an overwrite. LOCAL and the stable playable path identity commit together. Optional Navidrome lookup cannot blank that identity. Older unbound LOCAL records resolve only through the worker's exact SQLite filename association and an existing file.
- Preview provider comes from its source record. UI hydration must prefer a newly downloaded local binding; stale searches, likes or playback responses must not overwrite newer state. Failures keep likes and expose finite retries in download details.

## Desktop visuals

- Seven leaves and the trunk share the continuous `treeGeometry` coordinate curve; scrolling changes that curve and its decorative sprigs. Recommendation focus follows next/previous/autoplay as well as direct selection, without resetting deliberate browsing on pause/poll.
- Group navigation aligns with the left music-tree panel midpoint. The circular player remains centered in the window. Keep labels readable through hover/active states. Decorative art never intercepts clicks or obscures song controls.
- Rain, ripples and vines have bounded particle/frame budgets; stop animation on hidden/reduced-motion pages. Spectrum reads a captured audio copy and never reroutes playback. Recommendation waves use real audio energy where capture is allowed; uncapturable remote streams have quiet playback-progress ripples, never synthetic frequency bars. Pause clears waves; buffering does not advance them.
- Actual APP validation can attach Playwright to an isolated WebView2 via process-local debug-port and user-data-folder variables. Never enable those flags in production defaults or reuse the user's live state for tests.

## Management and packaging

- Maintenance jobs live in SQLite, one RUNNING task at a time, bounded to 600 seconds. Download components are pinned by release, size and SHA-256, and executable versions plus audio conversion are checked before atomic activation. Resolution prefers explicit environment overrides, verified managed tools, then PATH.
- SQLite `.backup` provides consistent snapshots but does not checkpoint the source WAL. Restore stops owned services, validates schema/integrity/hash, saves a safety snapshot, checkpoints successfully, then replaces. Failed preparation leaves old data usable. Backups exclude music and credentials; diagnostics export selected sanitized fields, not raw DBs/logs/paths/cookies.
- Runtime staging, Identity, Rust manifest/build watchers and fixtures include Onboarding, Management, Search and their scripts/assets in addition to the core service modules. The launcher explicitly serves new Web assets. Package a real SQLite executable but no personal credentials or data.
- The CI desktop gate is the authoritative clean-install test. A local portable launch does not prove silent installation. Self-signed release certificates only have trust where imported; they do not guarantee Windows reputation on other machines.
