Set-StrictMode -Version 3.0

# MusicServer.Database.psm1 - SQLite data access layer
# Provides safe typed SQL-template expansion, transactions, and connection management.
# sqlite3.exe does not expose native parameter binding across one-shot CLI processes,
# so templates are expanded exactly once with SQL literals before execution.

$script:DbPath = $null
$script:SqliteExe = $null
$script:InTransaction = $false
$script:SqliteInvocationCount = [long]0

function Get-MusicServerSqliteInvocationCount {
    # Counts this module's state DB CLI processes, not Navidrome reads.
    return $script:SqliteInvocationCount
}

function ConvertTo-MusicServerSqlLiteral {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [DBNull]) { return 'NULL' }
    if ($Value -is [bool]) { if ([bool]$Value) { return '1' } else { return '0' } }

    $integerTypes = @(
        [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64]
    )
    foreach ($type in $integerTypes) {
        if ($Value -is $type) {
            return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
    }

    if ($Value -is [single] -or $Value -is [double]) {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            throw 'SQLite numeric parameters cannot be NaN or Infinity.'
        }
        return $number.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [decimal]) {
        return ([decimal]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [DateTimeOffset]) {
        $text = ([DateTimeOffset]$Value).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    } elseif ($Value -is [DateTime]) {
        $date = [DateTime]$Value
        if ($date.Kind -eq [DateTimeKind]::Unspecified) {
            $date = [DateTime]::SpecifyKind($date, [DateTimeKind]::Utc)
        } else {
            $date = $date.ToUniversalTime()
        }
        $text = $date.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    } else {
        $text = [string]$Value
    }

    # Encode text as UTF-8 bytes instead of embedding a quoted SQL string.
    # This preserves CRLF and every quote/token character through sqlite3 .read.
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $hex = -join @($bytes | ForEach-Object { $_.ToString('x2', [Globalization.CultureInfo]::InvariantCulture) })
    return "CAST(X'$hex' AS TEXT)"
}

function Test-MusicServerSqlParameterStart {
    param([char]$Character)
    return ($Character -eq '_' -or [char]::IsLetter($Character))
}

function Test-MusicServerSqlParameterPart {
    param([char]$Character)
    return ($Character -eq '_' -or [char]::IsLetterOrDigit($Character))
}

function ConvertTo-MusicServerSqlText {
    param(
        [Parameter(Mandatory)][string]$Template,
        [hashtable]$Params,
        [switch]$SeparateStatements
    )

    $builder = New-Object Text.StringBuilder
    $length = $Template.Length
    $index = 0
    while ($index -lt $length) {
        $character = $Template[$index]

        # CLI commands occupy a whole line and do not use SQL quoting rules.
        if ($SeparateStatements -and $character -eq '.' -and ($index -eq 0 -or $Template[$index - 1] -eq "`n")) {
            while ($index -lt $length) {
                $commandCharacter = $Template[$index]
                [void]$builder.Append($commandCharacter)
                $index++
                if ($commandCharacter -eq "`n") { break }
            }
            continue
        }

        # Preserve SQL strings and quoted identifiers verbatim. Parameter-looking
        # text inside them is data in the template, not a binding token.
        if ($character -eq "'" -or $character -eq '"' -or $character -eq '`') {
            $quote = $character
            [void]$builder.Append($character)
            $index++
            while ($index -lt $length) {
                $quoted = $Template[$index]
                [void]$builder.Append($quoted)
                $index++
                if ($quoted -eq $quote) {
                    if ($index -lt $length -and $Template[$index] -eq $quote) {
                        [void]$builder.Append($Template[$index])
                        $index++
                        continue
                    }
                    break
                }
            }
            continue
        }
        if ($character -eq '[') {
            [void]$builder.Append($character)
            $index++
            while ($index -lt $length) {
                $quoted = $Template[$index]
                [void]$builder.Append($quoted)
                $index++
                if ($quoted -eq ']') {
                    if ($index -lt $length -and $Template[$index] -eq ']') {
                        [void]$builder.Append($Template[$index])
                        $index++
                        continue
                    }
                    break
                }
            }
            continue
        }

        # Preserve line and block comments verbatim for the same reason.
        if ($character -eq '-' -and $index + 1 -lt $length -and $Template[$index + 1] -eq '-') {
            while ($index -lt $length) {
                $comment = $Template[$index]
                [void]$builder.Append($comment)
                $index++
                if ($comment -eq "`n") { break }
            }
            continue
        }
        if ($character -eq '/' -and $index + 1 -lt $length -and $Template[$index + 1] -eq '*') {
            [void]$builder.Append('/*')
            $index += 2
            while ($index -lt $length) {
                if ($Template[$index] -eq '*' -and $index + 1 -lt $length -and $Template[$index + 1] -eq '/') {
                    [void]$builder.Append('*/')
                    $index += 2
                    break
                }
                [void]$builder.Append($Template[$index])
                $index++
            }
            continue
        }

        if ($null -ne $Params -and $character -eq '@' -and $index + 1 -lt $length -and (Test-MusicServerSqlParameterStart $Template[$index + 1])) {
            $nameStart = $index + 1
            $end = $nameStart + 1
            while ($end -lt $length -and (Test-MusicServerSqlParameterPart $Template[$end])) { $end++ }
            $name = $Template.Substring($nameStart, $end - $nameStart)
            if (-not $Params.ContainsKey($name)) {
                throw "SQL template parameter @$name has no supplied value."
            }
            [void]$builder.Append((ConvertTo-MusicServerSqlLiteral $Params[$name]))
            $index = $end
            continue
        }

        [void]$builder.Append($character)
        if ($SeparateStatements -and $character -eq ';') {
            [void]$builder.Append("`n")
        }
        $index++
    }
    return $builder.ToString()
}

