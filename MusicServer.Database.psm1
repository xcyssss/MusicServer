Set-StrictMode -Version 3.0

# MusicServer.Database.psm1 - SQLite data access layer
# Provides safe typed SQL-template expansion, transactions, and connection management.
# sqlite3.exe does not expose native parameter binding across one-shot CLI processes,
# so templates are expanded exactly once with SQL literals before execution.

$script:DbPath = $null
$script:SqliteExe = $null
$script:InTransaction = $false

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

function Expand-MusicServerSqlTemplate {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Params
    )

    $builder = New-Object Text.StringBuilder
    $length = $Template.Length
    $index = 0
    while ($index -lt $length) {
        $character = $Template[$index]

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

        if ($character -eq '@' -and $index + 1 -lt $length -and (Test-MusicServerSqlParameterStart $Template[$index + 1])) {
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
        $index++
    }
    return $builder.ToString()
}

function ConvertFrom-MusicServerSqliteJson {
    param([Parameter(Mandatory)][string]$Json)
    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Json -DateKind String
    }
    return ConvertFrom-Json -InputObject $Json
}

function Invoke-MusicServerSqliteScript {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [switch]$Json
    )
    if (-not $script:DbPath) { throw 'Database not initialized. Call Initialize-MusicServerDatabase first.' }
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) "msdb_$([guid]::NewGuid().ToString('N')).sql"
    try {
        [IO.File]::WriteAllText($tmpFile, $Sql, (New-Object Text.UTF8Encoding($false)))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:SqliteExe
        $jsonArgument = if ($Json) { '-json ' } else { '' }
        $startInfo.Arguments = "$jsonArgument`"$($script:DbPath)`" `".read $tmpFile`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        try { $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch {}
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $process.Start() | Out-Null
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
    Invoke-MusicServerSqlNonQuery -Query 'PRAGMA foreign_keys=ON;'
    Invoke-MusicServerSqlNonQuery -Query 'PRAGMA busy_timeout=5000;'
    Invoke-MusicServerSqlNonQuery -Query 'PRAGMA synchronous=NORMAL;'
    if (-not (Test-Path -LiteralPath $DbPath)) {
        [IO.File]::WriteAllBytes($DbPath, @())
    }
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
    $parsed = ConvertFrom-MusicServerSqliteJson -Json $stdout
    if ($parsed -is [Array]) { return $parsed }
    return @($parsed)
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
