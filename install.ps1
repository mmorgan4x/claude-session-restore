#Requires -Version 7
# Installs Claude session restore: copies scripts, adds Claude Code hooks, adds Windows Terminal profiles + startup restore.
# Safe to re-run (updates in place). Original settings are backed up once to *.pre-session-restore.bak,
# and any startupActions / firstWindowPreference we replace are saved so uninstall.ps1 can put them back.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\src\common.ps1"

$dest     = $SR.Root
$hookPath = ($dest -replace '\\', '/') + '/hook.ps1'
$restore  = Join-Path $dest 'restore.ps1'
$icon     = Join-Path $dest 'claude.png'

# 1. Scripts
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'src\*') $dest -Force
Write-Host "Scripts  -> $dest"

# Icon: copied from the installed Claude Desktop app (not shipped in this repo). Re-run install to refresh.
$pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
$logo = if ($pkg) { Get-ChildItem (Join-Path $pkg.InstallLocation 'assets') -Filter 'Square44x44Logo.targetsize-*_altform-unplated.png' -ErrorAction SilentlyContinue |
                    Sort-Object { [int]($_.Name -replace '.*targetsize-(\d+)_.*', '$1') } | Where-Object { $_.Name -match 'targetsize-(32|48|64)_' } | Select-Object -Last 1 }
if ($logo) { Copy-Item $logo.FullName $icon -Force; Write-Host "Icon     -> $icon" }
elseif (-not (Test-Path $icon)) { $icon = $null; Write-Warning 'Claude Desktop not found; profiles will use the default icon.' }

# 2. Claude Code hooks (~/.claude/settings.json)
$cs = Join-Path $HOME '.claude\settings.json'
$s  = if (Test-Path $cs) { Get-Content $cs -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
if (-not $s.hooks) { $s.hooks = [ordered]@{} }
foreach ($ev in 'SessionStart', 'SessionEnd') {
    $arg  = if ($ev -eq 'SessionStart') { 'start' } else { 'end' }
    $list = @($s.hooks[$ev] | Where-Object { $_ } | Where-Object { -not ($_.hooks.command -match 'session-tracker/hook\.ps1') })
    $h = [ordered]@{ type = 'command'; command = "pwsh -NoProfile -NonInteractive -File `"$hookPath`" $arg" }
    if ($ev -eq 'SessionStart') { $h.async = $true }
    $list += [ordered]@{ hooks = @($h) }
    $s.hooks[$ev] = $list
}
Save-Json $s $cs
Write-Host "Hooks    -> $cs"

# 3. Windows Terminal
$wtPaths = Get-WtSettingsPaths
if (-not $wtPaths) { Write-Warning 'Windows Terminal settings not found. Open Windows Terminal once, then re-run.'; return }

$state = if (Test-Path $SR.State) { Get-Content $SR.State -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }

foreach ($wp in $wtPaths) {
    $w = Get-Content $wp -Raw | ConvertFrom-Json -AsHashtable

    # Remember the user's own settings once (not ours from a previous install)
    if (-not $state.Contains($wp)) {
        $state[$wp] = [ordered]@{
            startupActions        = if ($w.startupActions -notmatch 'session-tracker') { $w.startupActions } else { $null }
            firstWindowPreference = $w.firstWindowPreference
        }
        if ($w.startupActions -and $w.startupActions -notmatch 'session-tracker') {
            Write-Warning "Replacing your startupActions ('$($w.startupActions)'); uninstall.ps1 restores it."
        }
        if ($w.firstWindowPreference -eq 'persistedWindowLayout') {
            Write-Warning "Turning off 'reopen previous session' (it would duplicate restored tabs); uninstall.ps1 restores it."
        }
    }

    if ($w.profiles -is [System.Collections.IList]) { $w.profiles = [ordered]@{ list = $w.profiles } }
    $list = @($w.profiles.list | Where-Object { $_.guid -notin $SR.Guids })
    $list += [ordered]@{ guid = $SR.GuidLast; name = 'Restore Last Claude Session'; icon = $icon; hidden = $false
                         commandline = "pwsh -NoProfile -NoExit -File `"$restore`" -Last"; startingDirectory = '%USERPROFILE%' }
    $list += [ordered]@{ guid = $SR.GuidAll; name = 'Restore All Claude Sessions'; icon = $icon; hidden = $false
                         commandline = "pwsh -NoProfile -NoExit -File `"$restore`" -All -UseTab"; startingDirectory = '%USERPROFILE%' }
    $list += [ordered]@{ guid = $SR.GuidSession; name = 'Claude Session'; icon = $icon; hidden = $true
                         commandline = 'pwsh -NoExit'; startingDirectory = '%USERPROFILE%' }
    if (-not $icon) { $list | Where-Object { $_.guid -in $SR.Guids } | ForEach-Object { $_.Remove('icon') } }
    $w.profiles.list = $list
    # Restore on app launch only (not when clicking +), in a tab styled as the default profile
    $def = if ($w.defaultProfile) { $w.defaultProfile } else { 'PowerShell' }
    $w.startupActions = "nt -p `"$def`" pwsh -NoExit -File `"$restore`" -UseTab"
    if ($w.firstWindowPreference -eq 'persistedWindowLayout') { $w.Remove('firstWindowPreference') }
    Save-Json $w $wp
    Write-Host "Terminal -> $wp"
}
$state | ConvertTo-Json -Depth 8 | Set-Content $SR.State -Encoding utf8

Write-Host "`nInstalled. Restart Windows Terminal. Sessions started from now on are tracked." -ForegroundColor Green
