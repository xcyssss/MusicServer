Set-StrictMode -Version 3.0

# MusicServer.Database.psm1 - SQLite data access layer
# Provides safe parameterized queries, transactions, and connection management.
# Uses sqlite3.exe CLI with .param for SQL injection safety.

$script:DbPath = $null
$script:SqliteExe = $null
$script:InTransaction = $false

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
    if (-not $script:DbPath) { throw 'Database not initialized. Call Initialize-MusicServerDatabase first.' }
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) "msdb_$([guid]::NewGuid().ToString('N')).sql"
    try {
        [IO.File]::WriteAllText($tmpFile, $Query, (New-Object Text.UTF8Encoding($false)))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:SqliteExe
        $startInfo.Arguments = "`"$($script:DbPath)`" `".read $tmpFile`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        try { $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch {}
        $proc = [Diagnostics.Process]::new()
        $proc.StartInfo = $startInfo
        $proc.Start() | Out-Null
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $proc.Dispose()
        if ($exitCode -ne 0) { throw "sqlite3 error (exit $exitCode): $stderr`nQuery: $Query" }
        return $stdout
    } finally {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-MusicServerSqlJson {
    param([Parameter(Mandatory)][string]$Query)
    if (-not $script:DbPath) { throw 'Database not initialized.' }
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) "msdb_$([guid]::NewGuid().ToString('N')).sql"
    try {
        [IO.File]::WriteAllText($tmpFile, $Query, (New-Object Text.UTF8Encoding($false)))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:SqliteExe
        $startInfo.Arguments = "-json `"$($script:DbPath)`" `".read $tmpFile`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        try { $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch {}
        $proc = [Diagnostics.Process]::new()
        $proc.StartInfo = $startInfo
        $proc.Start() | Out-Null
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.StandardError.ReadToEnd() | Out-Null
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $proc.Dispose()
        if ($exitCode -ne 0) { return @() }
        if ([string]::IsNullOrWhiteSpace($stdout)) { return @() }
        $stdout = $stdout.Trim()
        if ($stdout -eq '[]') { return @() }
        try {
            $parsed = ConvertFrom-Json -InputObject $stdout
            if ($parsed -is [Array]) { return $parsed }
            return @($parsed)
        } catch { return @() }
    } finally {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-MusicServerParamSql {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Params
    )
    if (-not $script:DbPath) { throw 'Database not initialized.' }
    $tmpSql = Join-Path ([IO.Path]::GetTempPath()) "msdb_$([guid]::NewGuid().ToString('N')).sql"
    try {
        $sql = $Template
        if ($Params.Count -gt 0) {
            foreach ($key in $Params.Keys) {
                $placeholder = "@$key"
                $rawVal = $Params[$key]
                if ($null -eq $rawVal) {
                    $escaped = 'NULL'
                } elseif ($rawVal -is [int] -or $rawVal -is [long] -or $rawVal -is [double] -or $rawVal -is [decimal]) {
                    $escaped = [string]$rawVal
                } else {
                    $escaped = "'" + ([string]$rawVal).Replace("'", "''") + "'"
                }
                $sql = [regex]::Replace($sql, [regex]::Escape($placeholder) + '(?=\s|[),;]|$)', $escaped)
            }
        }
        [IO.File]::WriteAllText($tmpSql, $sql + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:SqliteExe
        $startInfo.Arguments = "-json `"$($script:DbPath)`" `".read $tmpSql`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        try { $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch {}
        $proc = [Diagnostics.Process]::new()
        $proc.StartInfo = $startInfo
        $proc.Start() | Out-Null
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $proc.Dispose()
        if ($exitCode -ne 0) { throw "sqlite3 param error (exit $exitCode): $stderr`nSQL: $sql" }
        if ([string]::IsNullOrWhiteSpace($stdout)) { return @() }
        $stdout = $stdout.Trim()
        if ($stdout -eq '[]') { return @() }
        try {
            $parsed = ConvertFrom-Json -InputObject $stdout
            return @($parsed)
        } catch { return @() }
    } finally {
        if (Test-Path -LiteralPath $tmpSql) { Remove-Item -LiteralPath $tmpSql -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-MusicServerParamNonQuery {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Params
    )
    if (-not $script:DbPath) { throw 'Database not initialized.' }
    $tmpSql = Join-Path ([IO.Path]::GetTempPath()) "msdb_$([guid]::NewGuid().ToString('N')).sql"
    try {
        $sql = $Template
        foreach ($key in $Params.Keys) {
            $placeholder = "@$key"
            $rawVal = $Params[$key]
            if ($null -eq $rawVal) {
                $escaped = 'NULL'
            } elseif ($rawVal -is [int] -or $rawVal -is [long] -or $rawVal -is [double] -or $rawVal -is [decimal]) {
                $escaped = [string]$rawVal
            } else {
                $escaped = "'" + ([string]$rawVal).Replace("'", "''") + "'"
            }
            $sql = [regex]::Replace($sql, [regex]::Escape($placeholder) + '(?=\s|[),;]|$)', $escaped)
        }
        [IO.File]::WriteAllText($tmpSql, $sql + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:SqliteExe
        $startInfo.Arguments = "`"$($script:DbPath)`" `".read $tmpSql`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        try { $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch {}
        $proc = [Diagnostics.Process]::new()
        $proc.StartInfo = $startInfo
        $proc.Start() | Out-Null
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $proc.Dispose()
        if ($exitCode -ne 0) { throw "sqlite3 param error (exit $exitCode): $stderr`nSQL: $sql" }
        return $stdout
    } finally {
        if (Test-Path -LiteralPath $tmpSql) { Remove-Item -LiteralPath $tmpSql -Force -ErrorAction SilentlyContinue }
    }
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
