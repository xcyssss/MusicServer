<#
.SYNOPSIS
    Test helper: runs a single worker action in a real child PowerShell process.
    Used by MusicServer.WorkerConcurrency.Tests.ps1 to simulate concurrent workers
    racing against the same SQLite state database.
#>
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$WorkerId,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$TrackId = '',
    [string]$NewState = 'RETRY_WAIT',
    [int]$ExpectedRevision = -1,
    [int]$LeaseMinutes = 30,
    [int]$JitterMs = 0
)

$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'DailyMix_data\state') -Force

function Write-Result {
    param([hashtable]$Payload)
    $json = ($Payload | ConvertTo-Json -Depth 5 -Compress)
    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        $null = New-Item -ItemType Directory -Path $outDir -Force
    }
    [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    if ($JitterMs -gt 0) { Start-Sleep -Milliseconds $JitterMs }

    Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
    $cfg = New-MusicServerConfig -Root $Root
    Initialize-MusicServerState -Config $cfg
    Initialize-MusicServerDatabase -DbPath (Join-Path $cfg.StateDir 'musicserver.db') -SqliteExe $cfg.Sqlite
    Initialize-MusicServerSchema

    switch ($Action) {
        'claim' {
            $res = Claim-WantedItemDb -TrackId $TrackId -WorkerId $WorkerId -LeaseMinutes $LeaseMinutes
            $item = Get-WantedItemDb -TrackId $TrackId
            Write-Result @{
                Success = [bool]$res.Success; Reason = [string]$res.Reason
                ItemState = [string]$item.state; ClaimedBy = [string]$item.claimed_by
            }
        }
        'cancel' {
            $res = Request-WantedCancellationDb -TrackId $TrackId
            $item = Get-WantedItemDb -TrackId $TrackId
            Write-Result @{
                Success = [bool]$res.Success; Reason = [string]$res.Reason
                ItemState = if ($item) { [string]$item.state } else { 'MISSING' }
            }
        }
        'cas' {
            $res = Update-WantedStateCasDb -TrackId $TrackId -NewState $NewState `
                -ExpectedRevision $ExpectedRevision -WorkerId $WorkerId
            Write-Result @{ Success = [bool]$res.Success; Reason = [string]$res.Reason }
        }
        'recover-claim' {
            $recovered = Invoke-CrashRecoveryDb
            $res = Claim-WantedItemDb -TrackId $TrackId -WorkerId $WorkerId -LeaseMinutes $LeaseMinutes
            $item = Get-WantedItemDb -TrackId $TrackId
            Write-Result @{
                Success = [bool]$res.Success; Reason = [string]$res.Reason; Recovered = [int]$recovered
                ItemState = [string]$item.state; ClaimedBy = [string]$item.claimed_by
            }
        }
        'renew' {
            $affected = Renew-LeaseDb -TrackId $TrackId -WorkerId $WorkerId
            Write-Result @{ Success = ([int]$affected -eq 1); Affected = [int]$affected }
        }
        'like' {
            $res = Invoke-LikeTrackTransactionDb -TrackId $TrackId -Source 'worker_child'
            Write-Result @{
                Success = $true; Action = [string]$res.action
                Queue = $(if ($res.to_queue) { [string]$res.to_queue } else { 'NONE' }); QueueRev = [int]$res.queue_revision
            }
}
        default {
            Write-Result @{ Success = $false; Reason = "UNKNOWN_ACTION:$Action" }
        }
    }
} catch {
    Write-Result @{
        Success = $false; Reason = 'EXCEPTION'
        Message = [string]$_.Exception.Message; Action = $Action; WorkerId = $WorkerId
    }
}
