Set-StrictMode -Version 3.0

function Resolve-MusicServerExecutable {
    param(
        [Parameter(Mandatory)][string]$EnvironmentVariable,
        [Parameter(Mandatory)][string[]]$Commands,
        [string[]]$FallbackPaths = @()
    )
    $configured = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if (Test-Path -LiteralPath $configured -PathType Leaf) { return [IO.Path]::GetFullPath($configured) }
        $resolvedConfigured = Get-Command $configured -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolvedConfigured) { return [string]$resolvedConfigured.Source }
    }
    foreach ($command in $Commands) {
        $resolved = Get-Command $command -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved) { return [string]$resolved.Source }
    }
    foreach ($fallback in $FallbackPaths) {
        if ($fallback -and (Test-Path -LiteralPath $fallback -PathType Leaf)) { return [IO.Path]::GetFullPath($fallback) }
    }
    return [string]$Commands[0]
}

function New-MusicServerConfig {
    param([string]$Root = $PSScriptRoot)

    $rootPath = [System.IO.Path]::GetFullPath($Root)
    return [pscustomobject]@{
        Root       = $rootPath
        MusicDir   = Join-Path $rootPath 'Music'
        DailyDir   = Join-Path $rootPath 'Music\DailyMix'
        DataDir    = Join-Path $rootPath 'DailyMix_data'
        StateDir   = Join-Path $rootPath 'DailyMix_data\state'
        NdDb       = Join-Path $rootPath 'Navidrome\Data\navidrome.db'
        NdExe      = Join-Path $rootPath 'Navidrome\bin\navidrome.exe'
        NdConfig   = Join-Path $rootPath 'Navidrome\navidrome.toml'
        YtDlp      = Resolve-MusicServerExecutable -EnvironmentVariable 'MUSICSERVER_YTDLP' -Commands @('yt-dlp.exe','yt-dlp') -FallbackPaths @('C:\Users\dell\anaconda3\Scripts\yt-dlp.exe')
        FFprobe    = Resolve-MusicServerExecutable -EnvironmentVariable 'MUSICSERVER_FFPROBE' -Commands @('ffprobe.exe','ffprobe') -FallbackPaths @('C:\Users\dell\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe')
        FFmpeg     = Resolve-MusicServerExecutable -EnvironmentVariable 'MUSICSERVER_FFMPEG' -Commands @('ffmpeg.exe','ffmpeg') -FallbackPaths @('C:\Users\dell\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe')
        CookieFile = Join-Path $rootPath 'cookies.txt'
        Sqlite     = Resolve-MusicServerExecutable -EnvironmentVariable 'MUSICSERVER_SQLITE' -Commands @('sqlite3.exe','sqlite3') -FallbackPaths @('C:\Users\dell\anaconda3\Library\bin\sqlite3.exe')
    }
}

function Initialize-MusicServerState {
    param([Parameter(Mandatory)][psobject]$Config)

    foreach ($path in @($Config.DataDir, $Config.StateDir, $Config.MusicDir, $Config.DailyDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }
    }
}

function Get-NowIso { return [DateTime]::UtcNow.ToString('o') }
function Get-TodayDate { return (Get-Date).ToString('yyyy-MM-dd') }

