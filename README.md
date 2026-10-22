# claude-account-switcher

Bill a Claude Code session to a different Claude subscription, per project or on demand, inside **one** Claude Desktop app or one terminal. No logout, no restart, no second copy of the app.

- A project folder with `.claude/account` containing `work` bills every session opened there to the account named `work`.
- Every other session starts in **auto**: it bills whichever account has the most usage left, and moves to another one by itself when that account is nearly full (95 % of its 5-hour or weekly limit, or the API says the limit is reached).
- A band above the prompt shows the account in force, an `auto` button, and one button per account that has a token, each with how full that account is (`work 32%`). One click on an account holds the session there from its next message (auto never moves it); `auto` hands the choice back; `off` returns it to the app's own login; `hide` puts the band away (remembered; `/account show` brings it back).
- `/account <name>`, `/account auto` and `/account off` do the same by keyboard; `/account` shows status, token expiry and each account's real usage meters.
- The status line reads `💳 billing: WORK` whenever a session is routed. If the relay is down or has no token for the name, the session stays on the app's login and the status line says so.

| Platform | Installer | Service | Status |
|---|---|---|---|
| Windows | `scripts\install.ps1` | per-user scheduled task `ClaudeAccountRelay` | in daily use with Claude Desktop |
| Linux | `scripts/install.sh` | `systemd --user` unit `claude-account-relay.service` | tested end to end (Pop!_OS 24.04, Claude Code 2.1.281) |
| macOS | `scripts/install.sh` | LaunchAgent `com.claude-account-switcher.relay` | **untested**: written to the launchd docs and shellcheck-clean, but no Mac was available |

On Linux there is no Claude Desktop app, so the switcher there applies to terminal Claude Code only. On Windows and macOS it covers both the Desktop app's Code sessions and the terminal.

## How it works

Claude Desktop hands every Code session a login ticket for the account the app is signed into, and the engine keeps that ticket in memory, so environment tricks do not change it. What the engine *does* read per request is where to send the request (`ANTHROPIC_BASE_URL`). This project uses that:

1. **Relay** (`relay/relay.py`): a loopback-only HTTP relay on `127.0.0.1:48620`. A request to `/acct/<name>/v1/...` is forwarded to `api.anthropic.com/v1/...` with the Authorization header replaced by `<name>`'s long-lived token. Responses stream back unchanged. It never logs a token. It notes each account's usage from the API's reply headers, and every 2 minutes it sends a 1-token message for any account that had no reply in that time, so every account's usage stays current even when nothing is using it.
2. **Plugin** (`plugin/`): a Claude Code hooks module that points the session at the relay path for the account a marker, a click, `/account` or auto chose, and keeps the status line honest. It never reads a token; it learns which accounts exist, when their tokens expire and what their usage meters say from the relay's heartbeat file.
3. **Tokens** (`~/.claude/account-switcher/tokens.json`): one long-lived token per account from `claude setup-token` (one browser approval, valid one year, model requests only). Same protection level as Claude Code's own `.credentials.json`.

What stays on the app's own login: everything the app does itself (its panes, artifacts, scheduled tasks) and, inside a routed session, the claude.ai connector list, cloud routines and Remote Control, because the swapped ticket is model-only by design.

## Install

Requirements: Claude Code 2.1.280 or later (for `CLAUDE_CODE_PLUGIN_DIRS`), Python 3.8 or later (standard library only), and a Claude Pro/Max/Team/Enterprise subscription for every account you add.

### Windows (current user)

```powershell
git clone https://github.com/SmelterLabs/claude-account-switcher.git
.\claude-account-switcher\scripts\install.ps1
.\claude-account-switcher\scripts\add-account.ps1 -Name work     # browser opens: sign in as that account, approve
```

Add `-IsolatedBrowser` to sign in through a fresh, empty Chrome (or Edge) window instead of your usual browser, so the sign-in never mixes with the accounts you are logged into there. The window and its temporary profile are removed afterwards.

