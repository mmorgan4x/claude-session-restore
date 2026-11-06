# Shared constants/helpers for install.ps1, uninstall.ps1, hook.ps1, restore.ps1 (dot-sourced).

$SR = @{
    Root        = Join-Path $HOME '.claude\session-restore'
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
# Claude Code hook event -> hook.ps1 argument
$SR.HookEvents = [ordered]@{ SessionStart = 'start'; SessionEnd = 'end' }

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

# True if the Windows Terminal process that hosted a session entry is still running
function Test-WtAlive($s) {
    if (-not $s.wtPid) { return $false }
    $p = Get-Process -Id $s.wtPid -ErrorAction SilentlyContinue
    [bool]($p -and [math]::Abs(([DateTimeOffset]$p.StartTime).ToUnixTimeSeconds() - $s.wtStart) -le 5)
}

# The Claude Code process this hook runs under (native claude.exe, or node.exe for npm installs), or $null.
# Uses Process.Parent (fast) rather than CIM: the SessionEnd hook runs while the console is closing.
function Get-OwningClaude {
    $p = Get-Process -Id $PID
    for ($i = 0; $i -lt 12 -and $p; $i++) {
        if ($p.ProcessName -like 'claude*' -or ($p.ProcessName -eq 'node' -and $p.CommandLine -match 'claude')) { return $p }
        $p = $p.Parent
    }
    $null
}

# The Windows Terminal process directly hosting $claude, or $null. Only shells/console hosts may sit in
# between: if Claude runs inside another app launched from a WT tab (VS Code, a new console window), that app
# owns it and WT closing must not make it look orphaned.
function Get-WtHost($claude) {
    $shells = 'pwsh', 'powershell', 'cmd', 'bash', 'sh', 'zsh', 'wsl', 'OpenConsole', 'conhost'
    $p = $claude.Parent
    for ($i = 0; $i -lt 8 -and $p; $i++) {
        if ($p.ProcessName -eq 'WindowsTerminal') { return $p }
        if ($p.ProcessName -notin $shells) { return $null }
        $p = $p.Parent
    }
    $null
}

# Stop orphaned Claude processes with their whole tree (MCP servers, dev servers, shells), wait for them once,
# and return the pids that are still running
function Stop-ClaudeTree([int[]]$Pids) {
    foreach ($id in $Pids) { & taskkill.exe /T /F /PID $id 2>&1 | Out-Null }
    Wait-Process -Id $Pids -Timeout 3 -ErrorAction SilentlyContinue
    @($Pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
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
