# First-use experience: no network requests, downloads, or credential writes during preparation.
# Starter metadata was checked against NetEase on 2026-09-13. Media availability is resolved at playback.
function Get-MusicServerStarterCatalog {
    return @(
        [pscustomobject]@{ NeteaseId = '1330348068'; Title = '起风了'; Artist = '冯沁苑(买辣椒也用券)'; Album = '起风了'; Duration = 326 }
        [pscustomobject]@{ NeteaseId = '32717172'; Title = '青空'; Artist = 'Candy_Wind'; Album = '拂晓车站'; Duration = 201 }
        [pscustomobject]@{ NeteaseId = '1403774122'; Title = 'Speed of Light'; Artist = '塞壬唱片-MSR,DJ OKAWARI,二宮愛'; Album = 'Speed of Light'; Duration = 246 }
        [pscustomobject]@{ NeteaseId = '31445772'; Title = '理想三旬'; Artist = '陈鸿宇'; Album = '浓烟下的诗歌电台'; Duration = 211 }
        [pscustomobject]@{ NeteaseId = '1479543416'; Title = 'A Little Story'; Artist = 'Valentin'; Album = 'My View'; Duration = 204 }
        [pscustomobject]@{ NeteaseId = '139774'; Title = 'The truth that you leave'; Artist = 'Pianoboy高至豪'; Album = 'The truth that you leave'; Duration = 223 }
        [pscustomobject]@{ NeteaseId = '3410744228'; Title = '酸橙色信笺'; Artist = '塞壬唱片-MSR,DAZBEE'; Album = '酸橙色信笺'; Duration = 230 }
        [pscustomobject]@{ NeteaseId = '2743079423'; Title = 'Sakura Tears'; Artist = 'Snigellin'; Album = '壹伍壹捌·离'; Duration = 184 }
        [pscustomobject]@{ NeteaseId = '439142564'; Title = '和煦的糖果风'; Artist = 'Candy_Wind'; Album = '和煦的糖果风'; Duration = 183 }
        [pscustomobject]@{ NeteaseId = '139718'; Title = 'ALONE ON THE WAY'; Artist = 'Pianoboy高至豪'; Album = 'Alone On The Way'; Duration = 298 }
        [pscustomobject]@{ NeteaseId = '865283011'; Title = 'All in a Daydream'; Artist = 'Snigellin'; Album = 'All in a Daydream'; Duration = 229 }
        [pscustomobject]@{ NeteaseId = '523902194'; Title = '猫的舞步'; Artist = 'Candy_Wind'; Album = '猫的舞步'; Duration = 187 }
        [pscustomobject]@{ NeteaseId = '510309106'; Title = 'When I see the light at that Time'; Artist = 'Snigellin'; Album = 'When I see the light at that Time'; Duration = 269 }
        [pscustomobject]@{ NeteaseId = '485856132'; Title = 'Good Night'; Artist = 'Snigellin'; Album = 'Good Night'; Duration = 296 }
    )
}