function Get-OptionalProperty {
    param([AllowNull()][psobject]$Object, [Parameter(Mandatory)][string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Set-OptionalProperty {
    param([Parameter(Mandatory)][psobject]$Object, [Parameter(Mandatory)][string]$Name, $Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Convert-ToUtcDateTime {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [DateTime]) {
        $date = [DateTime]$Value
        if ($date.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($date, [DateTimeKind]::Utc) }
        return $date.ToUniversalTime()
    }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
    try { return [DateTimeOffset]::Parse([string]$Value).UtcDateTime } catch { return $null }
}

function Convert-ToUtcIso {
    param([AllowNull()]$Value)
    $date = Convert-ToUtcDateTime $Value
    if ($date) { return $date.ToString('o') }
    return ''
}

function Normalize-MusicText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $value = $Text.Normalize([Text.NormalizationForm]::FormKD).ToLowerInvariant()
    $value = $value -replace '\p{M}', ''
    return ($value -replace '[\s\p{P}\p{S}]', '')
}

function Get-CanonicalTrackId {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Artist)
    $artistKey = @($Artist -split '[,，、/&]' | ForEach-Object { Normalize-MusicText $_ } | Where-Object { $_ } | Sort-Object) -join ','
    $identity = "$(Normalize-MusicText $Title)|$artistKey"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
        $hash = $sha.ComputeHash($bytes)
        $hex = [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
        return "track_$($hex.Substring(0, 24))"
    } finally { $sha.Dispose() }
}

function New-CanonicalTrack {
    param(
        [string]$TrackId,
        [Parameter(Mandatory)][string]$Title,
        [string]$Artist = '', [string]$Album = '', [int]$Duration = 0, [string]$CoverUrl = '',
        [object]$Identifiers = $null, [object]$PreviewSources = $null, [object]$DownloadCandidates = $null,
        [string]$LocalSongId = '',
        [ValidateSet('REMOTE','WANTED','RESOLVING','DOWNLOADING','VALIDATING','LOCAL','RETRY_WAIT','UNAVAILABLE')][string]$Status = 'REMOTE'
    )
    if (-not $TrackId) { $TrackId = Get-CanonicalTrackId -Title $Title -Artist $Artist }
    $now = Get-NowIso
    return [pscustomobject]@{
        id = $TrackId; title = $Title; artist = $Artist; album = $Album; duration = $Duration; cover_url = $CoverUrl
        identifiers = @($Identifiers); preview_sources = @($PreviewSources); download_candidates = @($DownloadCandidates)
        local_song_id = $LocalSongId; status = $Status; created_at = $now; updated_at = $now
    }
}

function Get-StateFilePath {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][ValidateSet('tracks','recommendations','recommendation_history','wanted','providers')][string]$Name)
    return Join-Path $Config.StateDir "$Name.json"
}

function Read-StateCollection {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][ValidateSet('tracks','recommendations','recommendation_history','wanted','providers')][string]$Name)
    Initialize-MusicServerState -Config $Config
    $path = Get-StateFilePath -Config $Config -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $value = ConvertFrom-Json -InputObject $raw
        if ($null -eq $value) { return @() }
        return @($value)
    } catch { throw "无法读取状态文件 $path：$($_.Exception.Message)" }
}

function Write-StateCollection {
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][ValidateSet('tracks','recommendations','recommendation_history','wanted','providers')][string]$Name,
        [AllowEmptyCollection()][object[]]$Items = @()
    )
    Initialize-MusicServerState -Config $Config
    $path = Get-StateFilePath -Config $Config -Name $Name
    $temp = "$path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $json = ConvertTo-Json -InputObject @($Items) -Depth 20
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Save-CanonicalTrack {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Track)
    $items = @(Read-StateCollection -Config $Config -Name tracks)
    Set-OptionalProperty -Object $Track -Name 'updated_at' -Value (Get-NowIso)
    $found = $false
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ([string]$items[$i].id -eq [string]$Track.id) {
            $old = $items[$i]
            $oldCreated = [string](Get-OptionalProperty $old 'created_at')
            $incomingCreated = [string](Get-OptionalProperty $Track 'created_at')
            $isExplicitMutation = $oldCreated -and $incomingCreated -and $oldCreated -eq $incomingCreated
            if (-not $incomingCreated -and $oldCreated) { Set-OptionalProperty -Object $Track -Name 'created_at' -Value $oldCreated }
            $oldStatus = [string](Get-OptionalProperty $old 'status' 'REMOTE')
            $incomingStatus = [string](Get-OptionalProperty $Track 'status' 'REMOTE')
            if (-not $isExplicitMutation -and $oldStatus -ne 'REMOTE' -and $incomingStatus -eq 'REMOTE') {
                Set-OptionalProperty -Object $Track -Name 'status' -Value $oldStatus
            }
            if (-not (Get-OptionalProperty $Track 'local_song_id') -and (Get-OptionalProperty $old 'local_song_id')) { Set-OptionalProperty -Object $Track -Name 'local_song_id' -Value $old.local_song_id }
            foreach ($arrayName in @('identifiers','preview_sources','download_candidates')) {
                $merged = @(); $seen = New-Object System.Collections.Generic.HashSet[string]
                foreach ($item in @((Get-OptionalProperty $old $arrayName), (Get-OptionalProperty $Track $arrayName))) {
                    if ($null -eq $item) { continue }
                    $key = ConvertTo-Json $item -Compress -Depth 10
                    if ($seen.Add($key)) { $merged += $item }
                }
                Set-OptionalProperty -Object $Track -Name $arrayName -Value $merged
            }
            $items[$i] = $Track; $found = $true; break
        }
    }
    if (-not $found) { $items += $Track }
    Write-StateCollection -Config $Config -Name tracks -Items $items
    return $Track
}

