# Reopens Claude Code sessions lost to a window close or crash, each in a new tab (this tab stays a plain shell).
#   restore.ps1            restore dead sessions active in last 12h; ask about older ones
#   restore.ps1 -All       restore every dead session without asking
#   restore.ps1 -List      just list tracked sessions
#   -Startup               run from Windows Terminal startup; does nothing when autoRestore is off in config.json
param([switch]$All, [switch]$List, [switch]$Startup, [int]$Hours = 12)
. "$PSScriptRoot\common.ps1"

if ($Startup -and -not (Get-SrConfig).autoRestore) { return }
$trigger = if ($Startup) { 'startup' } else { 'profile' }

$root = $SR.Root
$dir  = $SR.Sessions
if (-not (Test-Path $dir)) { return }
$files = @(Get-ChildItem $dir -Filter *.json)
if (-not $files) { if ($List) { 'No tracked sessions.' }; return }

# Session name from transcript, one pass: /rename title wins, else Claude's auto title
function Get-SessionName($transcript) {
    $ms = Select-String -Path $transcript -Pattern '"type":"(custom-title","customTitle|ai-title","aiTitle)":"((?:[^"\\]|\\.)*)"'
    $m = ($ms | Where-Object { $_.Matches[0].Groups[1].Value -like 'custom*' } | Select-Object -Last 1)
    if (-not $m) { $m = $ms | Select-Object -Last 1 }
    if ($m) { [regex]::Unescape($m.Matches[0].Groups[2].Value) } else { '' }
}

