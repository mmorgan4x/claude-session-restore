# claude-session-restore

Reopens your Claude Code sessions in Windows Terminal after a crash, in their original tabs, folders and order.

## How it works

- **Tracking** – Claude Code `SessionStart`/`SessionEnd` hooks record each session running in Windows Terminal (`~/.claude/session-tracker/sessions/`).
- **Like Chrome:** closing a single tab (X, `/exit`, Ctrl+D) forgets that session. Closing the whole window or a crash keeps all its sessions for restore. (After a non-clean exit, a detached check waits a few seconds: if Windows Terminal is still running, only the tab was closed.)
- **Restore** – when Windows Terminal starts, the first tab resumes the first crashed session (`claude --resume <id>`) and the rest open as new tabs to its right, named after the session. Clicking **+** is untouched.
  - Sessions active in the last 12h restore automatically; older ones prompt y/N.
  - Sessions with no messages are skipped (nothing to resume).
- **Profiles** (in the **+** dropdown):
  - *Claude: New* – starts a new `claude` session.
  - *Claude: Resume* – runs `claude --resume` (Claude's session picker).
  - *Claude: Restore Previous Sessions* – restore every session lost to a crash or window close, no age limit.

## Requirements

Windows, Windows Terminal, PowerShell 7 (`pwsh`), Claude Code (native or npm install).

## Install

```powershell
irm https://raw.githubusercontent.com/mmorgan4x/claude-session-restore/main/install.ps1 | iex
```

Restart Windows Terminal. Run the same line again to update.

Or from a clone: `pwsh -File install.ps1`.

Before the first change, `~/.claude/settings.json` and the Windows Terminal `settings.json` are backed up once to `settings.json.pre-session-restore.bak` (plus a rolling `settings.json.bak` on every run).

Install replaces Windows Terminal's `startupActions` and turns off "reopen previous session" (it would duplicate restored tabs). It warns when it does, and `uninstall.ps1` puts your originals back. The Windows Terminal settings file is rewritten, so comments in it are dropped.

## Uninstall

```powershell
pwsh -File ~/.claude/session-tracker/uninstall.ps1        # -KeepData to keep session data
```

## License

[MIT](LICENSE)

## Files

| Path | Purpose |
|---|---|
| `src/common.ps1` | Shared paths, profile GUIDs, helpers |
| `src/hook.ps1` | Hook: registers session on start, removes on clean exit |
| `src/restore.ps1` | Restores crashed sessions (`-List`, `-Last`, `-All`, `-UseTab`, `-Hours N`) |
| `src/closecheck.ps1` | Decides tab-close vs window-close/crash after a session ends |
| `install.ps1` / `uninstall.ps1` | Setup |

The profile icon is copied from your installed Claude Desktop app at install time (re-run `install.ps1` to refresh). Without Claude Desktop, the profiles use the default icon.