function Get-CanonicalTrack {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$TrackId)
    return @(Read-StateCollection -Config $Config -Name tracks | Where-Object { [string]$_.id -eq $TrackId }) | Select-Object -First 1
}

function Save-DailyRecommendations {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][object[]]$Recommendations, [string]$Date = (Get-TodayDate), [switch]$DryRun)
    if ($DryRun) { return }
    $recs = @($Recommendations)
    Write-StateCollection -Config $Config -Name recommendations -Items $recs
    $history = @(Read-StateCollection -Config $Config -Name recommendation_history | Where-Object { [string]$_.date -ne $Date })
    $history += $recs
    Write-StateCollection -Config $Config -Name recommendation_history -Items $history
    $legacyPath = Join-Path $Config.DataDir 'today.csv'
    $legacyRows = @(foreach ($r in $recs) {
        [pscustomobject]@{
            Date = $Date; TrackId = (Get-OptionalProperty $r 'track_id'); NeteaseId = (Get-OptionalProperty $r 'netease_id')
            Title = (Get-OptionalProperty $r 'title'); Artist = (Get-OptionalProperty $r 'artist'); Duration = (Get-OptionalProperty $r 'duration' 0)
            FromSeed = (Get-OptionalProperty $r 'reason'); Rank = (Get-OptionalProperty $r 'rank' 0); PlaybackSource = (Get-OptionalProperty $r 'playback_source')
            Liked = (Get-OptionalProperty $r 'liked' $false); Status = 'REMOTE'; File = ''
        }
    })
    if ($legacyRows.Count -gt 0) { $legacyRows | Export-Csv -LiteralPath $legacyPath -NoTypeInformation -Encoding UTF8 }
}

function Import-LegacyRecommendationState {
    param([Parameter(Mandatory)][psobject]$Config)
    Initialize-MusicServerState -Config $Config
    if (@(Read-StateCollection -Config $Config -Name recommendations).Count -gt 0) { return 0 }
    $legacyPath = Join-Path $Config.DataDir 'today.csv'
    if (-not (Test-Path -LiteralPath $legacyPath)) { return 0 }
    $rows = @(Import-Csv -LiteralPath $legacyPath -Encoding UTF8 | Where-Object { $_.Title })
    if ($rows.Count -eq 0) { return 0 }
    $date = Get-TodayDate; $tracks = @(); $recs = @(); $rank = 0
    foreach ($row in $rows) {
        $rank++; $title = [string](Get-OptionalProperty $row 'Title'); $artist = [string](Get-OptionalProperty $row 'Artist')
        $trackId = [string](Get-OptionalProperty $row 'TrackId'); if (-not $trackId) { $trackId = Get-CanonicalTrackId -Title $title -Artist $artist }
        $fileName = [string](Get-OptionalProperty $row 'File'); $localPath = if ($fileName) { Join-Path $Config.DailyDir $fileName } else { '' }
        $isLocal = $localPath -and (Test-Path -LiteralPath $localPath); $neteaseId = [string](Get-OptionalProperty $row 'NeteaseId'); $duration = [int](Get-OptionalProperty $row 'Duration' 0)
        $preview = if ($neteaseId) { @([pscustomobject]@{ provider = 'netease'; id = $neteaseId; url = "https://music.163.com/#/song?id=$neteaseId"; media_url = "https://music.163.com/song/media/outer/url?id=$neteaseId.mp3"; duration = $duration }) } else { @() }
        $trackStatus = if ($isLocal) { 'LOCAL' } else { 'REMOTE' }; $playbackSource = if ($isLocal) { "navidrome:$trackId" } elseif ($neteaseId) { "netease:$neteaseId" } else { '' }
        $track = New-CanonicalTrack -TrackId $trackId -Title $title -Artist $artist -Duration $duration -Identifiers @([pscustomobject]@{ type = 'netease'; value = $neteaseId }) -PreviewSources $preview -DownloadCandidates @([pscustomobject]@{ provider = 'local'; priority = 100 }, [pscustomobject]@{ provider = 'bilibili_search'; priority = 10; requires_search = $true }) -LocalSongId '' -Status $trackStatus
        $tracks += $track
        $recs += [pscustomobject]@{
            id = "rec_legacy_${date}_$rank"; date = $date; track_id = $trackId; netease_id = $neteaseId; title = $title; artist = $artist; duration = $duration; rank = $rank
            reason = [string](Get-OptionalProperty $row 'FromSeed' '历史日推'); playback_source = $playbackSource; preview_sources = $preview
            liked = [bool]([string](Get-OptionalProperty $row 'Liked' 'False') -eq 'True'); created_at = Get-NowIso; updated_at = Get-NowIso
        }
    }
    foreach ($track in $tracks) { Save-CanonicalTrack -Config $Config -Track $track | Out-Null }
    Write-StateCollection -Config $Config -Name recommendations -Items $recs
    Write-StateCollection -Config $Config -Name recommendation_history -Items $recs
    Write-StructuredEvent -Config $Config -Event 'LEGACY_STATE_IMPORTED' -Result 'SUCCESS' -Message "count=$($recs.Count)"
    return $recs.Count
}

