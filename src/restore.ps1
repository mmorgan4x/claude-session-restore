# Reopens Claude Code sessions that died without a clean exit (crash, closed tab).
#   restore.ps1            restore dead sessions active in last 12h; ask about older ones
#   restore.ps1 -All       restore every dead session without asking
#   restore.ps1 -List      just list tracked sessions
#   restore.ps1 -Last      resume the most recent dead session in this tab
#   -UseTab                resume the first session in this tab, rest in new tabs (used by WT startup / restore-all profile)
param([switch]$All, [switch]$List, [switch]$Last, [switch]$UseTab, [int]$Hours = 12)

$root = Join-Path $HOME '.claude\session-tracker'
$dir  = Join-Path $root 'sessions'
if (-not (Test-Path $dir)) { return }
$files = @(Get-ChildItem $dir -Filter *.json)
if (-not $files) { if ($List) { 'No tracked sessions.' }; return }

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
        $hasTranscript = $s.transcript -and (Test-Path $s.transcript)
        # Dead session that never got a message: nothing to resume, drop it
        if (-not $alive -and -not $hasTranscript -and -not $List) { Remove-Item $f.FullName -Force; continue }
        $lastActive = if ($hasTranscript) { (Get-Item $s.transcript).LastWriteTime }
                else { [DateTimeOffset]::FromUnixTimeSeconds($s.started).LocalDateTime }
        # Session name: /rename title wins, else Claude's auto title
        $name = ''
        if ($hasTranscript) {
            $custom = Select-String -Path $s.transcript -Pattern '"type":"custom-title","customTitle":"((?:[^"\\]|\\.)*)"' | Select-Object -Last 1
            $ai     = if (-not $custom) { Select-String -Path $s.transcript -Pattern '"type":"ai-title","aiTitle":"((?:[^"\\]|\\.)*)"' | Select-Object -Last 1 }
            $m = if ($custom) { $custom } else { $ai }
            if ($m) { $name = [regex]::Unescape($m.Matches[0].Groups[1].Value) }
        }
        [pscustomobject]@{ File = $f.FullName; Id = $s.sessionId; Name = $name; Cwd = $s.cwd; Last = $lastActive; Started = [long]$s.started; Alive = $alive }
    }

    if ($List) {
        $sessions | Sort-Object Last -Descending | Format-Table @{n='State';e={ if ($_.Alive) {'open'} else {'dead'} }}, Last, Name, Cwd, Id -AutoSize
        return
    }

    # Sort by original start time = the order the tabs were opened (left to right)
    $dead = @($sessions | Where-Object { -not $_.Alive } | Sort-Object Started)

    if ($Last) {
        $s = $dead | Sort-Object Last | Select-Object -Last 1
        if (-not $s) { Write-Host 'Claude: no crashed sessions to restore.' -ForegroundColor Yellow; return }
        Remove-Item $s.File -Force
        Set-Content (Join-Path $dir "$($s.Id).seq") $s.Started
        $lock.Close(); $lock = $null
        Write-Host "Claude: resuming '$($s.Name)' in $($s.Cwd)" -ForegroundColor Green
        Set-Location $s.Cwd
        $Host.UI.RawUI.WindowTitle = if ($s.Name) { $s.Name } else { Split-Path $s.Cwd -Leaf }
        claude --resume $s.Id
        return
    }

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
        Remove-Item $s.File -Force   # re-registers itself when it starts
        if (-not (Test-Path $s.Cwd)) { Write-Host "Skipped (folder gone): $($s.Cwd)" -ForegroundColor Red; continue }
        # keep original start time so tab order survives repeated restores
        Set-Content (Join-Path $dir "$($s.Id).seq") $s.Started
        $count++
        if ($UseTab -and -not $here) { $here = $s; continue }
        $title = if ($s.Name) { $s.Name -replace '[";]', '' } else { Split-Path $s.Cwd -Leaf }
        $tabs += "nt -p `"{c1a0de5e-5e55-4d0a-9c1a-0de5e55e0001}`" --title `"$title`" -d `"$($s.Cwd)`" pwsh -NoExit -Command claude --resume $($s.Id)"
    }
    # one wt call so tabs are created in order
    if ($tabs) { Start-Process wt.exe -ArgumentList ("-w 0 " + ($tabs -join ' ; ')) }
    if ($count) { Write-Host "Claude: restored $count session(s)." -ForegroundColor Green }
    if ($here) {
        $lock.Close(); $lock = $null
        Set-Location $here.Cwd
        $Host.UI.RawUI.WindowTitle = if ($here.Name) { $here.Name } else { Split-Path $here.Cwd -Leaf }
        claude --resume $here.Id
    }
}
finally { if ($lock) { $lock.Close() } }
