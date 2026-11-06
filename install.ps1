# Installs Claude session restore: copies scripts, adds Claude Code hooks, adds Windows Terminal profiles + startup restore.
# Safe to re-run (updates in place). Original settings are backed up once to *.pre-session-restore.bak,
# and any startupActions / firstWindowPreference we replace are saved so uninstall.ps1 can put them back.
#
# One-line install (from Windows PowerShell or pwsh):
#   irm https://raw.githubusercontent.com/mmorgan4x/claude-session-restore/main/install.ps1 | iex
#
# -AutoRestore on|off   restore crashed sessions when Windows Terminal starts (default on; omitted keeps the current choice)
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mmorgan4x/claude-session-restore/main/install.ps1))) -AutoRestore off
# No [ValidateSet] here: under `irm | iex` the param block runs as a plain statement and the attribute
# throws on the empty value. Validated by hand instead.
param([string]$AutoRestore)
if ($AutoRestore -and $AutoRestore -notin 'on', 'off') {
    Write-Host "-AutoRestore must be 'on' or 'off' (got '$AutoRestore')" -ForegroundColor Red; return
}

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

# Icon: the orange Claude starburst with no background, taken from the installed Claude Desktop app (not
# shipped in this repo). Re-run install to refresh.
#  - Standalone (Squirrel) install: its app.ico is exactly that; WT accepts .ico as-is.
#  - Store (MSIX) install: has only a tile (burst on an orange square) and a black tray burst, so the tray
#    burst is recolored with the tile's orange.
function New-OrangeBurst($trayIco, $tilePng, $outPng) {
    Add-Type -AssemblyName System.Drawing
    $tile = [System.Drawing.Bitmap]::new($tilePng); $counts = @{}
    for ($x = 0; $x -lt $tile.Width; $x++) { for ($y = 0; $y -lt $tile.Height; $y++) {
        $c = $tile.GetPixel($x, $y); if ($c.A -eq 255 -and -not ($c.R -gt 240 -and $c.G -gt 240)) { $counts[$c.ToArgb()]++ } } }
    $tile.Dispose()
    $o = [System.Drawing.Color]::FromArgb(($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key)
    $src = ([System.Drawing.Icon]::new($trayIco, 256, 256)).ToBitmap(); $dst = [System.Drawing.Bitmap]::new($src.Width, $src.Height)
    for ($x = 0; $x -lt $src.Width; $x++) { for ($y = 0; $y -lt $src.Height; $y++) {
        $a = $src.GetPixel($x, $y).A; if ($a) { $dst.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($a, $o.R, $o.G, $o.B)) } } }
    $dst.Save($outPng); $dst.Dispose(); $src.Dispose()
}
$made = $null
$squirrelIco = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\app.ico'
if (Test-Path $squirrelIco) {
    $icon = Join-Path $dest 'claude.ico'; Copy-Item $squirrelIco $icon -Force; $made = $icon
} elseif ($pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1) {
    $tray = Join-Path $pkg.InstallLocation 'app\resources\Tray-Win32.ico'
    $tile = Get-ChildItem (Join-Path $pkg.InstallLocation 'assets') -Filter 'Square44x44Logo.targetsize-*_altform-unplated.png' -ErrorAction SilentlyContinue |
            Sort-Object { [int]($_.Name -replace '.*targetsize-(\d+)_.*', '$1') } | Where-Object { $_.Name -match 'targetsize-(32|48|64)_' } | Select-Object -Last 1
    if ((Test-Path $tray) -and $tile) {
        try { New-OrangeBurst $tray $tile.FullName $icon; $made = $icon }
        catch { Copy-Item $tile.FullName $icon -Force; $made = $icon }   # recolor failed: use the tile as-is
    } elseif ($tile) { Copy-Item $tile.FullName $icon -Force; $made = $icon }
}
if ($made) {
    # Drop the other format's leftover from an earlier install
    Get-ChildItem $dest -Filter 'claude.*' | Where-Object { $_.Extension -in '.png', '.ico' -and $_.FullName -ne $icon } | Remove-Item -Force
    Write-Host "Icon     -> $icon"
} else {
    # Not found now: keep an icon copied by an earlier install, if any
    $icon = @('claude.png', 'claude.ico') | ForEach-Object { Join-Path $dest $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $icon) { Write-Warning 'Claude Desktop not found; profiles will use the default icon.' }
}

# 2. Claude Code hooks (~/.claude/settings.json)
$cs = Join-Path $HOME '.claude\settings.json'
$s  = if (Test-Path $cs) { Get-Content $cs -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
if (-not $s.hooks) { $s.hooks = [ordered]@{} }
foreach ($ev in $SR.HookEvents.Keys) {
    $arg  = $SR.HookEvents[$ev]
    $list = @($s.hooks[$ev] | Where-Object { $_ } | Where-Object { -not ($_.hooks.command -match 'session-restore/hook\.ps1') })
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
    if ($w.startupActions -and $w.startupActions -notmatch 'session-restore') {
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
                         commandline = "pwsh -NoProfile -NoExit -File `"$restore`" -All"; startingDirectory = '%USERPROFILE%' }
    $list += [ordered]@{ guid = $SR.GuidSession; name = 'Claude: Session'; icon = $icon; hidden = $true
                         commandline = 'pwsh -NoExit'; startingDirectory = '%USERPROFILE%' }
    if (-not $icon) { $list | Where-Object { $_.guid -in $SR.Guids } | ForEach-Object { $_.Remove('icon') } }
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
    } elseif ($w.startupActions -match 'session-restore') {
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
