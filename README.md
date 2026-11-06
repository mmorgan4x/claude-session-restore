# claude-session-restore

Reopens your Claude Code sessions in Windows Terminal after a crash, in their original tabs, folders and order.

## How it works

- **Tracking** – Claude Code `SessionStart`/`SessionEnd` hooks record each session running in Windows Terminal (`~/.claude/session-restore/sessions/`).
- **Like Chrome:** closing a single tab (X, `/exit`, Ctrl+D) forgets that session. Closing the whole window or a crash keeps all its sessions for restore. (After a non-clean exit, a detached check waits a few seconds: if Windows Terminal is still running, only the tab was closed.)
- **Restore** – when Windows Terminal starts, your first tab stays a normal shell and each lost session (`claude --resume <id>`) opens in a new tab to its right, named after the session. Focus stays on your first tab. Clicking **+** is untouched.
  - Sessions active in the last 12h restore automatically; older ones prompt y/N.
  - Sessions with no messages are skipped (nothing to resume).
  - Sessions already open in another Claude process are skipped, so restore never opens a second copy.
- **Profiles** (in the **+** dropdown, below a separator after your profiles):
  - *Claude: New* – starts a new `claude` session.
  - *Claude: Resume* – runs `claude --resume` (Claude's session picker).
  - *Claude: Restore Previous Sessions* – restore every session lost to a crash or window close, no age limit.

## Requirements

Windows, Windows Terminal, PowerShell 7 (`pwsh`), Claude Code (native or npm install).

## Install

```powershell
irm https://raw.githubusercontent.com/mmorgan4x/claude-session-restore/main/install.ps1 | iex
```

Restart Windows Terminal. Run the same line again to update. From a clone: `pwsh -File install.ps1`.

### Turn auto-restore on/off

Re-run the installer with `-AutoRestore off` (or `on`). Sessions are still tracked, so *Claude: Restore Previous Sessions* keeps working; only the restore on Windows Terminal startup is skipped, and the first tab goes back to your default profile. Updating without the flag keeps your choice.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mmorgan4x/claude-session-restore/main/install.ps1))) -AutoRestore off
```

From a clone: `pwsh -File install.ps1 -AutoRestore off`. The setting lives in `~/.claude/session-restore/config.json`.


Before the first change, `~/.claude/settings.json` and the Windows Terminal `settings.json` are backed up once to `settings.json.pre-session-restore.bak` (plus a rolling `settings.json.bak` on every run).

Install replaces Windows Terminal's `startupActions` and `newTabMenu` (the **+** dropdown layout) and turns off "reopen previous session" (it would duplicate restored tabs). It warns when it does, and `uninstall.ps1` puts your originals back. If you edit the **+** menu after installing, updates keep your edits. The Windows Terminal settings file is rewritten, so comments in it are dropped.

## Optional setup

- **Launch Windows Terminal on login** – Settings › Startup › *Launch on machine startup*, then Save. With auto-restore on, this brings back crashed sessions after a reboot. (Setting `"startOnUserLogin": true` in settings.json alone isn't enough: the Windows startup task stays disabled until it's toggled in the Settings UI or under Windows Settings › Apps › Startup.)
- **Make + open Claude** – Settings › Startup › *Default profile* › *Claude: New*. The first tab at startup still uses your shell profile for the restore.
- **Start Claude in a project folder** – run the installer with `-StartIn C:\path\to\projects` (or set *Starting directory* on *Claude: New* / *Claude: Resume* yourself). Updates keep it, along with any other changes you make to the Claude profiles (color scheme, font, ...); the installer only manages their name, command line, icon and visibility.

## Uninstall

```powershell
pwsh -File ~/.claude/session-restore/uninstall.ps1        # -KeepData to keep session data
```

## Files

| Path | Purpose |
|---|---|
| `src/common.ps1` | Shared paths, profile GUIDs, helpers |
| `src/hook.ps1` | Hook: registers session on start, removes on clean exit |
| `src/restore.ps1` | Restores crashed sessions (`-List`, `-All`, `-Startup`, `-Hours N`) |
| `src/tabclose-check.ps1` | Decides tab-close vs window-close/crash after a session ends |
| `install.ps1` / `uninstall.ps1` | Setup |

The profile icon is copied from your installed Claude Desktop app (Store or standalone install) at install time (re-run `install.ps1` to refresh). Without Claude Desktop, the profiles use the default icon.


## Limitations

- Tabs restore in the order the sessions were opened. Rearranging tabs by dragging isn't tracked (Windows Terminal doesn't expose tab positions).
- Everything restores into one window.
- Only Claude sessions restore, not plain shell tabs.

## Log

`~/.claude/session-restore/events.log` has one line per session start/end, close check and restore decision (why each session was reopened, kept, skipped or forgotten). A start line marked `DUPLICATE` means the same session was opened in two places.

## License

[MIT](LICENSE)