# Lock so tabs opening at the same time don't both restore
$lock = $null
try { $lock = [IO.File]::Open((Join-Path $root 'restore.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { return }

try {
    $sessions = foreach ($f in $files) {
        # Unreadable: delete only if it's old (a fresh one may be mid-write)
        try { $s = Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop; if (-not $s.sessionId) { throw } }
        catch { if ($f.LastWriteTime -lt (Get-Date).AddMinutes(-1)) { Remove-Item $f.FullName -Force }; continue }
        $alive = Test-SessionAlive $s
        # Alive but its Windows Terminal is gone: WT was killed and this Claude process is an invisible orphan
        # that lingers for a few seconds. Treat it as lost; it's stopped only right before it is reopened.
        # (wtPid is recorded only when Claude runs directly in a WT shell, so apps launched from WT are safe.)
        $orphan = $alive -and $s.wtPid -and -not (Test-WtAlive $s)
        if ($orphan) { $alive = $false }
        # Dead but its Windows Terminal is still running: only the tab was closed (tabclose-check.ps1 may not
        # have run yet) -> intentional, forget it
        elseif (-not $alive -and (Test-WtAlive $s)) {
            if (-not $List) { Remove-Item $f.FullName -Force; Write-SrLog 'restore' $s.sessionId 'tab was closed, terminal still running -> forgotten' }
            continue
        }
        $hasTranscript = $s.transcript -and (Test-Path -LiteralPath $s.transcript)
        # Dead session that never got a message: nothing to resume, drop it
        if (-not $alive -and -not $orphan -and -not $hasTranscript -and -not $List) { Remove-Item $f.FullName -Force; Write-SrLog 'restore' $s.sessionId 'no messages -> dropped'; continue }
        $lastActive = if ($hasTranscript) { (Get-Item -LiteralPath $s.transcript).LastWriteTime }
                else { [DateTimeOffset]::FromUnixTimeSeconds($s.started).LocalDateTime }
        # Only read transcripts we might show or restore
        $name = if ($hasTranscript -and ($List -or -not $alive)) { Get-SessionName $s.transcript } else { '' }
        [pscustomobject]@{ File = $f.FullName; Id = $s.sessionId; Name = $name; Cwd = $s.cwd; Last = $lastActive; Started = [long]$s.started
                           Alive = $alive; Orphan = [bool]$orphan; Pid = $s.pid; HasTranscript = [bool]$hasTranscript }
    }

    if ($List) {
        $sessions | Sort-Object Last -Descending |
            Format-Table @{n='State';e={ if ($_.Orphan) {'orphan'} elseif ($_.Alive) {'open'} else {'dead'} }}, Last, Name, Cwd, Id -AutoSize
        return
    }

    # Orphan that never got a message: nothing to resume (it dies with its console anyway)
    $sessions = @($sessions | Where-Object {
        if ($_.Orphan -and -not $_.HasTranscript) { Remove-Item $_.File -Force; Write-SrLog 'restore' $_.Id 'orphan with no messages -> dropped'; $false } else { $true }
    })

    # Sort by original start time = the order the tabs were opened (left to right)
    $dead = @($sessions | Where-Object { -not $_.Alive } | Sort-Object Started)

    # Never open a second copy of a session that's already open in another Claude process
    # (e.g. resumed by hand outside Windows Terminal); keep its entry
    if ($dead) {
        $running = Get-RunningSessionIds
        $dead = @($dead | Where-Object {
            # (an orphan's own process doesn't count: it's stopped right before reopening)
            if ($running.ContainsKey($_.Id) -and -not ($_.Orphan -and $running[$_.Id] -eq $_.Pid)) {
                Write-SrLog 'restore' $_.Id "already open (pid $($running[$_.Id])) -> skipped"; $false
            } else { $true }
        })
    }

    if (-not $dead) { if ($All) { Write-Host 'Claude: no crashed sessions to restore.' -ForegroundColor Yellow }; return }

    $cutoff = (Get-Date).AddHours(-$Hours)
    $recent = @($dead | Where-Object { $All -or $_.Last -ge $cutoff })
    $old    = @($dead | Where-Object { -not ($All -or $_.Last -ge $cutoff) })

    if ($old) {
        Write-Host "Claude: $($old.Count) session(s) older than ${Hours}h didn't exit cleanly:" -ForegroundColor Yellow
        $old | ForEach-Object { Write-Host ("  {0:g}  {1}  {2}" -f $_.Last, $_.Name, $_.Cwd) }
        $ans = Read-Host 'Restore them too? [y/N]'
        if ($ans -match '^y') { $recent += $old }
        else { $old | ForEach-Object { Remove-Item $_.File -Force; Write-SrLog 'restore' $_.Id 'older than cutoff, declined -> forgotten' } }
    }

    # Folder missing (unmounted drive, VPN share): keep the entry so it can restore later
    $recent = @($recent | Sort-Object Started | Where-Object {
        if (Test-Path -LiteralPath $_.Cwd) { return $true }
        Write-Host "Claude: folder not found, kept for later: $($_.Cwd)" -ForegroundColor Red
        Write-SrLog 'restore' $_.Id "folder not found ($($_.Cwd)) -> kept"; $false
    })

    # Only now, for orphans that will really be reopened: stop them with their process tree (all at once,
    # one wait). Any that refuse to die are skipped so two copies never run.
    $orphans = @($recent | Where-Object Orphan)
    if ($orphans) {
        $stuck = Stop-ClaudeTree @($orphans.Pid)
        foreach ($o in $orphans) {
            if ($o.Pid -in $stuck) { Write-SrLog 'restore' $o.Id "orphan pid $($o.Pid) could not be stopped -> skipped, kept" }
            else { Write-SrLog 'restore' $o.Id "orphan pid $($o.Pid) (terminal gone) -> stopped with its process tree" }
        }
        $recent = @($recent | Where-Object { -not ($_.Orphan -and $_.Pid -in $stuck) })
    }

    $count = 0
    $tabs = @()
    foreach ($s in $recent) {
        Remove-Item $s.File -Force   # re-registers itself when it starts
        Write-SrLog 'restore' $s.Id "reopened via ${trigger}: $($s.Name)"
        # keep original start time so tab order survives repeated restores
        Set-Content (Join-Path $dir "$($s.Id).seq") $s.Started
        $count++
        $title = if ($s.Name) { $s.Name } else { Split-Path $s.Cwd -Leaf }
        $tabs += "nt -p `"$($SR.GuidSession)`" --title $(ConvertTo-WtArg $title) -d $(ConvertTo-WtArg $s.Cwd) pwsh -NoExit -Command claude --resume $($s.Id)"
    }
    # Stay on the tab you launched from: new tabs are appended after it and the last one takes focus,
    # so step back once per new tab
    if ($tabs) { $tabs += @('ft -p') * $tabs.Count }
    # one wt call so tabs are created in order
    if ($tabs) { Start-Process wt.exe -ArgumentList ("-w 0 " + ($tabs -join ' ; ')) }
    if ($count) { Write-Host "Claude: restored $count session(s)." -ForegroundColor Green }
}
finally { if ($lock) { $lock.Close() } }
