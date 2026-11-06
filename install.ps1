# Installs Claude session restore: copies scripts, adds Claude Code hooks, adds Windows Terminal profiles + startup restore.
# Safe to re-run (updates in place). Original settings are backed up once to *.pre-session-restore.bak,
# and any startupActions / firstWindowPreference we replace are saved so uninstall.ps1 can put them back.
#
# One-line install (from Windows PowerShell or pwsh):
#   irm https://raw.githubusercontent.com/mmorgan4x/claude-session-restore/main/install.ps1 | iex
#
# -AutoRestore on|off   restore crashed sessions when Windows Terminal starts (default on; omitted keeps the current choice)
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mmorgan4x/claude-session-restore/main/install.ps1))) -AutoRestore off
param([ValidateSet('on', 'off')][string]$AutoRestore)

# Bootstrap: when piped through iex there is no repo on disk, so download it and run from there with pwsh 7
if (-not $PSScriptRoot -or -not (Test-Path (Join-Path $PSScriptRoot 'src\common.ps1'))) {
    & {
        if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
            Write-Host 'PowerShell 7 (pwsh) is required: winget install Microsoft.PowerShell' -ForegroundColor Red; return
        }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "claude-session-restore-$(Get-Random)"
        New-Item -ItemType Directory $tmp | Out-Null
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest 'https://github.com/mmorgan4x/claude-session-restore/archive/refs/heads/main.zip' -OutFile "$tmp\repo.zip" -UseBasicParsing
            Expand-Archive "$tmp\repo.zip" $tmp
            $fwd = if ($AutoRestore) { @('-AutoRestore', $AutoRestore) } else { @() }
            pwsh -NoProfile -File "$tmp\claude-session-restore-main\install.ps1" @fwd
            if ($LASTEXITCODE) { Write-Error "claude-session-restore: install failed (exit code $LASTEXITCODE)." }
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return
}

if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run with PowerShell 7: pwsh -File install.ps1' }
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\src\common.ps1"

$dest     = $SR.Root
$hookPath = ($dest -replace '\\', '/') + '/hook.ps1'
$restore  = Join-Path $dest 'restore.ps1'
$icon     = Join-Path $dest 'claude.png'

# 1. Scripts
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'src\*') $dest -Force
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1') $dest -Force   # so uninstall works without the repo
Write-Host "Scripts  -> $dest"

