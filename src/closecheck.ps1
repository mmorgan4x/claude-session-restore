# Runs detached after a session ends without a clean exit. If Windows Terminal is still running a few
# seconds later, only the tab was closed (intentional) -> forget the session. If WT is gone, the whole
# window was closed or crashed -> keep it for restore.
param([string]$SessionFile, [int]$WtPid, [long]$WtStart, [int]$ClaudePid)
$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\common.ps1"

Start-Sleep -Seconds 4
$wt = Get-Process -Id $WtPid
$alive = $wt -and [math]::Abs(([DateTimeOffset]$wt.StartTime).ToUnixTimeSeconds() - $WtStart) -le 5
$id = [IO.Path]::GetFileNameWithoutExtension($SessionFile)
# Session reopened meanwhile (new Claude process re-registered it): leave the new entry alone
$cur = Get-Content $SessionFile -Raw | ConvertFrom-Json
if (-not $cur -or $cur.pid -ne $ClaudePid) { exit 0 }
if ($alive) {
    Remove-Item $SessionFile -Force
    Add-Content (Join-Path $SR.Root 'end.log') "$(Get-Date -Format s) $id tab closed (terminal still running) -> forgotten"
} else {
    Add-Content (Join-Path $SR.Root 'end.log') "$(Get-Date -Format s) $id terminal closed -> kept for restore"
}