function Initialize-StarterRecommendationsDb {
    param([string]$Date = (Get-TodayDate), [ValidateRange(1,100)][int]$Count = 14)
    if (@(Get-TodayRecommendationsDb -Date $Date).Count -gt 0) { return $false }
    $tracks = @(); $recommendations = @(); $rank = 0
    foreach ($song in @(Get-MusicServerStarterCatalog | Select-Object -First $Count)) {
        $rank++
        $preview = @([pscustomobject]@{ provider = 'netease'; id = $song.NeteaseId; media_url = "https://music.163.com/song/media/outer/url?id=$($song.NeteaseId).mp3"; duration = $song.Duration })
        $track = New-CanonicalTrack -Title $song.Title -Artist $song.Artist -Album $song.Album -Duration $song.Duration `
            -Identifiers @([pscustomobject]@{ type = 'netease'; value = $song.NeteaseId }) -PreviewSources $preview
        $tracks += $track
        $recommendations += [pscustomobject]@{
            id = "starter_${Date}_${rank}"; track_id = $track.id; netease_id = $song.NeteaseId
            title = $song.Title; artist = $song.Artist; album = $song.Album; duration = $song.Duration; rank = $rank
            reason = '初遇歌单 · 从一首喜欢开始'; seed_source = 'onboarding_starter'
            playback_source = "netease:$($song.NeteaseId)"; preview_sources = $preview
        }
    }
    $result = Save-DailyRecommendationsDb -Recommendations $recommendations -Tracks $tracks -Date $Date -OnlyIfEmpty
    return -not $result.Skipped
}

function Get-OnboardingStateDb {
    param([Parameter(Mandatory)][psobject]$Config)
    $phase = [string](Get-AppSettingDb -Key 'onboarding_phase')
    $history = @(Invoke-MusicServerSqlJson -Query "SELECT (SELECT COUNT(*) FROM recommendation_feedback WHERE feedback_type IN ('LIKE','ACCEPTED')) + (SELECT COUNT(*) FROM listening_stats) AS n;")
    $existing = @($history).Count -gt 0 -and [int]$history[0].n -gt 0
    $mode = Get-AppSettingDb -Key 'library_display_mode'
    $trackId = [string](Get-AppSettingDb -Key 'onboarding_track_id')
    $guideTrack = $null
    if ($trackId) {
        $track = Get-CanonicalTrackDb -TrackId $trackId
        if ($track) { $guideTrack = [pscustomobject]@{ track_id=$trackId; title=$track.title; artist=$track.artist; local_status=$track.status; wanted=(Get-WantedItemDb -TrackId $trackId) } }
    }
    $missing = @()
    foreach ($entry in @(@('YtDlp','下载组件'), @('FFmpeg','音频转换组件'), @('FFprobe','音频校验组件'))) {
        $path = [string]$Config.($entry[0])
        if (-not $path -or (-not [IO.File]::Exists($path) -and -not (Get-Command $path -ErrorAction SilentlyContinue))) { $missing += $entry[1] }
    }
    return [pscustomobject]@{
        phase = if ($phase -in @('welcome','listen','like','download','done')) { $phase } else { 'welcome' }
        dismissed = ([string](Get-AppSettingDb -Key 'onboarding_dismissed') -eq 'true') -or (-not $phase -and $existing)
        normalize = if ($mode) { $mode -eq 'canonical' } else { -not $existing }
        auto_lyrics = [string](Get-AppSettingDb -Key 'auto_lyrics') -ne 'false'
        download_ready = $missing.Count -eq 0; missing_components = $missing
        music_dir = $Config.MusicDir; library_available = [IO.Directory]::Exists($Config.MusicDir)
        track = $guideTrack
    }
}

function ConvertTo-OnboardingUpdate {
    param([Parameter(Mandatory)][psobject]$Data)
    $values = @{}; $invalid = ''
    if ($Data.phase) {
        if ($Data.phase -isnot [string] -or $Data.phase -notin @('welcome','listen','like','download','done')) { $invalid='Invalid onboarding phase.' }
        $values['Phase'] = [string]$Data.phase
    }
    if ($null -ne $Data.track_id) {
        if ($Data.track_id -isnot [string] -or -not $Data.track_id -or -not (Get-CanonicalTrackDb -TrackId $Data.track_id)) { $invalid='Unknown onboarding track.' }
        $values['TrackId'] = [string]$Data.track_id
    }
    foreach ($pair in @(@('dismissed','Dismissed'),@('normalize','Normalize'),@('auto_lyrics','AutoLyrics'))) {
        if ($null -ne $Data.($pair[0])) {
            if ($Data.($pair[0]) -isnot [bool]) { $invalid="Invalid onboarding boolean: $($pair[0])" }
            $values[$pair[1]] = [bool]$Data.($pair[0])
        }
    }
    if ($invalid) {
        $error = New-Object IO.InvalidDataException($invalid)
        $error.Data['HttpStatusCode'] = 400; $error.Data['ErrorCode'] = 'INVALID_ONBOARDING'
        throw $error
    }
    return $values
}

function Set-OnboardingStateDb {
    param(
        [ValidateSet('welcome','listen','like','download','done')][string]$Phase,
        [Nullable[bool]]$Dismissed, [Nullable[bool]]$Normalize, [Nullable[bool]]$AutoLyrics,
        [string]$TrackId
    )
    $changes = @{}
    if ($Phase) { $changes['onboarding_phase'] = $Phase }
    if ($TrackId) {
        if (-not (Get-CanonicalTrackDb -TrackId $TrackId)) { throw 'Unknown onboarding track.' }
        $changes['onboarding_track_id'] = $TrackId
    }
    if ($null -ne $Dismissed) { $changes['onboarding_dismissed'] = ([string][bool]$Dismissed).ToLowerInvariant() }
    if ($null -ne $Normalize) { $changes['library_display_mode'] = if ($Normalize) { 'canonical' } else { 'raw' } }
    if ($null -ne $AutoLyrics) { $changes['auto_lyrics'] = ([string][bool]$AutoLyrics).ToLowerInvariant() }
    if (-not $changes.Count) { return }
    $now = ConvertTo-MusicServerSqlLiteral (Get-NowIso)
    $statements = foreach ($key in $changes.Keys) {
        "INSERT INTO app_settings (key,value,updated_at) VALUES ($(ConvertTo-MusicServerSqlLiteral $key),$(ConvertTo-MusicServerSqlLiteral $changes[$key]),$now) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at"
    }
    Invoke-StateAtomicSql -Statements @($statements) | Out-Null
}

Export-ModuleMember -Function *
