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
    Add-Content (Join-Path $SR.Root 'end.log') "$(Get-Date -Format s) $($data.session_id) reason=$($data.reason)"
    # Only an explicit quit removes the session; anything else (tab closed, terminal crash) stays restorable
    if ($data.reason -in 'prompt_input_exit', 'clear', 'logout') { Remove-Item $file -Force }
    exit 0
}

# Only track sessions running inside Windows Terminal (skip Desktop app, IDEs, etc.)
if (-not $env:WT_SESSION) { exit 0 }

# Walk up the process tree to the owning Claude Code process (native claude.exe, or node.exe for npm installs)
$p = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$claude = $null
for ($i = 0; $i -lt 12 -and $p; $i++) {
    if ($p.Name -like 'claude*' -or ($p.Name -eq 'node.exe' -and $p.CommandLine -match 'claude')) { $claude = $p; break }
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)"
}
if (-not $claude) { exit 0 }

New-Item -ItemType Directory -Force $dir | Out-Null
# Restored session: keep its original start time (tab order)
$seq = Join-Path $dir "$($data.session_id).seq"
$started = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (Test-Path $seq) { $started = [long](Get-Content $seq -Raw); Remove-Item $seq -Force }
[pscustomobject]@{
    sessionId  = $data.session_id
    cwd        = $data.cwd
    transcript = $data.transcript_path
    pid        = $claude.ProcessId
    pidStart   = ([DateTimeOffset]$claude.CreationDate).ToUnixTimeSeconds()
    started    = $started
} | ConvertTo-Json | Set-Content $file -Encoding utf8
exit 0
