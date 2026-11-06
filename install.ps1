#Requires -Version 7
# Installs Claude session restore: copies scripts, adds Claude Code hooks, adds Windows Terminal profiles + startup restore.
# Safe to re-run (updates in place). Backs up both settings files first.
$ErrorActionPreference = 'Stop'

$dest     = Join-Path $HOME '.claude\session-tracker'
$hookPath = ($dest -replace '\\', '/') + '/hook.ps1'
$restore  = Join-Path $dest 'restore.ps1'
$icon     = Join-Path $dest 'claude.png'

# Fixed GUIDs so re-install / uninstall can find our profiles
$G = @{
    Last    = '{2f6c8e1a-9b4d-4c7e-a3f5-6d1b8c9e0a24}'
    All     = '{8a3d5f7b-1c2e-4b9a-8f6d-3e7c1a5b9d02}'
    Session = '{c1a0de5e-5e55-4d0a-9c1a-0de5e55e0001}'
}

function Save-Json($obj, $path) {
    Copy-Item $path "$path.bak" -Force -ErrorAction SilentlyContinue
    $obj | ConvertTo-Json -Depth 32 | Set-Content $path -Encoding utf8
}

# 1. Scripts
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'src\*') $dest -Force
Write-Host "Scripts  -> $dest"

# 2. Claude Code hooks (~/.claude/settings.json)
$cs = Join-Path $HOME '.claude\settings.json'
$s  = if (Test-Path $cs) { Get-Content $cs -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
if (-not $s.hooks) { $s.hooks = [ordered]@{} }
foreach ($ev in 'SessionStart', 'SessionEnd') {
    $arg  = if ($ev -eq 'SessionStart') { 'start' } else { 'end' }
    $list = @($s.hooks[$ev] | Where-Object { $_ } | Where-Object { -not ($_.hooks.command -match 'session-tracker/hook\.ps1') })
    $h = [ordered]@{ type = 'command'; command = "pwsh -NoProfile -NonInteractive -File $hookPath $arg" }
    if ($ev -eq 'SessionStart') { $h.async = $true }
    $list += [ordered]@{ hooks = @($h) }
    $s.hooks[$ev] = $list
}
Save-Json $s $cs
Write-Host "Hooks    -> $cs"

# 3. Windows Terminal (Store, Preview, or unpackaged install)
$wtPaths = @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
) | Where-Object { Test-Path $_ }
if (-not $wtPaths) { Write-Warning 'Windows Terminal settings not found. Open Windows Terminal once, then re-run.'; return }

foreach ($wp in $wtPaths) {
    $w = Get-Content $wp -Raw | ConvertFrom-Json -AsHashtable
    if ($w.profiles -is [System.Collections.IList]) { $w.profiles = [ordered]@{ list = $w.profiles } }
    $ours = $G.Values
    $list = @($w.profiles.list | Where-Object { $_.guid -notin $ours })
    $list += [ordered]@{ guid = $G.Last; name = 'Restore Last Claude Session'; icon = $icon; hidden = $false
                         commandline = "pwsh -NoProfile -NoExit -File `"$restore`" -Last"; startingDirectory = '%USERPROFILE%' }
    $list += [ordered]@{ guid = $G.All; name = 'Restore All Claude Sessions'; icon = $icon; hidden = $false
                         commandline = "pwsh -NoProfile -NoExit -File `"$restore`" -All -UseTab"; startingDirectory = '%USERPROFILE%' }
    $list += [ordered]@{ guid = $G.Session; name = 'Claude Session'; icon = $icon; hidden = $true
                         commandline = 'pwsh -NoExit'; startingDirectory = '%USERPROFILE%' }
    $w.profiles.list = $list
    # Restore on app launch only (not when clicking +), in a tab of the default profile
    $def = if ($w.defaultProfile) { $w.defaultProfile } else { 'PowerShell' }
    $w.startupActions = "nt -p `"$def`" pwsh -NoExit -File `"$restore`" -UseTab"
    if ($w.firstWindowPreference -eq 'persistedWindowLayout') { $w.Remove('firstWindowPreference') }
    Save-Json $w $wp
    Write-Host "Terminal -> $wp"
}

Write-Host "`nInstalled. Restart Windows Terminal. Sessions started from now on are tracked." -ForegroundColor Green