function Expand-MusicServerSqlTemplate {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Params
    )
    return ConvertTo-MusicServerSqlText -Template $Template -Params $Params
}

function ConvertFrom-MusicServerSqliteJson {
    param([Parameter(Mandatory)][string]$Json)
    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Json -DateKind String
    }
    return ConvertFrom-Json -InputObject $Json
}

function Test-MusicServerJsonCollection {
    <#
    .SYNOPSIS
      True when a value is a list of JSON items rather than a single item.

      A Hashtable is the trap this exists to avoid. It is IEnumerable, but
      PowerShell does not hand back its entries: enumerating a Hashtable (including
      each DictionaryEntry, which PowerShell hands back as a Hashtable again) yields
      THE HASHTABLE ITSELF. A flattener that treats any IEnumerable as a list
      therefore re-enqueues the same hashtable forever -- an infinite loop with no
      output and no error, measured as a hang in every caller of
      Save-CanonicalTrackDb.

      `-Identifiers` and `-PreviewSources` are routinely passed as
      `@(@{ provider = ...; preview_url = ... })`, so a dictionary must stay ONE
      item and be serialized as a JSON object. A PSCustomObject is not IEnumerable
      and needs no special case.
    #>
    param([AllowNull()]$Item)

    if ($null -eq $Item) { return $false }
    if ($Item -is [string]) { return $false }
    if ($Item -is [System.Collections.IDictionary]) { return $false }
    return ($Item -is [System.Collections.IEnumerable])
}

function Get-MusicServerFlatJsonItems {
    <#
    .SYNOPSIS
      Flattens whatever a JSON array column holds into the items it really means.

      Shared by the reader and the writer. Two historical shapes must survive it:
        * a nested array, from PowerShell 5.1's -InputObject array nesting;
        * a collection wrapper `{value:[...],Count:n}`, which is how ConvertTo-Json
          renders an ArrayList/List instead of a true array.
      A JSON null is not an item, so it is dropped: `New-CanonicalTrack` turned a
      missing -Identifiers into `@($null)` and stored `[null]` in the column, which
      the old reader's wrapper bug then hid from every test.
    #>
    param([AllowNull()]$Items)

    $flat = New-Object System.Collections.ArrayList
    $pending = New-Object System.Collections.Queue
    if ($null -ne $Items) { $pending.Enqueue($Items) }
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        if ($null -eq $item) { continue }
        if (Test-MusicServerJsonCollection -Item $item) {
            foreach ($inner in $item) { $pending.Enqueue($inner) }
            continue
        }
        # A collection wrapper carries the real items in `.value`; unwrap it, but only
        # when the object is not a legitimate item. Real items carry their own fields
        # (`type`/`value`), so the wrapper is identified by BOTH `value` (a list) and
        # `Count` -- the exact shape ConvertTo-Json gives an ArrayList/List.
        if (-not ($item -is [System.Collections.IDictionary]) -and -not $item.PSObject.Properties['type']) {
            $valueProperty = $item.PSObject.Properties['value']
            $countProperty = $item.PSObject.Properties['Count']
            if ($valueProperty -and $countProperty -and (Test-MusicServerJsonCollection -Item $valueProperty.Value)) {
                foreach ($inner in $valueProperty.Value) { $pending.Enqueue($inner) }
                continue
            }
        }
        [void]$flat.Add($item)
    }
    return @($flat.ToArray())
}

