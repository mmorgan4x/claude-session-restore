# claude-session-restore

Reopens your Claude Code sessions in Windows Terminal after a crash, in their original tabs, folders and order.

## How it works

- **Tracking** – Claude Code `SessionStart`/`SessionEnd` hooks record each session running in Windows Terminal (`~/.claude/session-tracker/sessions/`).
- **Clean exit** (`/exit`, Ctrl+D, `/clear`, logout) removes the session. Anything else (terminal crash, tab closed with X) leaves it restorable.
- **Restore** – when Windows Terminal starts, the first tab resumes the first crashed session (`claude --resume <id>`) and the rest open as new tabs to its right, named after the session. Clicking **+** is untouched.
  - Sessions active in the last 12h restore automatically; older ones prompt y/N.
  - Sessions with no messages are skipped (nothing to resume).
- **Profiles** (in the **+** dropdown):
  - *Restore Last Claude Session* – resume the most recent crashed session in that tab.
  - *Restore All Claude Sessions* – restore every crashed session, no age limit.

## Requirements

Windows, Windows Terminal, PowerShell 7 (`pwsh`), Claude Code.

## Install

```powershell
git clone https://github.com/mmorgan4x/claude-session-restore
pwsh -File claude-session-restore\install.ps1
```

Restart Windows Terminal. Re-run `install.ps1` to update.

Both `~/.claude/settings.json` and the Windows Terminal `settings.json` are backed up to `settings.json.bak` before changes. Note: the Windows Terminal settings file is rewritten, so comments in it are dropped.

## Uninstall

```powershell
pwsh -File claude-session-restore\uninstall.ps1            # -KeepData to keep ~/.claude/session-tracker
```

## Files

| Path | Purpose |
|---|---|
| `src/hook.ps1` | Hook: registers session on start, removes on clean exit |
| `src/restore.ps1` | Restores crashed sessions (`-List`, `-Last`, `-All`, `-UseTab`, `-Hours N`) |
| `src/claude.png` | Profile/tab icon |
| `install.ps1` / `uninstall.ps1` | Setup |
