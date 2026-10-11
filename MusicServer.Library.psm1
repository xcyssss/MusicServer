Set-StrictMode -Version 3.0

# Runtime truth remains SQLite. A portable manifest is consumed once as verified
# migration input; it is never read to answer normal library requests.
$script:LibrarySchemaDb = ''
$script:LibraryAudioExtensions = @('.mp3','.flac','.wav','.aac','.m4a','.ogg','.opus')

function Initialize-MusicServerLibrarySchema {
    $db = Get-MusicServerDbPath
    if ($script:LibrarySchemaDb -eq $db -and $db) { return }
    Invoke-MusicServerSqlNonQuery -Query @'
CREATE TABLE IF NOT EXISTS library_tracks (
 root_key TEXT NOT NULL, relative_path TEXT NOT NULL, import_order INTEGER NOT NULL,
 imported_at TEXT NOT NULL, size INTEGER NOT NULL, modified_at TEXT NOT NULL,
 metadata_json TEXT NOT NULL DEFAULT '{}', metadata_source TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(root_key, relative_path)
);
CREATE INDEX IF NOT EXISTS idx_library_order ON library_tracks(root_key, import_order);
CREATE TABLE IF NOT EXISTS library_imports (
 root_key TEXT NOT NULL, manifest_hash TEXT NOT NULL, imported_at TEXT NOT NULL,
 PRIMARY KEY(root_key, manifest_hash)
);
'@
    $script:LibrarySchemaDb = $db
}