function ConvertFrom-MusicServerJsonArray {
    <#
    .SYNOPSIS
      Parses JSON text holding an array into a flat list of its items.

      PowerShell 5.1's ConvertFrom-Json does not hand back a JSON array
      consistently through -InputObject: for a one-item array it returns an array
      whose single element is the whole array again, so `@(ConvertFrom-Json ...)`
      yields a WRAPPER instead of the items. Scalar reads survived it only because
      PowerShell member enumeration silently unwraps a one-element array, which is
      why `identifiers_json` looked fine while `Get-NeteaseIdFromTrack` quietly
      returned '' for every track read back from the database -- and the same
      wrapper hit preview_sources_json and download_candidates_json.

      Wrapping the text in an object before parsing makes the shape determinate at
      every length, which guessing at the nesting cannot.
    #>
    param([AllowNull()]$Json)

    if ($null -eq $Json) { return @() }
    $text = [string]$Json
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $text = $text.Trim()
    # Array-only by contract. A bare object is not a list of items, and the wrapped
    # parse below could not tell the two apart (both expose a `.items` property), so
    # the shape is settled from the text rather than guessed after parsing.
    if (-not $text.StartsWith('[')) { return @() }
    $wrapped = $null
    try { $wrapped = ConvertFrom-MusicServerSqliteJson -Json "{`"items`":$text}" } catch { return @() }
    if ($null -eq $wrapped) { return @() }
    $items = $wrapped.PSObject.Properties['items']
    if (-not $items -or $null -eq $items.Value) { return @() }
    return @(Get-MusicServerFlatJsonItems -Items $items.Value)
}

function ConvertTo-MusicServerJsonArrayText {
    <#
    .SYNOPSIS
      Serializes items into JSON array text for a canonical JSON column.

      The counterpart of ConvertFrom-MusicServerJsonArray, so a column always holds a
      real array with no null holes. `@($null)` used to reach disk as `[null]`, which
      every array reader then had to defend against.
    #>
    param([AllowNull()]$Items)

    $flat = @(Get-MusicServerFlatJsonItems -Items $Items)
    if ($flat.Count -eq 0) { return '[]' }
    return ConvertTo-Json -InputObject @($flat) -Compress -Depth 10
}

function Invoke-MusicServerSqliteScript {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [switch]$Json
    )
    if (-not $script:DbPath) { throw 'Database not initialized. Call Initialize-MusicServerDatabase first.' }
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) "msdb_$([guid]::NewGuid().ToString('N')).sql"
    try {
        # Connection-local settings must precede any caller BEGIN statement.
        # Bail on the first SQL error so a later COMMIT cannot persist a partial
        # transaction; sqlite3 rolls back an open transaction when it exits.
        # SQLite 3.53.4 may execute all statements on a line before honoring
        # .bail. Separate unquoted terminators without changing strings or
        # comments. The CLI itself keeps CREATE TRIGGER bodies together until
        # END; completes the statement.
        $scriptText = ".bail on`nPRAGMA foreign_keys=ON;`n" + (ConvertTo-MusicServerSqlText -Template $Sql -SeparateStatements)
        [IO.File]::WriteAllText($tmpFile, $scriptText, (New-Object Text.UTF8Encoding($false)))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:SqliteExe
        $jsonArgument = if ($Json) { '-json ' } else { '' }
        # Every invocation is a fresh sqlite3 process, so a PRAGMA set during
        # Initialize-MusicServerDatabase does not survive here. `.timeout` must
        # ride along with every execution: without it, concurrent workers hit a
        # hard "database is locked" error instead of waiting for the other
        # writer to commit and then losing the claim race gracefully.
        $startInfo.Arguments = "-batch $jsonArgument`"$($script:DbPath)`" `".timeout 5000`" `".read $tmpFile`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        try { $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch {}
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $process.Start() | Out-Null
        $script:SqliteInvocationCount++
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $process.Dispose()
        if ($exitCode -ne 0) {
            throw "sqlite3 error (exit $exitCode): $stderr`nSQL: $Sql"
        }
        return [string]$stdout
    } finally {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

function Initialize-MusicServerDatabase {
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [string]$SqliteExe = 'sqlite3.exe'
    )
    $script:DbPath = $DbPath
    $script:SqliteExe = $SqliteExe
    $dir = [IO.Path]::GetDirectoryName($DbPath)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Invoke-MusicServerSqlNonQuery -Query 'PRAGMA journal_mode=WAL;'
    # foreign_keys and busy_timeout are applied on every invocation. Keep the
    # existing effective synchronous default (FULL); changing write durability
    # is a separate decision, not part of connection initialization.
    if (-not (Test-Path -LiteralPath $DbPath)) {
        [IO.File]::WriteAllBytes($DbPath, @())
    }
}