`install.ps1` copies the plugin and relay to `~/.claude/account-switcher`, adds `CLAUDE_CODE_PLUGIN_DIRS` to the `env` block of `~/.claude/settings.json` (backup kept), registers the per-user scheduled task `ClaudeAccountRelay` (starts at logon, 5-minute self-recovery) and starts it. Needs `pythonw.exe` on the PATH or in the default python.org location.

### Linux (tested) and macOS (untested)

```bash
git clone https://github.com/SmelterLabs/claude-account-switcher.git
./claude-account-switcher/scripts/install.sh
./claude-account-switcher/scripts/add-account.sh work        # browser opens or a sign-in URL is shown; approve
```

`install.sh` copies the plugin and relay to `~/.claude/account-switcher` (mode 700), adds `CLAUDE_CODE_PLUGIN_DIRS` and `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` to the `env` block of `~/.claude/settings.json` (backup kept), registers the relay as a per-user service that starts at login and restarts on failure, starts it and checks the heartbeat:

- Linux: `~/.config/systemd/user/claude-account-relay.service`, enabled for `default.target`. On a headless box that should relay without anyone logged in, run `loginctl enable-linger $USER` once.
- macOS: `~/Library/LaunchAgents/com.claude-account-switcher.relay.plist`, loaded with `launchctl bootstrap gui/<uid>` (falls back to `launchctl load -w`). Python 3 from Homebrew or python.org is preferred over the Xcode stub.

`add-account.sh` runs `claude setup-token` inside a pseudo-terminal (it prints nothing without one), passes your keystrokes through in case Claude Code asks you to paste a code, shows its screen with the token masked, and writes the token straight into `tokens.json` (mode 600). `--isolated` signs in through a fresh, empty Chrome or Chromium window, like `-IsolatedBrowser` on Windows (not yet tried on a Mac or Linux machine).

Open a new Claude Code session afterwards; existing sessions do not load the plugin.

## Use

- Put `.claude/account` with the account name in any project that should bill another account.
- Do nothing, and auto picks the account with the most room for each new session.
- In a session: click an account (or `auto`) in the band above the prompt, or `/account`, `/account work`, `/account auto`, `/account off`, `/account hide`, `/account show`.
- Want auto to use the app's own account too? Add it like any other (for example `add-account.ps1 -Name main`, signed in as the app's account).
- Renew a token near expiry (the status line warns at 14 days): run add-account for that name again.
- Remove: `scripts\uninstall.ps1` / `scripts/uninstall.sh` (`-PurgeTokens` / `--purge-tokens` to delete the token store too).

## Limits and notes

- A routed session's rate-limit meters (`/account`) are the routed account's. The app's own usage tray still shows the app's login.
- Switching account mid-conversation loses nothing: every request carries the whole conversation, so the new account simply continues it. The first reply after a switch reads the conversation fresh (no prompt cache yet), which is why auto only moves when an account is nearly full.
- The usage check costs one 1-token message per idle account every 2 minutes (`PROBE_EVERY` in `relay.py`).
- Hooks-module plugins are early access in the terminal CLI: the terminal needs `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, which `install.sh` sets in `settings.json`. Claude Desktop sets it for its own sessions, so `install.ps1` does not.
- macOS is untested. If you run it there, an issue with the output of `launchctl print gui/$(id -u)/com.claude-account-switcher.relay` is welcome.

## Terms

Every token comes from Anthropic's own `claude setup-token` flow, approved in a browser by the account owner, and every account is that user's own paid Claude subscription. The relay only swaps which of *your* subscriptions a session bills; sharing tokens with other people or machines is outside what this tool is for and may breach Anthropic's terms. Check the terms that apply to your plan before using it.

See `TECHNICAL-GUIDE.md` for the full design, what was tried and rejected, and the evidence; `USER-GUIDE.md` for the plain-language version.