function Get-TodayRecommendations {
    param([Parameter(Mandatory)][psobject]$Config, [string]$Date = (Get-TodayDate))
    return @(Read-StateCollection -Config $Config -Name recommendations | Where-Object { [string]$_.date -eq $Date } | Sort-Object rank)
}

function Get-TrackLiked {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$TrackId)
    $current = @(Read-StateCollection -Config $Config -Name recommendations | Where-Object { [string]$_.track_id -eq $TrackId } | Select-Object -First 1)
    if ($current) { return [bool](Get-OptionalProperty ($current | Select-Object -First 1) 'liked' $false) }
    $history = @(Read-StateCollection -Config $Config -Name recommendation_history | Where-Object { [string]$_.track_id -eq $TrackId } | Sort-Object date -Descending | Select-Object -First 1)
    if ($history) { return [bool](Get-OptionalProperty ($history | Select-Object -First 1) 'liked' $false) }
    return $false
}

function Add-WantedTrack {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$TrackId, [int]$MaxAttempts = 5)
    $items = @(Read-StateCollection -Config $Config -Name wanted)
    $existing = $items | Where-Object { [string]$_.track_id -eq $TrackId } | Select-Object -First 1
    if ($existing) {
        if ([string]$existing.state -in @('UNAVAILABLE','LOCAL','CANCEL_REQUESTED')) {
            $existing.state = 'WANTED'; $existing.attempts = 0; $existing.next_retry_at = $null; $existing.last_error = ''
        }
        $existing.updated_at = Get-NowIso; Write-StateCollection -Config $Config -Name wanted -Items $items; return $existing
    }
    $wanted = [pscustomobject]@{
        id = "wanted_$([guid]::NewGuid().ToString('N'))"; track_id = $TrackId; state = 'WANTED'; attempts = 0; max_attempts = $MaxAttempts
        next_retry_at = $null; selected_candidate = $null; last_error = ''; created_at = Get-NowIso; updated_at = Get-NowIso
    }
    $items += $wanted; Write-StateCollection -Config $Config -Name wanted -Items $items; return $wanted
}

function Get-WantedTracks {
    param([Parameter(Mandatory)][psobject]$Config, [switch]$EligibleOnly)
    $items = @(Read-StateCollection -Config $Config -Name wanted)
    if (-not $EligibleOnly) { return $items }
    $now = [DateTime]::UtcNow
    return @($items | Where-Object {
        if ([string]$_.state -in @('WANTED','CANCEL_REQUESTED')) { return $true }
        if ([string]$_.state -ne 'RETRY_WAIT') { return $false }
        if (-not $_.next_retry_at) { return $true }
        $retryAt = Convert-ToUtcDateTime $_.next_retry_at
        if ($retryAt) { return ($retryAt -le $now) }
        return $true
    })
}

