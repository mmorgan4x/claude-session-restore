# Claude Code SessionStart/SessionEnd hook: tracks open sessions for crash restore.
# Usage (from settings.json hooks): pwsh -NoProfile -File hook.ps1 start|end
param([string]$Event)
$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\common.ps1"

# Hook input is UTF-8 JSON; console default is the OEM code page
[Console]::InputEncoding = [Text.Encoding]::UTF8
$data = [Console]::In.ReadToEnd() | ConvertFrom-Json
if (-not $data.session_id) { exit 0 }
$dir  = $SR.Sessions
$file = Join-Path $dir "$($data.session_id).json"

if ($Event -eq 'end') {
    $clean = $data.reason -in 'prompt_input_exit', 'clear', 'logout'
    # The entry may belong to another copy of this session (reopened elsewhere); only touch our own
    # (can't tell who we are -> don't touch it either)
    $s  = Get-Content $file -Raw | ConvertFrom-Json
    $me = Get-OwningClaude
    if ($s -and (-not $me -or $s.pid -ne $me.Id)) {
        Write-SrLog 'end' $data.session_id "reason=$($data.reason) from pid $(if ($me) { $me.Id } else { '?' }); entry belongs to pid $($s.pid) -> left alone"
        exit 0
    }
    Write-SrLog 'end' $data.session_id "reason=$($data.reason)$(if ($clean) { ' -> forgotten' } else { ' -> checking' })"
    # Explicit quit: remove now
    if ($clean) { Remove-Item $file -Force; exit 0 }
    # Otherwise the console is closing: either one tab was closed (Windows Terminal keeps running -> intentional,
    # like closing a Chrome tab) or the whole window closed / crashed (WT exits -> keep for restore).
    # Decide a few seconds later from a detached process, since this one dies with the console.
    if ($s.wtPid) {
        Start-Process pwsh -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', "`"$PSScriptRoot\tabclose-check.ps1`"",
            '-SessionFile', "`"$file`"", '-WtPid', $s.wtPid, '-WtStart', $s.wtStart, '-ClaudePid', $s.pid)
    }
    exit 0
}

# Only track sessions running inside Windows Terminal (skip Desktop app, IDEs, etc.)
if (-not $env:WT_SESSION) { exit 0 }

$claude = Get-OwningClaude
if (-not $claude) { exit 0 }
# Hosting Windows Terminal (tells tab-close from window-close/crash); $null if another app sits in between
$wt = Get-WtHost $claude

New-Item -ItemType Directory -Force $dir | Out-Null
# Same session already running in another Claude process? (two copies would diverge and both keep working)
$prev = if (Test-Path $file) { try { Get-Content $file -Raw | ConvertFrom-Json } catch {} }
$dup = $prev -and $prev.pid -ne $claude.Id -and (Test-SessionAlive $prev)
Write-SrLog 'start' $data.session_id ("source=$($data.source) pid=$($claude.Id) cwd=$($data.cwd)" + $(if (-not $wt) { ' (not directly in WT)' } else { '' }) +
    $(if ($dup) { " DUPLICATE: already running as pid $($prev.pid)" } else { '' }))
# Restored session: keep its original start time (tab order)
$seq = Join-Path $dir "$($data.session_id).seq"
$started = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (Test-Path $seq) { $started = [long](Get-Content $seq -Raw); Remove-Item $seq -Force }
[pscustomobject]@{
    sessionId  = $data.session_id
    cwd        = $data.cwd
    transcript = $data.transcript_path
    pid        = $claude.Id
    pidStart   = ([DateTimeOffset]$claude.StartTime).ToUnixTimeSeconds()
    started    = $started
    wtPid      = if ($wt) { $wt.Id } else { $null }
    wtStart    = if ($wt) { ([DateTimeOffset]$wt.StartTime).ToUnixTimeSeconds() } else { $null }
} | ConvertTo-Json | Set-Content "$file.tmp" -Encoding utf8
# Atomic replace so restore.ps1 never reads a half-written file
Move-Item "$file.tmp" $file -Force

Invoke-SrHousekeeping
exit 0