function Get-MusicServerLibraryRootKey {
    param($Config)
    return [IO.Path]::GetFullPath([string]$Config.MusicDir).TrimEnd('\','/').ToLowerInvariant()
}

function Set-MusicServerRecommendationLibraryPending {
    param($Config)
    $pending = [ordered]@{revision=[Guid]::NewGuid().ToString('N');path_key=(Get-MusicServerPathKey -Path ([string]$Config.MusicDir))}
    Set-AppSettingDb -Key 'recommendation_library_pending' -Value (ConvertTo-Json -InputObject $pending -Compress)
    return [pscustomobject]$pending
}

function Resolve-MusicServerLibraryRelativePath {
    param($Config, [Parameter(Mandatory)][string]$RelativePath, [switch]$MustExist)
    if ($RelativePath.Length -gt 2048 -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '[:\x00-\x1f]') { throw 'INVALID_LIBRARY_RELATIVE_PATH' }
    $parts = @($RelativePath -split '[\\/]')
    if ($parts.Count -eq 0 -or @($parts | Where-Object { -not $_ -or $_ -eq '.' -or $_ -eq '..' -or $_.EndsWith('.') -or $_.EndsWith(' ') }).Count) { throw 'INVALID_LIBRARY_RELATIVE_PATH' }
    $root = [IO.Path]::GetFullPath([string]$Config.MusicDir).TrimEnd('\','/')
    $path = [IO.Path]::GetFullPath((Join-Path $root ($parts -join '\')))
    if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'INVALID_LIBRARY_RELATIVE_PATH' }
    $cursor = $root
    foreach ($part in @('') + $parts) {
        if ($part) { $cursor = Join-Path $cursor $part }
        if ([IO.Directory]::Exists($cursor) -or [IO.File]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'LIBRARY_REPARSE_NOT_SUPPORTED' }
        }
    }
    if ($MustExist -and -not [IO.File]::Exists($path)) { throw 'LIBRARY_CONTENT_MISSING' }
    return $path
}

function Get-MusicServerLibraryRelativePath {
    param($Config, [Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath([string]$Config.MusicDir).TrimEnd('\','/')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'LIBRARY_FILE_OUTSIDE_ROOT' }
    $relative = $full.Substring($root.Length + 1).Replace('\','/')
    Resolve-MusicServerLibraryRelativePath -Config $Config -RelativePath $relative -MustExist | Out-Null
    return $relative
}

function Get-MusicServerLibraryAudioFiles {
    param($Config)
    if (-not [IO.Directory]::Exists($Config.MusicDir)) { throw 'LIBRARY_UNAVAILABLE' }
    $pending = New-Object 'Collections.Generic.Queue[string]'
    $pending.Enqueue([IO.Path]::GetFullPath([string]$Config.MusicDir))
    $files = New-Object 'Collections.Generic.List[object]'
    while ($pending.Count) {
        $directory = $pending.Dequeue()
        if (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
            if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $pending.Enqueue($child) }
        }
        foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
            if ([IO.Path]::GetExtension($file).ToLowerInvariant() -notin $script:LibraryAudioExtensions) { continue }
            if (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $files.Add((New-Object IO.FileInfo($file)))
            if ($files.Count -gt 25000) { throw 'LIBRARY_TRACK_LIMIT' }
        }
    }
    return @($files.ToArray() | Sort-Object FullName)
}

function ConvertTo-MusicServerLibraryMetadata {
    param($Item, [switch]$Portable)
    $metadata = [ordered]@{}
    foreach ($field in @('title','name','artist','album','raw_artist','raw_album','canonical_title','canonical_title_source','canonical_track_id','library_id','library_relative_path')) {
        if ($Portable -and $field -in @('library_id','library_relative_path','canonical_track_id')) { continue }
        $value = Get-OptionalProperty $Item $field ''
        if ($value -is [string]) { $clean = ([string]$value).Replace([string][char]0,''); $metadata[$field] = $clean.Substring(0,[Math]::Min(1024,$clean.Length)) }
    }
    foreach ($field in @('duration','track','year')) {
        $value = 0
        if ([int]::TryParse([string](Get-OptionalProperty $Item $field 0), [ref]$value)) { $metadata[$field] = [Math]::Max(0,[Math]::Min(86400,$value)) }
    }
    return [pscustomobject]$metadata
}

function Test-MusicServerLibraryArtistCredit {
    param([string]$Artist = '')
    # Same approved credit contract as Test-MusicServerArtistCredit. Importing
    # Providers here would force-reload State in the maintenance worker.
    $value = $Artist.Trim().Trim('[',']','【','】').Trim()
    return $value -and $value -notmatch '^(?i)(?:unknown(?:[ _-]+(?:artist|singer))?|various(?:[ _-]+artists)?|n/?a|none|null|未知(?:歌手|艺术家|藝人)?|佚名|群星)$'
}

function Merge-MusicServerLibraryCanonicalMetadata {
    param($Metadata,$Canonical)
    if (-not $Metadata.raw_artist) { $Metadata.raw_artist = [string]$Metadata.artist }
    if (-not $Metadata.raw_album) { $Metadata.raw_album = [string]$Metadata.album }
    if (Test-MusicServerLibraryArtistCredit -Artist ([string]$Canonical.artist)) { $Metadata.artist = [string]$Canonical.artist }
    if ([string]$Canonical.album) { $Metadata.album = [string]$Canonical.album }
    if ([int]$Canonical.duration -gt 0) { $Metadata.duration = [int]$Canonical.duration }
    if ([int]$Canonical.release_year -gt 0) { $Metadata.year = [int]$Canonical.release_year }
    $Metadata.canonical_track_id = [string]$Canonical.id
    return $Metadata
}

function ConvertTo-MusicServerLibraryTextLiteral {
    param([AllowEmptyString()][string]$Text)
    # The same UTF-8 blob literal contract as Database, with bulk conversion in
    # .NET so indexing thousands of tracks does not invoke PowerShell per byte.
    $hex = [BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($Text)).Replace('-','')
    return "CAST(X'$hex' AS TEXT)"
}

function Get-MusicServerLibraryIndex {
    param($Config)
    Initialize-MusicServerLibrarySchema
    $map = @{}
    foreach ($row in @(Invoke-MusicServerParamSql -Template "SELECT t.relative_path,t.import_order,t.imported_at,t.size,t.modified_at,t.metadata_json,t.metadata_source,c.id AS canonical_id,c.artist AS canonical_artist,c.album AS canonical_album,c.duration AS canonical_duration,c.release_year AS canonical_year FROM library_tracks t LEFT JOIN canonical_tracks c ON c.id=json_extract(t.metadata_json,'$.canonical_track_id') WHERE t.root_key=@root;" -Params @{root=(Get-MusicServerLibraryRootKey -Config $Config)})) {
        if ($row.canonical_id) {
            $metadata = ConvertTo-MusicServerLibraryMetadata -Item ([string]$row.metadata_json | ConvertFrom-Json)
            $canonical = [pscustomobject]@{id=[string]$row.canonical_id;artist=[string]$row.canonical_artist;album=[string]$row.canonical_album;duration=[int]$row.canonical_duration;release_year=[int]$row.canonical_year}
            $row.metadata_json = ConvertTo-Json -InputObject (Merge-MusicServerLibraryCanonicalMetadata -Metadata $metadata -Canonical $canonical) -Depth 4 -Compress
        }
        $map[([string]$row.relative_path).ToLowerInvariant()] = $row
    }
    return $map
}

function Get-MusicServerLibrarySnapshot {
    param($Config)
    if (-not [IO.Directory]::Exists($Config.MusicDir)) { return @() }
    $rootPrefix = [IO.Path]::GetFullPath([string]$Config.MusicDir).TrimEnd('\','/') + '\'
    Initialize-MusicServerLibrarySchema
    # Project approved fields in SQLite once rather than parsing one JSON object
    # and invoking property helper functions for every row on first paint.
    $rows = @(Invoke-MusicServerParamSql -Template @'
SELECT import_order,imported_at,
 COALESCE(json_extract(metadata_json,'$.library_relative_path'),relative_path) AS relative_path,
 COALESCE(json_extract(metadata_json,'$.library_id'),'') AS library_id,
 COALESCE(json_extract(metadata_json,'$.title'),'') AS title,
 COALESCE(json_extract(metadata_json,'$.name'),json_extract(metadata_json,'$.title'),'') AS name,
 COALESCE(json_extract(metadata_json,'$.artist'),'') AS artist,
 COALESCE(json_extract(metadata_json,'$.album'),'') AS album,
 COALESCE(json_extract(metadata_json,'$.raw_artist'),json_extract(metadata_json,'$.artist'),'') AS raw_artist,
 COALESCE(json_extract(metadata_json,'$.raw_album'),json_extract(metadata_json,'$.album'),'') AS raw_album,
 COALESCE(json_extract(metadata_json,'$.duration'),0) AS duration,
 COALESCE(json_extract(metadata_json,'$.track'),0) AS track,
 COALESCE(json_extract(metadata_json,'$.year'),0) AS year,
 COALESCE(json_extract(metadata_json,'$.canonical_title'),'') AS canonical_title,
 COALESCE(json_extract(metadata_json,'$.canonical_title_source'),'') AS canonical_title_source,
 COALESCE(json_extract(metadata_json,'$.canonical_track_id'),'') AS canonical_track_id
FROM library_tracks WHERE root_key=@root AND json_valid(metadata_json) ORDER BY import_order;
'@ -Params @{root=(Get-MusicServerLibraryRootKey -Config $Config)})
    $canonicalById = @{}; $canonicalByBinding = @{}
    foreach ($canonical in @(Invoke-MusicServerSqlJson -Query @'
WITH latest_preference AS (
 SELECT track_id,feedback_type,ROW_NUMBER() OVER(PARTITION BY track_id ORDER BY created_at DESC,id DESC) AS rank
 FROM recommendation_feedback WHERE feedback_type IN('LIKE','UNLIKE','DISLIKE','UNDISLIKE')
)
SELECT c.id,c.local_song_id,c.artist,c.album,c.duration,c.release_year,p.feedback_type
FROM canonical_tracks c LEFT JOIN latest_preference p ON p.track_id=c.id AND p.rank=1;
'@)) {
        $canonicalById[[string]$canonical.id] = $canonical
        if ([string]$canonical.local_song_id) { $canonicalByBinding[[string]$canonical.local_song_id] = $canonical }
    }
    foreach ($row in $rows) {
        $relative = [string]$row.relative_path
        if (-not $relative -or $relative -match '^[/\\]|(^|[/\\])\.\.?([/\\]|$)|[:\x00-\x1f]') { continue }
        try { $file = [IO.Path]::GetFullPath($rootPrefix + $relative.Replace('/','\')) } catch { continue }
        if (-not $file.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($file)) { continue }
        $id = [string]$row.library_id
        if ($id -notmatch '^[a-zA-Z0-9_-]{1,160}$') { $id = Get-MusicServerLocalIdentity -File $file }
        $canonical = $null
        if ($row.canonical_track_id -and $canonicalById.ContainsKey([string]$row.canonical_track_id)) { $canonical = $canonicalById[[string]$row.canonical_track_id] }
        if (-not $canonical) {
            foreach ($binding in @(('file:'+$file),$file,$id,($id -replace '^library-',''))) {
                if ($canonicalByBinding.ContainsKey($binding)) { $canonical = $canonicalByBinding[$binding]; break }
            }
        }
        $canonicalId = if ($canonical) { [string]$canonical.id } else { '' }
        $artist = [string]$row.artist
        $album = [string]$row.album; $seconds = [int]$row.duration; $year = [int]$row.year
        if ($canonical) {
            if (Test-MusicServerLibraryArtistCredit -Artist ([string]$canonical.artist)) { $artist = [string]$canonical.artist }
            if ([string]$canonical.album) { $album = [string]$canonical.album }
            if ([int]$canonical.duration -gt 0) { $seconds = [int]$canonical.duration }
            if ([int]$canonical.release_year -gt 0) { $year = [int]$canonical.release_year }
        }
        if (-not (Test-MusicServerLibraryArtistCredit -Artist $artist)) { $artist = '' }
        $explicitPreference = if ($canonical) { [string]$canonical.feedback_type } else { '' }
        $title = [string]$row.title
        if (-not $title) { $title = [IO.Path]::GetFileNameWithoutExtension($file) }
        $directory = [IO.Path]::GetDirectoryName($file)
        $name = [IO.Path]::GetFileNameWithoutExtension($file)
        $hasLyrics = [IO.File]::Exists([IO.Path]::ChangeExtension($file,'.lrc'))
        if (-not $hasLyrics) { $hasLyrics = [IO.File]::Exists($directory+'\Lyrics\'+$name+'.lrc') }
        if (-not $hasLyrics) { $hasLyrics = [IO.File]::Exists($directory+'\歌词\'+$name+'.lrc') }
        [pscustomobject]@{
            id=$id;library_id=$id;source='local';provider='navidrome';path=$file;file=$file
            title=$title;name=[string]$row.name;artist=$artist;album=$album
            raw_artist=[string]$row.raw_artist;raw_album=[string]$row.raw_album
            duration=$seconds;track=[int]$row.track;year=$year
            canonical_track_id=$canonicalId;track_id=$(if ($canonicalId) {$canonicalId} else {$id});listening_identity=$(if ($canonicalId) {$canonicalId} else {$id});local_status='LOCAL'
            liked=$(if ($explicitPreference) {$explicitPreference -eq 'LIKE'} else {$null});disliked=($explicitPreference -eq 'DISLIKE')
            canonical_title=[string]$row.canonical_title;canonical_title_source=[string]$row.canonical_title_source
            import_order=[long]$row.import_order;imported_at=[string]$row.imported_at;addedto=[string]$row.imported_at;collectionat=[string]$row.imported_at
            stream_url="/api/library/$id/stream";lyrics_url="/api/library/$id/lyrics";has_local_lyrics=$hasLyrics
        }
    }
}

function Get-MusicServerLibraryFileById {
    param($Config, [Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[a-zA-Z0-9_-]{1,160}$' -or -not [IO.Directory]::Exists($Config.MusicDir)) { return $null }
    Initialize-MusicServerLibrarySchema
    $rootPrefix = [IO.Path]::GetFullPath([string]$Config.MusicDir).TrimEnd('\','/') + '\'
    # Imported manifests intentionally exclude the old device's path-derived ID.
    # Only those unindexed IDs need the shared path hash; ordinary playback reads
    # the one matching row instead of enumerating or resolving the entire library.
    $rows = @(Invoke-MusicServerParamSql -Template @'
SELECT COALESCE(json_extract(metadata_json,'$.library_relative_path'),relative_path) AS relative_path,
 COALESCE(json_extract(metadata_json,'$.library_id'),'') AS library_id
FROM library_tracks WHERE root_key=@root AND json_valid(metadata_json)
 AND (COALESCE(json_extract(metadata_json,'$.library_id'),'')=@id OR COALESCE(json_extract(metadata_json,'$.library_id'),'')='');
'@ -Params @{root=(Get-MusicServerLibraryRootKey -Config $Config);id=$Id})
    foreach ($row in $rows) {
        $relative = [string]$row.relative_path
        if (-not $relative -or $relative -match '^[/\\]|(^|[/\\])\.\.?([/\\]|$)|[:\x00-\x1f]') { continue }
        try { $file = [IO.Path]::GetFullPath($rootPrefix + $relative.Replace('/','\')) } catch { continue }
        if (-not $file.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($file)) { continue }
        $indexedId = [string]$row.library_id
        if (-not $indexedId) { $indexedId = Get-MusicServerLocalIdentity -File $file }
        if ($indexedId -ne $Id) { continue }
        try { return (Resolve-MusicServerLibraryRelativePath -Config $Config -RelativePath $relative -MustExist) } catch { return $null }
    }
    return $null
}

function Sync-MusicServerLibraryIndex {
    param($Config, [AllowEmptyCollection()][object[]]$Items = @())
    if (-not [IO.Directory]::Exists($Config.MusicDir)) { throw 'LIBRARY_UNAVAILABLE' }
    $existing = Get-MusicServerLibraryIndex -Config $Config
    $rootKey = Get-MusicServerLibraryRootKey -Config $Config
    $rootPrefix = [IO.Path]::GetFullPath([string]$Config.MusicDir).TrimEnd('\','/') + '\'
    $rootLiteral = ConvertTo-MusicServerLibraryTextLiteral -Text $rootKey
    [long]$maximum = 0
    foreach ($row in $existing.Values) { $maximum = [Math]::Max($maximum,[long]$row.import_order) }
    $freshRoot = ($existing.Count -eq 0)
    $ordered = @($Items | Sort-Object @{Expression={[string](Get-OptionalProperty $_ 'addedto' '')}}, @{Expression={[string](Get-OptionalProperty $_ 'path' (Get-OptionalProperty $_ 'file' ''))}})
    $statements = New-Object 'Collections.Generic.List[string]'
    $decorated = @{}
    $now = Get-NowIso
    foreach ($item in $ordered) {
        $path = [string](Get-OptionalProperty $item 'path' (Get-OptionalProperty $item 'file' ''))
        if (-not $path) { continue }
        try { $full = [IO.Path]::GetFullPath($path) } catch { continue }
        if (-not $full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $full.Substring($rootPrefix.Length).Replace('\','/')
        $key = $relative.ToLowerInvariant()
        $info = [IO.FileInfo]::new($full)
        if (-not $info.Exists -or (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { continue }
        $old = if ($existing.ContainsKey($key)) { $existing[$key] } else { $null }
        $copy = $item.PSObject.Copy()
        $source = ''
        if ($old -and [string]$old.metadata_source -eq 'manifest') {
            $source = 'manifest'
            $restored = [string]$old.metadata_json | ConvertFrom-Json
            foreach ($property in $restored.PSObject.Properties) {
                if ($copy.PSObject.Properties[$property.Name]) { $copy.PSObject.Properties[$property.Name].Value = $property.Value }
                else { $copy.PSObject.Properties.Add([psnoteproperty]::new($property.Name,$property.Value)) }
            }
        }
        $sequence = if ($old) { [long]$old.import_order } else { $maximum++; $maximum }
        $imported = if ($old) { [string]$old.imported_at } elseif ($freshRoot -and (Get-OptionalProperty $item 'addedto' '')) { [string](Get-OptionalProperty $item 'addedto' '') } else { $now }
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($imported,[ref]$parsed)) { $imported = $now }
        else { $imported = $parsed.ToUniversalTime().ToString('o') }
        $values = @{library_id=([string](Get-OptionalProperty $item 'id' (Get-OptionalProperty $item 'library_id' '')));library_relative_path=$relative;import_order=$sequence;imported_at=$imported;addedto=$imported;collectionat=$imported}
        foreach ($field in $values.Keys) {
            if ($copy.PSObject.Properties[$field]) { $copy.PSObject.Properties[$field].Value = $values[$field] }
            else { $copy.PSObject.Properties.Add([psnoteproperty]::new($field,$values[$field])) }
        }
        $metadata = ConvertTo-Json -InputObject (ConvertTo-MusicServerLibraryMetadata -Item $copy) -Depth 4 -Compress
        $modified = $info.LastWriteTimeUtc.ToString('o')
        if (-not $old -or [long]$old.size -ne $info.Length -or [string]$old.modified_at -ne $modified -or [string]$old.metadata_json -ne $metadata) {
            $pathLiteral = ConvertTo-MusicServerLibraryTextLiteral -Text $key
            $importedLiteral = ConvertTo-MusicServerLibraryTextLiteral -Text $imported
            $modifiedLiteral = ConvertTo-MusicServerLibraryTextLiteral -Text $modified
            $metadataLiteral = ConvertTo-MusicServerLibraryTextLiteral -Text $metadata
            $sourceLiteral = ConvertTo-MusicServerLibraryTextLiteral -Text $source
            # MAX is evaluated after BEGIN IMMEDIATE, so independent scanners
            # cannot allocate the same append order from stale read snapshots.
            # A manifest committed while this scan ran owns all portable fields;
            # update only the current device's playback ID and path spelling.
            $statements.Add("INSERT INTO library_tracks(root_key,relative_path,import_order,imported_at,size,modified_at,metadata_json,metadata_source) VALUES($rootLiteral,$pathLiteral,(SELECT COALESCE(MAX(import_order),0)+1 FROM library_tracks WHERE root_key=$rootLiteral),$importedLiteral,$($info.Length),$modifiedLiteral,$metadataLiteral,$sourceLiteral) ON CONFLICT(root_key,relative_path) DO UPDATE SET size=excluded.size,modified_at=excluded.modified_at,metadata_json=CASE WHEN library_tracks.metadata_source='manifest' THEN json_set(library_tracks.metadata_json,'$.library_id',json_extract(excluded.metadata_json,'$.library_id'),'$.library_relative_path',json_extract(excluded.metadata_json,'$.library_relative_path')) ELSE excluded.metadata_json END;")
        }
        $decorated[$path.ToLowerInvariant()] = $copy
    }
    if ($statements.Count) {
        # Return the committed order and portable metadata, including changes
        # made by an import after the initial bulk read. The query shares the
        # write process; unchanged scans still use just their original read.
        $committed = @{}
        foreach ($row in @(Invoke-MusicServerSqlJson -Query ("BEGIN IMMEDIATE;`n" + ($statements -join "`n") + "`nSELECT t.relative_path,t.import_order,t.imported_at,t.metadata_json,t.metadata_source,c.id AS canonical_id,c.artist AS canonical_artist,c.album AS canonical_album,c.duration AS canonical_duration,c.release_year AS canonical_year FROM library_tracks t LEFT JOIN canonical_tracks c ON c.id=json_extract(t.metadata_json,'`$.canonical_track_id') WHERE t.root_key=$rootLiteral;`nCOMMIT;"))) {
            if ($row.canonical_id) {
                $metadata = ConvertTo-MusicServerLibraryMetadata -Item ([string]$row.metadata_json | ConvertFrom-Json)
                $canonical = [pscustomobject]@{id=[string]$row.canonical_id;artist=[string]$row.canonical_artist;album=[string]$row.canonical_album;duration=[int]$row.canonical_duration;release_year=[int]$row.canonical_year}
                $row.metadata_json = ConvertTo-Json -InputObject (Merge-MusicServerLibraryCanonicalMetadata -Metadata $metadata -Canonical $canonical) -Depth 4 -Compress
            }
            $committed[[string]$row.relative_path] = $row
        }
        foreach ($copy in $decorated.Values) {
            $relativeKey = ([string]$copy.library_relative_path).ToLowerInvariant()
            if (-not $committed.ContainsKey($relativeKey)) { continue }
            $row = $committed[$relativeKey]
            if ([string]$row.metadata_source -eq 'manifest') {
                foreach ($property in (([string]$row.metadata_json | ConvertFrom-Json).PSObject.Properties)) {
                    if ($copy.PSObject.Properties[$property.Name]) { $copy.PSObject.Properties[$property.Name].Value = $property.Value }
                    else { $copy.PSObject.Properties.Add([psnoteproperty]::new($property.Name,$property.Value)) }
                }
            }
            $copy.import_order = [long]$row.import_order
            $copy.imported_at = [string]$row.imported_at
            $copy.addedto = [string]$row.imported_at
            $copy.collectionat = [string]$row.imported_at
            $copy.library_id = [string](Get-OptionalProperty $copy 'id' (Get-OptionalProperty $copy 'library_id' ''))
        }
    }
    foreach ($item in @($Items)) {
        $key = ([string](Get-OptionalProperty $item 'path' (Get-OptionalProperty $item 'file' ''))).ToLowerInvariant()
        if ($decorated.ContainsKey($key)) { $decorated[$key] } else { $item }
    }
}

function Get-MusicServerLibraryStreamHash {
    param([IO.Stream]$InputStream, [IO.Stream]$OutputStream = $null, [Diagnostics.Stopwatch]$Clock)
    $hash = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] 1048576
    try {
        while (($read = $InputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($Clock -and $Clock.Elapsed.TotalSeconds -gt 600) { throw 'LIBRARY_TRANSFER_TIMEOUT' }
            [void]$hash.TransformBlock($buffer,0,$read,$buffer,0)
            if ($OutputStream) { $OutputStream.Write($buffer,0,$read) }
        }
        [void]$hash.TransformFinalBlock((New-Object byte[] 0),0,0)
        return ([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Get-MusicServerPortableIdentity {
    param($Canonical, [hashtable]$Preferences)
    if (-not $Canonical) { return $null }
    $identifiers = @()
    foreach ($id in @(ConvertFrom-MusicServerJsonArray -Json ([string](Get-OptionalProperty $Canonical 'identifiers_json' '[]')))) {
        $provider = [string](Get-OptionalProperty $id 'type' '')
        $value = [string](Get-OptionalProperty $id 'value' '')
        if (($provider -eq 'netease' -and $value -match '^\d{1,20}$') -or ($provider -eq 'bilibili' -and $value -match '^BV[0-9A-Za-z]{10}$')) { $identifiers += [pscustomobject]@{type=$provider;value=$value} }
    }
    $canonicalId = [string](Get-OptionalProperty $Canonical 'id' '')
    if ($canonicalId -notmatch '^[a-zA-Z0-9:_-]{1,160}$') { return $null }
    return [pscustomobject]@{id=$canonicalId;title=[string](Get-OptionalProperty $Canonical 'title' '');artist=[string](Get-OptionalProperty $Canonical 'artist' '');album=[string](Get-OptionalProperty $Canonical 'album' '');duration=[int](Get-OptionalProperty $Canonical 'duration' 0);release_year=[int](Get-OptionalProperty $Canonical 'release_year' 0);identifiers=@($identifiers);liked=($Preferences.ContainsKey($canonicalId) -and $Preferences[$canonicalId] -eq 'LIKE')}
}

function Export-MusicServerLibrary {
    param($Config, [string]$DestinationPath = '', [scriptblock]$Progress = {}, [string]$JobId = '')
    if ($JobId -and $JobId -notmatch '^[a-fA-F0-9]{32}$') { throw 'INVALID_LIBRARY_EXPORT_JOB' }
    $files = @(Get-MusicServerLibraryAudioFiles -Config $Config)
    if (-not $DestinationPath) {
        [IO.Directory]::CreateDirectory($Config.OutputDir) | Out-Null
        $DestinationPath = Join-Path $Config.OutputDir ('MusicServer-library-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6) + '.zip')
    }
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if ($JobId -and -not [string]::Equals([IO.Path]::GetDirectoryName($destination),[IO.Path]::GetFullPath([string]$Config.OutputDir).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)) { throw 'INVALID_LIBRARY_EXPORT_JOB_DESTINATION' }
    if ([IO.File]::Exists($destination)) { throw 'LIBRARY_EXPORT_EXISTS' }
    $root = [IO.Path]::GetFullPath([string]$Config.MusicDir).TrimEnd('\','/')
    if ($destination.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'LIBRARY_EXPORT_INSIDE_LIBRARY' }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($destination))) { throw 'LIBRARY_EXPORT_DIRECTORY_MISSING' }
    $index = Get-MusicServerLibraryIndex -Config $Config
    $syncItems = foreach ($file in $files) {
        $relative = (Get-MusicServerLibraryRelativePath -Config $Config -Path $file.FullName).ToLowerInvariant()
        $row = if ($index.ContainsKey($relative)) { $index[$relative] } else { $null }
        $item = if ($row) { [string]$row.metadata_json | ConvertFrom-Json } else { [pscustomobject]@{title=$file.BaseName;artist='';album='';addedto=$file.LastWriteTimeUtc.ToString('o')} }
        $item | Add-Member -NotePropertyName path -NotePropertyValue $file.FullName -Force
        if ($row) { $item | Add-Member -NotePropertyName addedto -NotePropertyValue ([string]$row.imported_at) -Force }
        $item
    }
    Sync-MusicServerLibraryIndex -Config $Config -Items @($syncItems) | Out-Null
    $index = Get-MusicServerLibraryIndex -Config $Config
    $canonical = @{}; $preferences = @{}
    $canonical = Get-CanonicalLocalTrackMapDb -MusicDir $Config.MusicDir
    $preferences = Get-TrackPreferenceMapDb
    $records = New-Object 'Collections.Generic.List[object]'
    $included = @{}
    $part = if ($JobId) {
        [IO.Directory]::CreateDirectory($Config.OutputDir) | Out-Null
        Join-Path $Config.OutputDir ('.musicserver-library-export-'+$JobId+'.part')
    } else { $destination + '.' + [Guid]::NewGuid().ToString('N') + '.part' }
    if ([IO.File]::Exists($part)) { throw 'LIBRARY_EXPORT_STAGE_EXISTS' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::Open($part,[IO.Compression.ZipArchiveMode]::Create)
        $done = 0
        foreach ($file in $files) {
            $relative = Get-MusicServerLibraryRelativePath -Config $Config -Path $file.FullName
            $row = $index[$relative.ToLowerInvariant()]
            $inputStream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $exportedSize = $inputStream.Length
            $outputStream = $zip.CreateEntry($relative,[IO.Compression.CompressionLevel]::NoCompression).Open()
            try { $sha256 = Get-MusicServerLibraryStreamHash -InputStream $inputStream -OutputStream $outputStream -Clock $clock } finally { $outputStream.Dispose(); $inputStream.Dispose() }
            $included[$relative.ToLowerInvariant()] = $true
            $identity = $null
            $display = [string]$row.metadata_json | ConvertFrom-Json
            $libraryId = [string](Get-OptionalProperty $display 'library_id' '')
            foreach ($binding in @(('file:'+$file.FullName),$file.FullName,$libraryId,($libraryId -replace '^library-',''))) {
                if ($canonical.ContainsKey($binding) -and $canonical[$binding]) { $identity = Get-MusicServerPortableIdentity -Canonical $canonical[$binding] -Preferences $preferences; break }
            }
            $records.Add([pscustomobject]@{relative_path=$relative;size=$exportedSize;sha256=$sha256;import_order=[long]$row.import_order;imported_at=[string]$row.imported_at;metadata=(ConvertTo-MusicServerLibraryMetadata -Item $display -Portable);identity=$identity})
            foreach ($candidate in @([IO.Path]::ChangeExtension($file.FullName,'.lrc'),(Join-Path $file.DirectoryName ('Lyrics\'+$file.BaseName+'.lrc')),(Join-Path $file.DirectoryName ('歌词\'+$file.BaseName+'.lrc')))) {
                if (-not [IO.File]::Exists($candidate)) { continue }
                $lyricRelative = Get-MusicServerLibraryRelativePath -Config $Config -Path $candidate
                if ($included.ContainsKey($lyricRelative.ToLowerInvariant())) { continue }
                $inputStream = [IO.File]::OpenRead($candidate); $outputStream = $zip.CreateEntry($lyricRelative,[IO.Compression.CompressionLevel]::Optimal).Open()
                try { Get-MusicServerLibraryStreamHash -InputStream $inputStream -OutputStream $outputStream -Clock $clock | Out-Null } finally { $outputStream.Dispose(); $inputStream.Dispose() }
                $included[$lyricRelative.ToLowerInvariant()] = $true
            }
            $done++; & $Progress ([int](95*$done/[Math]::Max(1,$files.Count)))
        }
        $manifest = [ordered]@{schema=1;format='MusicServerPortableLibrary';created_at=(Get-NowIso);tracks=@($records.ToArray())}
        $writer = New-Object IO.StreamWriter($zip.CreateEntry('.musicserver-library.json',[IO.Compression.CompressionLevel]::Optimal).Open(), (New-Object Text.UTF8Encoding($false)))
        try { $writer.Write((ConvertTo-Json -InputObject $manifest -Depth 12 -Compress)) } finally { $writer.Dispose() }
        $zip.Dispose(); $zip = $null
        [IO.File]::Move($part,$destination)
        & $Progress 100
        Write-MusicServerLog -Path (Join-Path $Config.LogDir 'library.log') -Message ('[library] phase=export result=READY count='+$files.Count+' duration_ms='+[int]$clock.Elapsed.TotalMilliseconds)
        return $destination
    } finally { if ($zip) { $zip.Dispose() }; if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) } }
}

function Import-MusicServerLibraryManifest {
    param($Config, [scriptblock]$Progress = {})
    if (-not [IO.Directory]::Exists($Config.MusicDir)) { throw 'LIBRARY_UNAVAILABLE' }
    $manifestPath = Join-Path $Config.MusicDir '.musicserver-library.json'
    if (-not [IO.File]::Exists($manifestPath)) { return [pscustomobject]@{imported=0;already_imported=$false;manifest=$false} }
    Resolve-MusicServerLibraryRelativePath -Config $Config -RelativePath '.musicserver-library.json' -MustExist | Out-Null
    if ((New-Object IO.FileInfo($manifestPath)).Length -gt 33554432) { throw 'LIBRARY_MANIFEST_TOO_LARGE' }
    Initialize-MusicServerLibrarySchema
    $manifestStream = [IO.File]::OpenRead($manifestPath)
    try { $manifestHash = Get-MusicServerLibraryStreamHash -InputStream $manifestStream } finally { $manifestStream.Dispose() }
    $rootKey = Get-MusicServerLibraryRootKey -Config $Config
    $marker = @(Invoke-MusicServerParamSql -Template 'SELECT 1 FROM library_imports WHERE root_key=@root AND manifest_hash=@hash;' -Params @{root=$rootKey;hash=$manifestHash})
    if ($marker.Count) { return [pscustomobject]@{imported=0;already_imported=$true;manifest=$true} }
    try { $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json } catch { throw 'INVALID_LIBRARY_MANIFEST' }
    if ([int](Get-OptionalProperty $manifest 'schema' 0) -ne 1) { throw 'UNSUPPORTED_LIBRARY_MANIFEST' }
    $tracks = @(Get-OptionalProperty $manifest 'tracks' @())
    if ($tracks.Count -gt 25000) { throw 'LIBRARY_TRACK_LIMIT' }
    $paths = @{}; $sequences = @{}; $validated = New-Object 'Collections.Generic.List[object]'
    $clock = [Diagnostics.Stopwatch]::StartNew(); $done = 0
    foreach ($track in $tracks) {
        $relative = [string](Get-OptionalProperty $track 'relative_path' '')
        $file = Resolve-MusicServerLibraryRelativePath -Config $Config -RelativePath $relative -MustExist
        $key = $relative.Replace('\','/').ToLowerInvariant()
        [long]$sequence = 0; [long]$size = 0
        $date = [DateTimeOffset]::MinValue
        if ([IO.Path]::GetExtension($file).ToLowerInvariant() -notin $script:LibraryAudioExtensions -or $paths.ContainsKey($key) -or -not [long]::TryParse([string](Get-OptionalProperty $track 'import_order' ''),[ref]$sequence) -or $sequence -lt 1 -or $sequences.ContainsKey($sequence) -or -not [long]::TryParse([string](Get-OptionalProperty $track 'size' ''),[ref]$size) -or $size -lt 0 -or -not [DateTimeOffset]::TryParse([string](Get-OptionalProperty $track 'imported_at' ''),[ref]$date)) { throw 'INVALID_LIBRARY_MANIFEST' }
        $paths[$key] = $true; $sequences[$sequence] = $true
        $hash = [string](Get-OptionalProperty $track 'sha256' '')
        if ($hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'INVALID_LIBRARY_MANIFEST' }
        $info = New-Object IO.FileInfo($file)
        if ($size -ne $info.Length) { throw 'LIBRARY_CONTENT_MISMATCH' }
        $stream = [IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { $actual = Get-MusicServerLibraryStreamHash -InputStream $stream -Clock $clock } finally { $stream.Dispose() }
        if ($actual -ne $hash.ToLowerInvariant()) { throw 'LIBRARY_CONTENT_MISMATCH' }
        $metadata = ConvertTo-MusicServerLibraryMetadata -Item (Get-OptionalProperty $track 'metadata' $null)
        $metadata.PSObject.Properties.Add([psnoteproperty]::new('library_relative_path',$relative.Replace('\','/')))
        $validated.Add([pscustomobject]@{key=$key;file=$file;size=$size;sequence=$sequence;date=$date.ToUniversalTime().ToString('o');modified=$info.LastWriteTimeUtc.ToString('o');metadata=(ConvertTo-Json -InputObject $metadata -Compress -Depth 4);identity=(Get-OptionalProperty $track 'identity' $null)})
        $done++; & $Progress ([int](85*$done/[Math]::Max(1,$tracks.Count)))
    }
    # Validation is all-or-nothing. A bad/missing recording cannot leave partial
    # order, artist, preference or download state behind.
    $sql = New-Object 'Collections.Generic.List[string]'
    $now = Get-NowIso
    [long]$maxImported = 0
    foreach ($row in $validated) { $maxImported = [Math]::Max($maxImported,[long]$row.sequence) }
    $sql.Add('CREATE TEMP TABLE imported_library_paths(relative_path TEXT PRIMARY KEY);')
    foreach ($path in $paths.Keys) {
        $sql.Add((Expand-MusicServerSqlTemplate -Template 'INSERT INTO imported_library_paths(relative_path) VALUES(@path);' -Params @{path=[string]$path}))
    }
    # Include every extra row visible after acquiring the write lock, including
    # songs indexed while manifest validation was hashing the recordings.
    $sql.Add((Expand-MusicServerSqlTemplate -Template @'
CREATE TEMP TABLE imported_library_extra_order AS
 SELECT relative_path,@maximum+ROW_NUMBER() OVER(ORDER BY import_order,relative_path) AS sequence
 FROM library_tracks WHERE root_key=@root AND relative_path NOT IN(SELECT relative_path FROM imported_library_paths);
UPDATE library_tracks SET import_order=(SELECT sequence FROM imported_library_extra_order e WHERE e.relative_path=library_tracks.relative_path)
 WHERE root_key=@root AND relative_path IN(SELECT relative_path FROM imported_library_extra_order);
DROP TABLE imported_library_extra_order;
DROP TABLE imported_library_paths;
'@ -Params @{root=$rootKey;maximum=$maxImported}))
    foreach ($row in $validated) {
        $sql.Add((Expand-MusicServerSqlTemplate -Template @'
INSERT INTO library_tracks(root_key,relative_path,import_order,imported_at,size,modified_at,metadata_json,metadata_source)
VALUES(@root,@path,@seq,@date,@size,@modified,@metadata,'manifest')
ON CONFLICT(root_key,relative_path) DO UPDATE SET import_order=excluded.import_order,imported_at=excluded.imported_at,size=excluded.size,modified_at=excluded.modified_at,metadata_json=excluded.metadata_json,metadata_source='manifest';
'@ -Params @{root=$rootKey;path=$row.key;seq=$row.sequence;date=$row.date;size=$row.size;modified=$row.modified;metadata=$row.metadata}))
        $identity = $row.identity
        if ($identity) {
            $id = [string](Get-OptionalProperty $identity 'id' '')
            if ($id -notmatch '^[a-zA-Z0-9:_-]{1,160}$') { throw 'INVALID_LIBRARY_IDENTITY' }
            $checked = Get-MusicServerPortableIdentity -Canonical ([pscustomobject]@{id=$id;title=(Get-OptionalProperty $identity 'title' '');artist=(Get-OptionalProperty $identity 'artist' '');album=(Get-OptionalProperty $identity 'album' '');duration=(Get-OptionalProperty $identity 'duration' 0);release_year=(Get-OptionalProperty $identity 'release_year' 0);identifiers_json=(ConvertTo-MusicServerJsonArrayText -Items (Get-OptionalProperty $identity 'identifiers' @()))}) -Preferences @{}
            $sql.Add((Expand-MusicServerSqlTemplate -Template @'
INSERT INTO canonical_tracks(id,title,artist,album,duration,release_year,identifiers_json,local_song_id,status,created_at,updated_at,revision)
SELECT @id,@title,@artist,@album,@duration,@year,@ids,@local,'LOCAL',@now,@now,1
WHERE NOT EXISTS(SELECT 1 FROM wanted_queue WHERE track_id=@id AND state IN ('RESOLVING','DOWNLOADING','VALIDATING') AND COALESCE(lease_expires_epoch,CAST(strftime('%s',lease_expires_at) AS INTEGER),0)>@epoch)
ON CONFLICT(id) DO UPDATE SET local_song_id=excluded.local_song_id,status='LOCAL',updated_at=excluded.updated_at,revision=canonical_tracks.revision+1
WHERE NOT EXISTS(SELECT 1 FROM wanted_queue WHERE track_id=@id AND state IN ('RESOLVING','DOWNLOADING','VALIDATING') AND COALESCE(lease_expires_epoch,CAST(strftime('%s',lease_expires_at) AS INTEGER),0)>@epoch);
'@ -Params @{id=$id;title=$checked.title;artist=$checked.artist;album=$checked.album;duration=$checked.duration;year=$checked.release_year;ids=(ConvertTo-MusicServerJsonArrayText -Items $checked.identifiers);local=('file:'+$row.file);now=$now;epoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}))
            $metadata = ConvertTo-MusicServerLibraryMetadata -Item ([string]$row.metadata | ConvertFrom-Json)
            $metadata = Merge-MusicServerLibraryCanonicalMetadata -Metadata $metadata -Canonical $checked
            $sql.Add((Expand-MusicServerSqlTemplate -Template 'UPDATE library_tracks SET metadata_json=@metadata WHERE root_key=@root AND relative_path=@path;' -Params @{root=$rootKey;path=$row.key;metadata=(ConvertTo-Json -InputObject $metadata -Depth 4 -Compress)}))
            if ((Get-OptionalProperty $identity 'liked' $false) -eq $true) {
                $sql.Add((Expand-MusicServerSqlTemplate -Template "INSERT INTO recommendation_feedback(track_id,feedback_type,source,value,created_at) VALUES(@id,'LIKE','library_import','true',@now);" -Params @{id=$id;now=$now}))
            }
        }
    }
    $sql.Add((Expand-MusicServerSqlTemplate -Template 'INSERT INTO library_imports(root_key,manifest_hash,imported_at) VALUES(@root,@hash,@now);' -Params @{root=$rootKey;hash=$manifestHash;now=$now}))
    $pending = [ordered]@{revision=[Guid]::NewGuid().ToString('N');path_key=(Get-MusicServerPathKey -Path ([string]$Config.MusicDir))}
    $pendingJson = ConvertTo-Json -InputObject $pending -Compress
    $envMusic = [string]$env:MUSICSERVER_MUSIC_DIR
    $hasEnvMusic = -not [string]::IsNullOrWhiteSpace($envMusic)
    $configuredRaw = [string](Get-AppSettingDb -Key 'music_library_path')
    $configuredMusic = if ($hasEnvMusic) { $envMusic } elseif ($configuredRaw) { $configuredRaw } else { Get-DefaultMusicDir -AppHome $Config.AppHome }
    $activeScope = [string]::Equals((Get-MusicServerPathKey -Path $configuredMusic).TrimEnd('\','/'),([string]$pending.path_key).TrimEnd('\','/'),[StringComparison]::Ordinal)
    # Compare the normalized scope in PowerShell, then guard its raw setting
    # snapshot inside this transaction. A folder switch during validation or
    # before the write lock cannot let an inactive import supersede the current
    # recommendation revision, even if that newer revision was already cleared.
    $scopePredicate = @'
@active=1 AND (@environment=1 OR COALESCE((SELECT value FROM app_settings WHERE key='music_library_path'),'')=@configured)
 AND NOT EXISTS(SELECT 1 FROM app_settings WHERE key='recommendation_library_pending' AND value<>''
  AND CASE WHEN json_valid(value) THEN COALESCE(json_extract(value,'$.path_key'),'') ELSE '' END NOT IN('',@scope))
'@
    $scopeParams = @{active=$activeScope;environment=$hasEnvMusic;configured=$configuredRaw;scope=[string]$pending.path_key}
    # An obsolete import must not mutate global recording bindings or likes.
    # Check before every data write, under the same lock as the import. No
    # receipt is recorded on scope failure, allowing a later explicit selection
    # of this library to retry its untouched migration input.
    $guard = "CREATE TEMP TABLE library_import_scope_guard(enabled INTEGER CONSTRAINT musicserver_active_library_import CHECK(enabled=1));`nINSERT INTO library_import_scope_guard(enabled) SELECT CASE WHEN $scopePredicate THEN 1 ELSE 0 END;`nDROP TABLE library_import_scope_guard;"
    $sql.Insert(0,(Expand-MusicServerSqlTemplate -Template $guard -Params $scopeParams))
    $sql.Add((Expand-MusicServerSqlTemplate -Template @'
INSERT INTO app_settings(key,value,updated_at)
SELECT 'recommendation_library_pending',@pending,@now
WHERE @active=1 AND (@environment=1 OR COALESCE((SELECT value FROM app_settings WHERE key='music_library_path'),'')=@configured)
 AND NOT EXISTS(SELECT 1 FROM app_settings WHERE key='recommendation_library_pending' AND value<>''
  AND CASE WHEN json_valid(value) THEN COALESCE(json_extract(value,'$.path_key'),'') ELSE '' END NOT IN('',@scope))
ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at;
'@ -Params @{pending=$pendingJson;now=$now;active=$activeScope;environment=$hasEnvMusic;configured=$configuredRaw;scope=[string]$pending.path_key}))
    try { Invoke-MusicServerSqlNonQuery -Query ("BEGIN IMMEDIATE;`n" + ($sql -join "`n") + "`nCOMMIT;") } catch {
        if ($_.Exception.Message -match '(?m)CHECK constraint failed: musicserver_active_library_import(?: \(\d+\))?\r?$') { throw 'LIBRARY_CHANGED' }
        throw
    }
    $recommendationRevision = if ([string](Get-AppSettingDb -Key 'recommendation_library_pending') -eq $pendingJson) { [string]$pending.revision } else { '' }
    & $Progress 100
    Write-MusicServerLog -Path (Join-Path $Config.LogDir 'library.log') -Message ('[library] phase=import result=READY count='+$validated.Count+' duration_ms='+[int]$clock.Elapsed.TotalMilliseconds)
    return [pscustomobject]@{imported=$validated.Count;already_imported=$false;manifest=$true;recommendation_revision=$recommendationRevision}
}

Export-ModuleMember -Function *