function Save-WantedTrack {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Wanted)
    $items = @(Read-StateCollection -Config $Config -Name wanted); $Wanted.updated_at = Get-NowIso; $found = $false
    for ($i = 0; $i -lt $items.Count; $i++) { if ([string]$items[$i].id -eq [string]$Wanted.id) { $items[$i] = $Wanted; $found = $true; break } }
    if (-not $found) { $items += $Wanted }; Write-StateCollection -Config $Config -Name wanted -Items $items; return $Wanted
}

function Remove-WantedTrack {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$WantedId)
    $items = @(Read-StateCollection -Config $Config -Name wanted); $remaining = @($items | Where-Object { [string]$_.id -ne $WantedId })
    if ($remaining.Count -ne $items.Count) { Write-StateCollection -Config $Config -Name wanted -Items $remaining }
}

function Set-TrackStatus {
    param(
        [Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][ValidateSet('REMOTE','WANTED','RESOLVING','DOWNLOADING','VALIDATING','LOCAL','RETRY_WAIT','UNAVAILABLE')][string]$Status,
        [string]$LocalSongId = ''
    )
    $track = Get-CanonicalTrack -Config $Config -TrackId $TrackId
    if (-not $track) { return $null }
    $track.status = $Status; if ($LocalSongId) { $track.local_song_id = $LocalSongId }
    Save-CanonicalTrack -Config $Config -Track $track
}

function Reset-TrackToRemote {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$TrackId)
    $items = @(Read-StateCollection -Config $Config -Name tracks); $result = $null; $changed = $false
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ([string]$items[$i].id -eq $TrackId) {
            if ([string]$items[$i].status -ne 'LOCAL') {
                $items[$i].status = 'REMOTE'; Set-OptionalProperty -Object $items[$i] -Name 'updated_at' -Value (Get-NowIso); $changed = $true
            }
            $result = $items[$i]; break
        }
    }
    if ($changed) { Write-StateCollection -Config $Config -Name tracks -Items $items }
    return $result
}

function Set-TrackLike {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$TrackId, [Parameter(Mandatory)][bool]$Liked)
    foreach ($stateName in @('recommendations','recommendation_history')) {
        $recs = @(Read-StateCollection -Config $Config -Name $stateName); $changed = $false
        foreach ($rec in $recs) {
            if ([string]$rec.track_id -eq $TrackId) {
                Set-OptionalProperty -Object $rec -Name 'liked' -Value $Liked; Set-OptionalProperty -Object $rec -Name 'updated_at' -Value (Get-NowIso); $changed = $true
            }
        }
        if ($changed) { Write-StateCollection -Config $Config -Name $stateName -Items $recs }
    }

    $track = Get-CanonicalTrack -Config $Config -TrackId $TrackId
    if ($track) {
        if ($Liked) {
            if ([string]$track.status -in @('REMOTE','UNAVAILABLE')) { $track.status = 'WANTED' }
            Save-CanonicalTrack -Config $Config -Track $track | Out-Null
        } elseif ([string]$track.status -in @('WANTED','RETRY_WAIT','UNAVAILABLE')) {
            Reset-TrackToRemote -Config $Config -TrackId $TrackId | Out-Null
        }
    }

    $wantedItems = @(Read-StateCollection -Config $Config -Name wanted)
    $existing = $wantedItems | Where-Object { [string]$_.track_id -eq $TrackId } | Select-Object -First 1
    if ($Liked) {
        if (-not $existing) { $existing = Add-WantedTrack -Config $Config -TrackId $TrackId }
        elseif ([string]$existing.state -eq 'CANCEL_REQUESTED') {
            $existing.state = 'WANTED'; $existing.next_retry_at = $null; $existing.last_error = ''; Save-WantedTrack -Config $Config -Wanted $existing | Out-Null
        }
    } elseif ($existing) {
        if ([string]$existing.state -in @('WANTED','RETRY_WAIT','UNAVAILABLE')) {
            Remove-WantedTrack -Config $Config -WantedId ([string]$existing.id); Reset-TrackToRemote -Config $Config -TrackId $TrackId | Out-Null; $existing = $null
        } elseif ([string]$existing.state -in @('RESOLVING','DOWNLOADING','VALIDATING')) {
            $existing.state = 'CANCEL_REQUESTED'; $existing.next_retry_at = $null; $existing.last_error = 'USER_CANCELLED'; Save-WantedTrack -Config $Config -Wanted $existing | Out-Null
        }
    }
    return [pscustomobject]@{ track_id = $TrackId; liked = $Liked; wanted = $existing }
}

