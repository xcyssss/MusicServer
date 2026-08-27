# open_with_obsidian.ps1
# Wrapper script: receives a .md file path, opens it in Obsidian via URI scheme
# This solves the problem where Obsidian is already running and won't open the file

param([Parameter(Mandatory=$true)][string]$FilePath)

# Resolve to absolute path
$fullPath = (Resolve-Path $FilePath -ErrorAction SilentlyContinue).Path
if (-not $fullPath) {
    $fullPath = (Get-Item $FilePath -ErrorAction SilentlyContinue).FullName
}
if (-not $fullPath) {
    # File doesn't exist, just launch Obsidian
    Start-Process "C:\Users\dell\AppData\Local\Programs\Obsidian\Obsidian.exe"
    exit
}

# Read Obsidian config to find vault
$obsidianConfig = Get-Content "$env:APPDATA\obsidian\obsidian.json" -ErrorAction SilentlyContinue | ConvertFrom-Json
$vaults = $obsidianConfig.vaults.PSObject.Properties
$firstVault = $vaults | Select-Object -First 1
$vaultName = $firstVault.Name  # This is the vault ID, not the name
$vaultPath = $firstVault.Value.path

# Try to get the vault folder name (for the URI we need the vault name, not ID)
$vaultDirName = Split-Path $vaultPath -Leaf

# Calculate relative path from vault root to the file
try {
    $relativePath = [System.IO.Path]::GetRelativePath($vaultPath, $fullPath)
    # Replace backslashes with forward slashes for URI
    $relativePath = $relativePath -replace '\\', '/'
    # Remove .md extension (Obsidian URI doesn't need it)
    $relativePath = $relativePath -replace '\.md$', ''
    # URL encode
    $encodedPath = [System.Uri]::EscapeDataString($relativePath)
    $encodedVault = [System.Uri]::EscapeDataString($vaultDirName)
    
    $uri = "obsidian://open?vault=$encodedVault&file=$encodedPath"
    Write-Host "Opening: $uri"
    Start-Process $uri
} catch {
    # Fallback: just launch Obsidian directly
    Start-Process "C:\Users\dell\AppData\Local\Programs\Obsidian\Obsidian.exe" -ArgumentList "`"$fullPath`""
}