function Connect-MusicServerDatabase {
    <#
      Bind the database helpers to an existing database without changing it.
      This is intentionally separate from Initialize-MusicServerDatabase so
      read-only migration previews can inspect a pre-Phase-4 database.
    #>
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [string]$SqliteExe = 'sqlite3.exe'
    )
    if (-not (Test-Path -LiteralPath $DbPath -PathType Leaf)) {
        throw "Database does not exist: $DbPath"
    }
    $script:DbPath = [IO.Path]::GetFullPath($DbPath)
    $script:SqliteExe = $SqliteExe
}

function Get-MusicServerDbPath {
    return $script:DbPath
}

function Get-MusicServerSqliteExe {
    return $script:SqliteExe
}

function Invoke-MusicServerSqlNonQuery {
    param([Parameter(Mandatory)][string]$Query)
    Invoke-MusicServerSqliteScript -Sql $Query | Out-Null
}

function Invoke-MusicServerSqlJson {
    param([Parameter(Mandatory)][string]$Query)
    $stdout = Invoke-MusicServerSqliteScript -Sql $Query -Json
    if ([string]::IsNullOrWhiteSpace($stdout)) { return @() }
    $stdout = $stdout.Trim()
    if ($stdout -eq '[]') { return @() }
    # Flat rows at every length: a one-row result used to come back as a wrapper
    # array, which scalar reads hid but property lookups could not.
    return @(ConvertFrom-MusicServerJsonArray -Json $stdout)
}

function Invoke-MusicServerParamSql {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Params
    )
    $sql = Expand-MusicServerSqlTemplate -Template $Template -Params $Params
    return @(Invoke-MusicServerSqlJson -Query $sql)
}

function Invoke-MusicServerParamNonQuery {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Params,
        [switch]$ReturnChanges
    )
    $sql = Expand-MusicServerSqlTemplate -Template $Template -Params $Params
    if ($ReturnChanges) {
        $rows = @(Invoke-MusicServerSqlJson -Query ($sql + [Environment]::NewLine + 'SELECT changes() AS affected_rows;'))
        if ($rows.Count -eq 0) { return [long]0 }
        return [long]$rows[$rows.Count - 1].affected_rows
    }
    Invoke-MusicServerSqlNonQuery -Query $sql
}

function Invoke-MusicServerTransaction {
    param([Parameter(Mandatory)][scriptblock]$Action)
    if (-not $script:DbPath) { throw 'Database not initialized.' }
    if ($script:InTransaction) {
        return & $Action
    }
    $script:InTransaction = $true
    try {
        $result = & $Action
        return $result
    } finally {
        $script:InTransaction = $false
    }
}

function Get-SchemaVersion {
    $rows = @(Invoke-MusicServerSqlJson -Query 'PRAGMA user_version;')
    if ($rows.Count -gt 0) {
        $val = $rows[0]
        if ($val -is [pscustomobject]) {
            $props = @($val.PSObject.Properties | Where-Object { $_.Name -match 'user_version' })
            if ($props.Count -gt 0) { return [int]$props[0].Value }
        }
        return [int]$val
    }
    return 0
}

function Set-SchemaVersion {
    param([Parameter(Mandatory)][int]$Version)
    Invoke-MusicServerSqlNonQuery -Query "PRAGMA user_version=$Version;"
}

Export-ModuleMember -Function *