function Write-StructuredEvent {
    param(
        [Parameter(Mandatory)][psobject]$Config, [string]$TrackId = '', [string]$Provider = '', [string]$Event = '',
        [string]$FromState = '', [string]$ToState = '', [int]$Attempt = 0, [double]$DurationMs = 0,
        [string]$Result = '', [string]$ErrorType = '', [int]$HttpStatus = 0, [string]$Message = ''
    )
    Initialize-MusicServerState -Config $Config
    $row = [ordered]@{
        timestamp = Get-NowIso; track_id = $TrackId; provider = $Provider; event = $Event; from_state = $FromState; to_state = $ToState; attempt = $Attempt
        duration_ms = $DurationMs; result = $Result; error_type = $ErrorType; http_status = $HttpStatus; message = $Message
    }
    $path = Join-Path $Config.StateDir 'events.jsonl'
    [IO.File]::AppendAllText($path, ((ConvertTo-Json $row -Compress -Depth 10) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}

function Find-LocalTrack {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$Title, [string]$Artist = '')
    if (-not (Test-Path -LiteralPath $Config.MusicDir)) { return $null }
    $titleKey = Normalize-MusicText $Title; if (-not $titleKey) { return $null }
    $artistKey = Normalize-MusicText $Artist; $exact = Normalize-MusicText "$Title - $Artist"; $requiresStrictShortTitleMatch = $titleKey.Length -le 1
    $candidates = foreach ($file in (Get-ChildItem -LiteralPath $Config.MusicDir -Filter '*.mp3' -File -Recurse -ErrorAction SilentlyContinue)) {
        $base = Normalize-MusicText $file.BaseName
        if (-not $base.Contains($titleKey)) { continue }
        if ($requiresStrictShortTitleMatch -and $base -ne $titleKey -and $base -ne $exact) { continue }
        if ($artistKey -and -not $base.Contains($artistKey)) { continue }
        $score = 50; if ($base -eq $exact) { $score += 100 }; if ($artistKey) { $score += 30 }
        if ($score -gt 0) { [pscustomobject]@{ File = $file; Score = $score } }
    }
    return $candidates | Sort-Object Score -Descending | Select-Object -First 1
}

function Get-NavidromeSongIdForPath {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Config.NdDb)) { return '' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "musicserver_nd_$([guid]::NewGuid().ToString('N')).db"
    try {
        Copy-Item -LiteralPath $Config.NdDb -Destination $tmp -Force
        foreach ($ext in @('-wal','-shm')) { $sidecar = "$($Config.NdDb)$ext"; if (Test-Path -LiteralPath $sidecar) { Copy-Item -LiteralPath $sidecar -Destination "$tmp$ext" -Force -ErrorAction SilentlyContinue } }
        $fullMusic = ([IO.Path]::GetFullPath($Config.MusicDir)).TrimEnd('\') + '\'; $fullPath = [IO.Path]::GetFullPath($Path)
        if ($fullPath.StartsWith($fullMusic, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $fullPath.Substring($fullMusic.Length).Replace('\','/').Replace("'", "''")
            $query = "select id from media_file where replace(path, '\', '/') = '$relative' limit 1;"
            $id = & $Config.Sqlite $tmp $query 2>$null | Select-Object -First 1; if ($id) { return [string]$id }
        }
        $leaf = [IO.Path]::GetFileName($Path).Replace("'", "''")
        $fallbackQuery = "select case when count(*) = 1 then min(id) else '' end from media_file where path like '%$leaf';"
        $fallbackId = & $Config.Sqlite $tmp $fallbackQuery 2>$null | Select-Object -First 1; return [string]$fallbackId
    } catch { return '' }
    finally { Remove-Item -LiteralPath "$tmp*" -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function *
