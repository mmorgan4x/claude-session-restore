# Reopens Claude Code sessions that died without a clean exit (crash, closed tab).
#   restore.ps1            restore dead sessions active in last 12h; ask about older ones
#   restore.ps1 -All       restore every dead session without asking
#   restore.ps1 -List      just list tracked sessions
#   -UseTab                resume the first session in this tab, rest in new tabs (used by WT startup / restore-all profile)
#   -Startup               run from Windows Terminal startup; does nothing when autoRestore is off in config.json
param([switch]$All, [switch]$List, [switch]$UseTab, [switch]$Startup, [int]$Hours = 12)
. "$PSScriptRoot\common.ps1"

if ($Startup -and -not (Get-SrConfig).autoRestore) { return }

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

function Start-Here($s) {
    Write-Host "Claude: resuming '$($s.Name)' in $($s.Cwd)" -ForegroundColor Green
    Set-Location -LiteralPath $s.Cwd
    $Host.UI.RawUI.WindowTitle = if ($s.Name) { $s.Name } else { Split-Path $s.Cwd -Leaf }
    claude --resume $s.Id
}

# Lock so tabs opening at the same time don't both restore
$lock = $null
try { $lock = [IO.File]::Open((Join-Path $root 'restore.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { return }

try {
    $sessions = foreach ($f in $files) {
        try { $s = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { Remove-Item $f.FullName -Force; continue }
        $alive = $false
        $proc = Get-Process -Id $s.pid -ErrorAction SilentlyContinue
        if ($proc) {
            $ps = ([DateTimeOffset]$proc.StartTime).ToUnixTimeSeconds()
            if ([math]::Abs($ps - $s.pidStart) -le 5) { $alive = $true }
        }
        # Dead but its Windows Terminal is still running: only the tab was closed (closecheck.ps1 may not
        # have run yet) -> intentional, forget it
        if (-not $alive -and $s.wtPid) {
            $wt = Get-Process -Id $s.wtPid -ErrorAction SilentlyContinue
            if ($wt -and [math]::Abs(([DateTimeOffset]$wt.StartTime).ToUnixTimeSeconds() - $s.wtStart) -le 5) {
                if (-not $List) { Remove-Item $f.FullName -Force }
                continue
            }
        }
        $hasTranscript = $s.transcript -and (Test-Path -LiteralPath $s.transcript)
        # Dead session that never got a message: nothing to resume, drop it
        if (-not $alive -and -not $hasTranscript -and -not $List) { Remove-Item $f.FullName -Force; continue }
        $lastActive = if ($hasTranscript) { (Get-Item -LiteralPath $s.transcript).LastWriteTime }
                else { [DateTimeOffset]::FromUnixTimeSeconds($s.started).LocalDateTime }
        # Only read transcripts we might show or restore
        $name = if ($hasTranscript -and ($List -or -not $alive)) { Get-SessionName $s.transcript } else { '' }
        [pscustomobject]@{ File = $f.FullName; Id = $s.sessionId; Name = $name; Cwd = $s.cwd; Last = $lastActive; Started = [long]$s.started; Alive = $alive }
    }

    if ($List) {
        $sessions | Sort-Object Last -Descending | Format-Table @{n='State';e={ if ($_.Alive) {'open'} else {'dead'} }}, Last, Name, Cwd, Id -AutoSize
        return
    }

    # Sort by original start time = the order the tabs were opened (left to right)
    $dead = @($sessions | Where-Object { -not $_.Alive } | Sort-Object Started)

    if (-not $dead) { if ($All) { Write-Host 'Claude: no crashed sessions to restore.' -ForegroundColor Yellow }; return }

    $cutoff = (Get-Date).AddHours(-$Hours)
    $recent = @($dead | Where-Object { $All -or $_.Last -ge $cutoff })
    $old    = @($dead | Where-Object { -not ($All -or $_.Last -ge $cutoff) })

    if ($old) {
        Write-Host "Claude: $($old.Count) session(s) older than ${Hours}h didn't exit cleanly:" -ForegroundColor Yellow
        $old | ForEach-Object { Write-Host ("  {0:g}  {1}  {2}" -f $_.Last, $_.Name, $_.Cwd) }
        $ans = Read-Host 'Restore them too? [y/N]'
        if ($ans -match '^y') { $recent += $old } else { $old | ForEach-Object { Remove-Item $_.File -Force } }
    }

    $recent = @($recent | Sort-Object Started)
    $here = $null   # session to resume in this tab (with -UseTab)
    $count = 0
    $tabs = @()
    foreach ($s in $recent) {
        # Folder missing (unmounted drive, VPN share): keep the entry so it can restore later
        if (-not (Test-Path -LiteralPath $s.Cwd)) { Write-Host "Claude: folder not found, kept for later: $($s.Cwd)" -ForegroundColor Red; continue }
        Remove-Item $s.File -Force   # re-registers itself when it starts
        # keep original start time so tab order survives repeated restores
        Set-Content (Join-Path $dir "$($s.Id).seq") $s.Started
        $count++
        if ($UseTab -and -not $here) { $here = $s; continue }
        $title = if ($s.Name) { $s.Name } else { Split-Path $s.Cwd -Leaf }
        $tabs += "nt -p `"$($SR.GuidSession)`" --title $(ConvertTo-WtArg $title) -d $(ConvertTo-WtArg $s.Cwd) pwsh -NoExit -Command claude --resume $($s.Id)"
    }
    # one wt call so tabs are created in order
    if ($tabs) { Start-Process wt.exe -ArgumentList ("-w 0 " + ($tabs -join ' ; ')) }
    if ($count) { Write-Host "Claude: restored $count session(s)." -ForegroundColor Green }
    if ($here) {
        $lock.Close(); $lock = $null
        Start-Here $here
    }
}
finally { if ($lock) { $lock.Close() } }
