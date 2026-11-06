#Requires -Version 7
# Removes Claude session restore: hooks, Windows Terminal profiles + startup action, and the scripts/data folder.
#   uninstall.ps1 -KeepData   leave ~/.claude/session-tracker in place
param([switch]$KeepData)
$ErrorActionPreference = 'Stop'

$dest = Join-Path $HOME '.claude\session-tracker'
$ours = '{2f6c8e1a-9b4d-4c7e-a3f5-6d1b8c9e0a24}', '{8a3d5f7b-1c2e-4b9a-8f6d-3e7c1a5b9d02}', '{c1a0de5e-5e55-4d0a-9c1a-0de5e55e0001}'

function Save-Json($obj, $path) {
    Copy-Item $path "$path.bak" -Force -ErrorAction SilentlyContinue
    $obj | ConvertTo-Json -Depth 32 | Set-Content $path -Encoding utf8
}

# Claude Code hooks
$cs = Join-Path $HOME '.claude\settings.json'
if (Test-Path $cs) {
    $s = Get-Content $cs -Raw | ConvertFrom-Json -AsHashtable
    foreach ($ev in 'SessionStart', 'SessionEnd') {
        if (-not $s.hooks -or -not $s.hooks[$ev]) { continue }
        $list = @($s.hooks[$ev] | Where-Object { -not ($_.hooks.command -match 'session-tracker/hook\.ps1') })
        if ($list) { $s.hooks[$ev] = $list } else { $s.hooks.Remove($ev) }
    }
    Save-Json $s $cs
    Write-Host "Hooks removed    <- $cs"
}

# Windows Terminal
$wtPaths = @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
) | Where-Object { Test-Path $_ }
foreach ($wp in $wtPaths) {
    $w = Get-Content $wp -Raw | ConvertFrom-Json -AsHashtable
    if ($w.profiles.list) { $w.profiles.list = @($w.profiles.list | Where-Object { $_.guid -notin $ours }) }
    if ($w.startupActions -match 'session-tracker') { $w.Remove('startupActions') }
    Save-Json $w $wp
    Write-Host "Profiles removed <- $wp"
}

if (-not $KeepData -and (Test-Path $dest)) { Remove-Item $dest -Recurse -Force; Write-Host "Deleted          <- $dest" }
Write-Host "`nUninstalled. Restart Windows Terminal." -ForegroundColor Green
