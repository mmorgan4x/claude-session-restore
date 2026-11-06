# Shared constants/helpers for install.ps1, uninstall.ps1, hook.ps1, restore.ps1 (dot-sourced).

$SR = @{
    Root        = Join-Path $HOME '.claude\session-tracker'
    # Fixed GUIDs so re-install / uninstall / restore can find our Windows Terminal profiles
    GuidAll     = '{8a3d5f7b-1c2e-4b9a-8f6d-3e7c1a5b9d02}'
    GuidSession = '{c1a0de5e-5e55-4d0a-9c1a-0de5e55e0001}'
    GuidResume  = '{c1a0de5e-5e55-4d0a-9c1a-0de5e55e0002}'
    GuidNew     = '{c1a0de5e-5e55-4d0a-9c1a-0de5e55e0003}'
}
$SR.Sessions = Join-Path $SR.Root 'sessions'
$SR.State    = Join-Path $SR.Root 'install-state.json'   # user's original WT settings we replaced
$SR.Config   = Join-Path $SR.Root 'config.json'          # user options, e.g. { "autoRestore": true }
$SR.Log      = Join-Path $SR.Root 'events.log'           # one line per start/end/close-check/restore decision

# Append a timestamped line to events.log: "<time> <event> <session id> <details>"
function Write-SrLog([string]$Event, [string]$Id = '-', [string]$Detail = '') {
    try { Add-Content $SR.Log ("{0} {1,-9} {2} {3}" -f (Get-Date -Format s), $Event, $Id, $Detail).TrimEnd() -Encoding utf8 } catch {}
}

# Session ids currently open in some Claude process (via `--resume <id>` / `-r <id>` on its command line),
# so restore never opens a second copy of a session that is already running
function Get-RunningSessionIds {
    $ids = @{}
    Get-CimInstance Win32_Process -Filter "Name='claude.exe' OR Name='node.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($m in [regex]::Matches("$($_.CommandLine)", '(?:--resume|-r)[ =]"?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')) {
            $ids[$m.Groups[1].Value] = $_.ProcessId
        }
    }
    $ids
}

# User options. Keeps every key in config.json (so unknown/future options survive a re-install) and
# normalises known ones; a missing or unreadable file means defaults.
function Get-SrConfig {
    $c = [ordered]@{}
    if (Test-Path $SR.Config) {
        try {
            $f = Get-Content $SR.Config -Raw | ConvertFrom-Json -AsHashtable
            foreach ($k in $f.Keys) { $c[$k] = $f[$k] }
        } catch {}
    }
    # Hand edits like "false" / "off" must not count as true
    $c.autoRestore = if ($c.Contains('autoRestore')) {
        if ($c.autoRestore -is [bool]) { $c.autoRestore } else { "$($c.autoRestore)" -match '^(true|on|yes|1)$' }
    } else { $true }
    $c
}

# Is this Windows Terminal newTabMenu the one install.ps1 wrote (vs the user's own)?
function Test-OurNewTabMenu($menu) { [bool]($menu -and (@($menu).profile -contains $SR.GuidNew)) }

# True if the Claude process recorded in a session entry is still running (pid + start time, so a reused pid doesn't count)
function Test-SessionAlive($s) {
    $p = Get-Process -Id $s.pid -ErrorAction SilentlyContinue
    [bool]($p -and [math]::Abs(([DateTimeOffset]$p.StartTime).ToUnixTimeSeconds() - $s.pidStart) -le 5)
}

# Housekeeping (run from the SessionStart hook): orphaned .seq files and cap events.log.
# Lost sessions themselves are never removed automatically.
function Invoke-SrHousekeeping {
    Get-ChildItem $SR.Sessions -Filter *.seq -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force
    Remove-Item (Join-Path $SR.Root 'end.log') -Force -ErrorAction SilentlyContinue   # pre-events.log name
    $log = $SR.Log
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 256KB) {
        $keep = Get-Content $log -Tail 1000; Set-Content $log $keep -Encoding utf8
    }
}
$SR.Guids    = @($SR.GuidAll, $SR.GuidSession, $SR.GuidResume, $SR.GuidNew)

# Windows Terminal settings files that exist (Store, Preview, unpackaged)
function Get-WtSettingsPaths {
    @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    ) | Where-Object { Test-Path $_ }
}

# Write JSON; keeps a one-time original backup (.pre-session-restore.bak) plus a rolling .bak
function Save-Json($obj, $path) {
    if (Test-Path $path) {
        $orig = "$path.pre-session-restore.bak"
        if (-not (Test-Path $orig)) { Copy-Item $path $orig }
        Copy-Item $path "$path.bak" -Force
    }
    $obj | ConvertTo-Json -Depth 32 | Set-Content $path -Encoding utf8
}

# Escape a value for a wt.exe command line: ';' separates wt subcommands, and a trailing '\'
# would escape the closing quote ("C:\" -> "C:\.")
function ConvertTo-WtArg([string]$s) {
    if ($s.EndsWith('\')) { $s += '.' }
    '"' + ($s -replace '"', '' -replace ';', '\;') + '"'
}
