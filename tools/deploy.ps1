# Deploy only runtime addon files from this repo to the live RoR AddOns folder.
# Copies: StockPiler3.mod + Source\
# Removes anything else under Dest (docs, tools, README, .git, etc.).
#
# Usage:
#   .\tools\deploy.ps1
#   .\tools\deploy.ps1 -WhatIf
#   .\tools\deploy.ps1 -Dest "D:\Games\...\Interface\AddOns\StockPiler3"

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Dest = "C:\Users\talla\Games\Return of Reckoning\Interface\AddOns\StockPiler3"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$DestParent = Split-Path -Parent $Dest
$ModSrc = Join-Path $RepoRoot "StockPiler3.mod"
$SourceSrc = Join-Path $RepoRoot "Source"

if (-not (Test-Path -LiteralPath $ModSrc)) {
    throw "StockPiler3.mod missing under $RepoRoot - refuse to deploy"
}
if (-not (Test-Path -LiteralPath $SourceSrc)) {
    throw "Source\ missing under $RepoRoot - refuse to deploy"
}
if (-not (Test-Path -LiteralPath $DestParent)) {
    throw "AddOns parent missing: $DestParent"
}

Write-Host "Repo:   $RepoRoot"
Write-Host "Dest:   $Dest"
Write-Host "Copy:   StockPiler3.mod + Source\"

if (-not $PSCmdlet.ShouldProcess($Dest, "Deploy runtime addon files and prune extras")) {
    exit 0
}

New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$DestSource = Join-Path $Dest "Source"
$DestMod = Join-Path $Dest "StockPiler3.mod"

# Mirror Source\ only (adds, updates, deletes stale files under Dest\Source).
$robocopyArgs = @(
    $SourceSrc,
    $DestSource,
    "/MIR",
    "/XF", "*.bak", "*.tmp", "*.log", "Thumbs.db", ".DS_Store",
    "/XD", "__pycache__",
    "/R:2", "/W:1",
    "/NFL", "/NDL", "/NP", "/NJH"
)
& robocopy @robocopyArgs
$rc = $LASTEXITCODE
# Robocopy: 0-7 = success (with optional extras); >=8 = failure
if ($rc -ge 8) {
    throw "robocopy Source failed with exit code $rc"
}

Copy-Item -LiteralPath $ModSrc -Destination $DestMod -Force

# Keep Dest as a runtime-only tree: remove anything that is not .mod or Source\.
$allowed = @{
    "StockPiler3.mod" = $true
    "Source"          = $true
}
Get-ChildItem -LiteralPath $Dest -Force | ForEach-Object {
    if ($allowed.ContainsKey($_.Name)) { return }
    Write-Host "Prune: $($_.FullName)"
    Remove-Item -LiteralPath $_.FullName -Recurse -Force
}

if (-not (Test-Path -LiteralPath $DestMod) -or -not (Test-Path -LiteralPath $DestSource)) {
    throw "Deploy incomplete: missing StockPiler3.mod or Source under $Dest"
}

$copied = (Get-ChildItem -LiteralPath $DestSource -Recurse -File).Count
Write-Host "Deploy OK (Source files: $copied, robocopy exit $rc). Reload UI in-game (/reload)."
exit 0
