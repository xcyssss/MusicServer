Set-StrictMode -Version 3.0

function Stop-MusicServerHttpInput {
    param([int]$StatusCode, [string]$Code, [string]$Message)
    $exception = New-Object IO.InvalidDataException($Message)
    $exception.Data['HttpStatusCode'] = $StatusCode
    $exception.Data['ErrorCode'] = $Code
    throw $exception
}

function Read-MusicServerJsonRequest {
    <#
      Buffer and validate small JSON control requests before any state changes
      or proxy forwarding. Empty bodies remain compatible with existing clients.
      Chunked bodies are explicitly rejected instead of silently becoming empty.
      One deadline covers the entire body, not a new timeout for every fragment.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [ValidateRange(1, 1048576)][int]$MaxBytes = 65536,
        [ValidateRange(1, 60000)][int]$TimeoutMs = 5000
    )
    if ($Request.Headers['Transfer-Encoding'] -or $Request.ContentLength64 -lt 0) {
        Stop-MusicServerHttpInput 411 'LENGTH_REQUIRED' 'Send a JSON body with an explicit Content-Length; chunked requests are not supported.'
    }
    $length = [long]$Request.ContentLength64
    if ($length -gt $MaxBytes) {
        Stop-MusicServerHttpInput 413 'BODY_TOO_LARGE' "Request body exceeds $MaxBytes bytes."
    }
    $encoding = [string]$Request.Headers['Content-Encoding']
    if ($encoding -and $encoding -ne 'identity') {
        Stop-MusicServerHttpInput 415 'UNSUPPORTED_CONTENT_ENCODING' 'Send uncompressed UTF-8 JSON.'
    }
    $bytes = New-Object byte[] ([int]$length)
    if ($length -eq 0) { return [pscustomobject]@{ Text = ''; Bytes = $bytes } }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $offset = 0
    while ($offset -lt $length) {
        $remainingMs = $TimeoutMs - [int]$timer.ElapsedMilliseconds
        if ($remainingMs -le 0) {
            Stop-MusicServerHttpInput 408 'BODY_TIMEOUT' 'Request body did not arrive within the time limit.'
        }
        $pending = $null
        $wait = $null
        $read = 0
        try {
            $pending = $Request.InputStream.BeginRead($bytes, $offset, [int]$length - $offset, $null, $null)
            $wait = $pending.AsyncWaitHandle
            if (-not $wait.WaitOne($remainingMs)) {
                Stop-MusicServerHttpInput 408 'BODY_TIMEOUT' 'Request body did not arrive within the time limit.'
            }
            $read = $Request.InputStream.EndRead($pending)
        } catch {
            if ($_.Exception.Data.Contains('HttpStatusCode')) { throw }
            Stop-MusicServerHttpInput 400 'INCOMPLETE_BODY' 'Request body ended before Content-Length bytes were received.'
        } finally {
            if ($wait) { $wait.Close() }
        }
        if ($read -le 0) {
            Stop-MusicServerHttpInput 400 'INCOMPLETE_BODY' 'Request body ended before Content-Length bytes were received.'
        }
        $offset += $read
    }
    try {
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $text = $utf8.GetString($bytes)
        $trimmed = $text.Trim()
        if (-not $trimmed.StartsWith('{') -or -not $trimmed.EndsWith('}')) { throw 'Expected a JSON object.' }
        $payload = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        if ($null -eq $payload -or $payload -isnot [pscustomobject]) { throw 'Expected a JSON object.' }
    } catch {
        Stop-MusicServerHttpInput 400 'INVALID_JSON' 'Request body must be a valid UTF-8 JSON object.'
    }
    return [pscustomobject]@{ Text = $text; Bytes = $bytes }
}

Export-ModuleMember -Function Read-MusicServerJsonRequest