# Options: an explicit -AutoRestore wins, otherwise keep what's in config.json (default on)
$cfg = Get-SrConfig
if ($AutoRestore) { $cfg.autoRestore = $AutoRestore -eq 'on' }
$cfg | ConvertTo-Json | Set-Content $SR.Config -Encoding utf8
Write-Host "Config   -> $($SR.Config) (auto-restore $(if ($cfg.autoRestore) { 'on' } else { 'off' }))"

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
foreach ($ev in $SR.HookEvents.Keys) {
    $arg  = $SR.HookEvents[$ev]
    $list = @($s.hooks[$ev] | Where-Object { $_ } | Where-Object { -not ($_.hooks.command -match 'session-tracker/hook\.ps1') })
    $h = [ordered]@{ type = 'command'; command = "pwsh -NoProfile -NonInteractive -File `"$hookPath`" $arg" }
    # Only SessionEnd runs synchronously (must finish before the process exits); the rest never delay Claude
    if ($ev -ne 'SessionEnd') { $h.async = $true }
    $list += [ordered]@{ hooks = @($h) }
    $s.hooks[$ev] = $list
}
Save-Json $s $cs
Write-Host "Hooks    -> $cs"

# 3. Windows Terminal
$wtPaths = Get-WtSettingsPaths
if (-not $wtPaths) { Write-Warning 'Windows Terminal settings not found. Open Windows Terminal once, then re-run.'; return }

$state = if (Test-Path $SR.State) { Get-Content $SR.State -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }

# Order-insensitive fingerprint of a newTabMenu (WT may reorder keys when it rewrites settings.json),
# used to tell whether the user edited the menu we wrote
function Get-MenuKey($m) {
    @($m | Where-Object { $_ } | ForEach-Object {
        $e = $_
        if ($e -is [System.Collections.IDictionary]) {
            ($e.Keys | Sort-Object | ForEach-Object { "$_=" + (Get-MenuKey $e[$_]) }) -join ','
        } elseif ($e -is [System.Collections.IList]) { '[' + (Get-MenuKey $e) + ']' }
        else { "$e" }
    }) -join ';'
}

foreach ($wp in $wtPaths) {
    $w = Get-Content $wp -Raw | ConvertFrom-Json -AsHashtable

    # The user's own settings we replace. Re-captured on every run whenever the current value isn't ours,
    # so changes made after the first install are what uninstall restores.
    if (-not $state.Contains($wp)) { $state[$wp] = [ordered]@{ startupActions = $null; firstWindowPreference = $null; newTabMenu = $null } }
    $st = $state[$wp]
    if ($w.startupActions -and $w.startupActions -notmatch 'session-tracker') {
        $st.startupActions = $w.startupActions
        if ($cfg.autoRestore) { Write-Warning "Replacing your startupActions ('$($w.startupActions)'); uninstall.ps1 restores it." }
    }
    if ($w.firstWindowPreference -eq 'persistedWindowLayout') {
        $st.firstWindowPreference = $w.firstWindowPreference
        Write-Warning "Turning off 'reopen previous session' (it would duplicate restored tabs); uninstall.ps1 restores it."
    }

    if ($w.profiles -is [System.Collections.IList]) { $w.profiles = [ordered]@{ list = $w.profiles } }
    $list = @($w.profiles.list | Where-Object { $_.guid -notin $SR.Guids })
    $list += [ordered]@{ guid = $SR.GuidNew; name = 'Claude: New'; icon = $icon; hidden = $false
                         commandline = 'pwsh -NoExit -Command claude'; startingDirectory = '%USERPROFILE%' }
    $list += [ordered]@{ guid = $SR.GuidResume; name = 'Claude: Resume'; icon = $icon; hidden = $false
                         commandline = 'pwsh -NoExit -Command claude --resume'; startingDirectory = '%USERPROFILE%' }
    $list += [ordered]@{ guid = $SR.GuidAll; name = 'Claude: Restore Previous Sessions'; icon = $icon; hidden = $false
                         commandline = "pwsh -NoProfile -NoExit -File `"$restore`" -All -UseTab"; startingDirectory = '%USERPROFILE%' }
    $list += [ordered]@{ guid = $SR.GuidSession; name = 'Claude: Session'; icon = $icon; hidden = $true
                         commandline = 'pwsh -NoExit'; startingDirectory = '%USERPROFILE%' }
    if (-not $icon) { $list | Where-Object { $_.guid -in $SR.Guids } | ForEach-Object { $_.Remove('icon') } }
    # Muted terracotta tab color: WT draws unselected colored tabs faded, a darker base keeps both states readable
    $list | Where-Object { $_.guid -in $SR.Guids } | ForEach-Object { $_.tabColor = $SR.TabColor }
    $w.profiles.list = $list

    # Default profile: WT's defaultProfile (guid or name) if it exists, else the first visible profile (what WT uses)
    $def = $w.defaultProfile
    if (-not $def -or -not ($list | Where-Object { $_.guid -eq $def -or $_.name -eq $def })) {
        $def = ($list | Where-Object { -not $_.hidden -and $_.guid -notin $SR.Guids } | Select-Object -First 1).guid
    }
    $defIsOurs = [bool]($list | Where-Object { ($_.guid -eq $def -or $_.name -eq $def) -and $_.guid -in $SR.Guids })

    # Startup restore only when auto-restore is on; off gives the first tab back to the default profile
    if ($cfg.autoRestore) {
        $w.startupActions = "nt -p `"$def`" pwsh -NoExit -File `"$restore`" -Startup"
    } elseif ($w.startupActions -match 'session-tracker') {
        if ($st.startupActions) { $w.startupActions = $st.startupActions } else { $w.Remove('startupActions') }
    }

    # + dropdown: default profile, other profiles, separator, Claude profiles (flat, no submenu).
    # Other profiles sit right under the default (empty if all hidden), so no separator can ever double up.
    $menu = @()
    if (-not $defIsOurs) { $menu += [ordered]@{ type = 'profile'; profile = $def } }
    $menu += [ordered]@{ type = 'remainingProfiles' }, [ordered]@{ type = 'separator' },
             [ordered]@{ type = 'profile'; profile = $SR.GuidNew },
             [ordered]@{ type = 'profile'; profile = $SR.GuidResume },
             [ordered]@{ type = 'profile'; profile = $SR.GuidAll }
    $cur = Get-MenuKey $w.newTabMenu
    if (-not (Test-OurNewTabMenu $w.newTabMenu)) {
        # The user's menu: save it (uninstall restores it) and replace. WT's default is just [remainingProfiles].
        $st.newTabMenu = if ($w.newTabMenu) { @($w.newTabMenu) } else { $null }
        if (@($w.newTabMenu | Where-Object { $_.type -ne 'remainingProfiles' })) {
            Write-Warning "Replacing your custom new-tab menu (newTabMenu); uninstall.ps1 restores it."
        }
        $w.newTabMenu = $menu
    } elseif ($st.ourMenu -and $cur -ne $st.ourMenu) {
        Write-Host "Menu     -> kept your edits to the + menu"
    } else {
        $w.newTabMenu = $menu
    }
    $st.ourMenu = Get-MenuKey $w.newTabMenu

    if ($w.firstWindowPreference -eq 'persistedWindowLayout') { $w.Remove('firstWindowPreference') }
    Save-Json $w $wp
    Write-Host "Terminal -> $wp"
}
$state | ConvertTo-Json -Depth 32 | Set-Content $SR.State -Encoding utf8

Write-Host "`nInstalled. Restart Windows Terminal. Sessions started from now on are tracked." -ForegroundColor Green
