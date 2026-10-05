# claude-account-switcher

Bill a Claude Code session to a different Claude subscription, per project or on demand, inside **one** Claude Desktop app. No logout, no restart, no second copy of the app.

- A project folder with `.claude/account` containing `vbp` bills every session opened there to the account named `vbp`.
- `/account <name>` switches the current session from its next message; `/account off` returns it to the app's own login; `/account` shows status.
- The status line reads `💳 billing: VBP` whenever a session is routed. If the relay is down or has no token for the name, the session stays on the app's login and the status line says so.

## How it works

Claude Desktop hands every Code session a login ticket for the account the app is signed into, and the engine keeps that ticket in memory, so environment tricks do not change it. What the engine *does* read per request is where to send the request (`ANTHROPIC_BASE_URL`). This project uses that:

1. **Relay** (`relay/relay.py`): a loopback-only HTTP relay on `127.0.0.1:48620`. A request to `/acct/<name>/v1/...` is forwarded to `api.anthropic.com/v1/...` with the Authorization header replaced by `<name>`'s long-lived token. Responses stream back unchanged. It never logs a token.
2. **Plugin** (`plugin/`): a Claude Code hooks module that, when a marker or `/account` names an account, points the session at the relay path for that account and keeps the status line honest. It never reads a token; it learns which accounts exist, and when their tokens expire, from the relay's heartbeat file.
3. **Tokens** (`~/.claude/account-switcher/tokens.json`): one long-lived token per account from `claude setup-token` (one browser approval, valid one year, model requests only). Same protection level as Claude Code's own `.credentials.json`.

What stays on the app's own login: everything the app does itself (its panes, artifacts, scheduled tasks) and, inside a routed session, the claude.ai connector list, cloud routines and Remote Control, because the swapped ticket is model-only by design.

## Install (Windows, current user)

```powershell
git clone <this repo> C:\Projects\claude-account-switcher
C:\Projects\claude-account-switcher\scripts\install.ps1
C:\Projects\claude-account-switcher\scripts\add-account.ps1 -Name vbp     # browser opens: sign in as that account, approve
```

`install.ps1` copies the plugin and relay to `~/.claude/account-switcher`, adds `CLAUDE_CODE_PLUGIN_DIRS` to the `env` block of `~/.claude/settings.json` (backup kept), registers the per-user scheduled task `ClaudeAccountRelay` (starts at logon, 5-minute self-recovery) and starts it. Open a new Claude Code session afterwards; existing sessions do not load the plugin.

Requirements: Claude Code 2.1.280 or later (for `CLAUDE_CODE_PLUGIN_DIRS`), Python 3 (`pythonw.exe`), a Claude Pro/Max/Team/Enterprise subscription per account.

## Use

- Put `.claude/account` with the account name in any project that should bill another account.
- In a session: `/account`, `/account vbp`, `/account off`.
- Renew a token near expiry (the status line warns at 14 days): `scripts\add-account.ps1 -Name <name>` again.
- Remove: `scripts\uninstall.ps1` (`-PurgeTokens` to delete the token store too).

## Limits and notes

- Windows installer only for now; the relay and plugin are platform-neutral (a launchd/systemd unit is the missing piece for macOS/Linux).
- A routed session's rate-limit meters in the status line are the routed account's. The app's own usage tray still shows the app's login.
- Tokens are the user's own subscription tokens on the user's own machine; sharing them is outside what this tool is for.

See `TECHNICAL-GUIDE.md` for the full design, what was tried and rejected, and the evidence; `USER-GUIDE.md` for the plain-language version.
