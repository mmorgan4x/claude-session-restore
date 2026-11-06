#Requires -Version 7
# Removes Claude session restore: hooks, Windows Terminal profiles + startup action (restoring the user's
# originals), and the scripts/data folder.
#   uninstall.ps1 -KeepData   leave ~/.claude/session-tracker in place
# Runs from the repo or from the installed copy (~/.claude/session-tracker/uninstall.ps1).
param([switch]$KeepData)
$ErrorActionPreference = 'Stop'
$common = @("$PSScriptRoot\src\common.ps1", "$PSScriptRoot\common.ps1") | Where-Object { Test-Path $_ } | Select-Object -First 1
. $common

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
$state = if (Test-Path $SR.State) { Get-Content $SR.State -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
foreach ($wp in Get-WtSettingsPaths) {
    $w = Get-Content $wp -Raw | ConvertFrom-Json -AsHashtable
    if ($w.profiles.list) { $w.profiles.list = @($w.profiles.list | Where-Object { $_.guid -notin $SR.Guids }) }
    if ($w.startupActions -match 'session-tracker') { $w.Remove('startupActions') }
    $orig = $state[$wp]
    if ($orig) {
        if ($orig.startupActions) { $w.startupActions = $orig.startupActions }
        if ($orig.firstWindowPreference -and -not $w.firstWindowPreference) { $w.firstWindowPreference = $orig.firstWindowPreference }
    }
    Save-Json $w $wp
    Write-Host "Profiles removed <- $wp"
}

if (-not $KeepData -and (Test-Path $SR.Root)) { Remove-Item $SR.Root -Recurse -Force; Write-Host "Deleted          <- $($SR.Root)" }
Write-Host "`nUninstalled. Restart Windows Terminal." -ForegroundColor Green
