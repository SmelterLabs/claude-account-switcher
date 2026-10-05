# claude-account-switcher — Technical Guide

Briefing for anyone (or any model) picking this up cold. Built 2026-10-04 on Casey's PC against Claude Code 2.1.286 and Claude Desktop 2.19675.0 (Windows).

## What it is

Three small parts that let one Claude Desktop app bill Code sessions to different Claude subscriptions:

| Part | Where (installed) | Job |
|---|---|---|
| Relay `relay.py` | `~/.claude/account-switcher/relay.py`, scheduled task `ClaudeAccountRelay` | Loopback HTTP relay on `127.0.0.1:48620`. `/acct/<name>/<path>` → `https://api.anthropic.com/<path>` with `Authorization: Bearer <name's token>`. Streams responses. Writes `relay.alive` every 10 s (port, pid, time, account names, expiry per name). Logs account/method/path/status/bytes/seconds to `relay.log`; never a token. |
| Plugin `plugin/` | `~/.claude/account-switcher/plugin`, loaded via `CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json` `env` | Hooks module. At `session.start` reads the marker (`<cwd>/.claude/account`, then `<session root>/.claude/account`), registers `/account`. At `session.start`, `turn.start`, `prompt.submit` re-applies: if an account is selected and the heartbeat is fresh (< 30 s) and lists the account, sets `ANTHROPIC_BASE_URL=http://127.0.0.1:48620/acct/<name>`; otherwise restores the host's original base URL and shows a warning status. `/account [name|off|status]` switches live. Warns (status + one toast) when the token has ≤ 14 days left. |
| Token store `tokens.json` | `~/.claude/account-switcher/tokens.json` | `{ "<name>": { "token", "createdAt", "expiresAt" } }`, written by `scripts/add-account.ps1` from `claude setup-token` output (captured to a file, regex-extracted, never printed). Bare-string values are accepted for compatibility. |

Scripts: `install.ps1` (copy, settings env, scheduled task, start, heartbeat check), `add-account.ps1 -Name`, `uninstall.ps1 [-PurgeTokens]`.

## Why this design (what was measured)

Evidence lives in Home Base's journal for 2026-10-04 (two entries) and was produced with fake tokens against a local header-logging sink, then with one real token.

1. **Claude Desktop is the login holder.** Each Code session it spawns receives `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_ACCOUNT_UUID`, `CLAUDE_CODE_USER_EMAIL`, `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH=1`, `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH=1` in its environment. The desktop does **not** set `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST`.
2. **In a plain CLI engine, `$.env.set("CLAUDE_CODE_OAUTH_TOKEN", …)` from a plugin wins per request** (sink saw the plugin's token on every request, including the first with `--plugin-dir`). A settings-file `env` block value also reaches auth (401 with a bogus value), contradicting the settings reference's "CLAUDE_CODE_* ignored in env" line; but when the process already holds the variable, the process value wins.
3. **In a desktop session the variable route is dead.** Both `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_AUTH_TOKEN` set by the plugin left the requests on the window's account. The engine binary explains it: a host-auth channel (`CLAUDE_CODE_HOST_AUTH_ENV_VAR`, `CLAUDE_CODE_HOST_CREDS_FILE`, control request `host_auth_token_refresh`, "the session token held in process", `cli_worker_auth_refresh_adopted`) adopts the host's credential into memory.
4. **`ANTHROPIC_BASE_URL` is read per request even in a desktop session.** With the plugin setting it, every request (and every retry) from a real desktop session arrived at the local sink on the `/acct/vbp/` path. Hence the relay.
5. **Proof on the live surface:** a desktop session in a marker project answered normally with `💳 billing: VBP` and reported VBP's rate-limit windows (1 % / 18 %, VBP's own reset times) while the window's account sat at 5 % / 37 %; the relay log shows its `messages` and `count_tokens` calls as `vbp → 200`.

Rejected / closed routes:
- Native: the desktop only switches between a same-email individual + Team pair; different emails mean logout/login. Feature requests anthropics/claude-code#18435 and #30565 are open or closed-as-duplicate. A popped-out session window is a bare session (no sidebar).
- `apiKeyHelper`: docs state desktop sessions never call it (and the OAuth-via-helper bug #97350 is open anyway).
- Per-project settings `env` alone: the host's process value wins.
- Swapping the Electron profile's login files and relaunching (the Hermes Account Switcher pattern): workable fallback but needs a restart; not needed now.

## Gotchas found while building

- `$.http.fetch` answers `{ status, ok, headers, text }`; there is no `.json()`. The first relay health check threw on it and the plugin (correctly) fell open. Liveness now uses the heartbeat file.
- Desktop sessions do not hot-reload a `CLAUDE_CODE_PLUGIN_DIRS` plugin on edit unless `CLAUDE_CODE_PLUGIN_DIR_WATCH=1` is set; each iteration needs a fresh session.
- The Claude Code auto-mode classifier refused the plugin-authoring session's own edit of `~/.claude/settings.json` (self-modification) until the user widened permissions; `install.ps1` does that edit from a normal shell.
- PowerShell: `ConvertFrom-Json` turns ISO dates into `DateTime`; format with `"$($x)"` before `.Substring`. A script parameter named `-Settings` shadows a `$settings` local when calling `Register-ScheduledTask -Settings`.
- A `claude setup-token` run with redirected stdout still opens the browser and prints the token to stdout; capture to a file, extract by regex, delete the file.
- The desktop's sidebar/session list is per Electron profile (`claude-code-sessions\<account>\<org>\local_*.json`); a second full window is a second app copy with its own list.

## Operating

- Relay health: `GET http://127.0.0.1:48620/health`, or read `relay.alive` (fresh if `at` is within 30 s). Scheduled task `ClaudeAccountRelay`: logon trigger + 5-minute recovery, `MultipleInstances IgnoreNew`; a second start exits immediately because the port is held.
- Add/renew an account: `scripts\add-account.ps1 -Name <name>`; the relay re-reads `tokens.json` on every request, no restart.
- Which account a session bills: the status line, or `/account`. Ground truth: the rate-limit windows the session reports (the routed account's), and `relay.log`.
- Rollback: `scripts\uninstall.ps1`; `install.ps1` leaves a timestamped `settings.json` backup.

## Open items

- macOS/Linux launcher (relay and plugin are already platform-neutral).
- Make the store path a plugin option instead of deriving it from the plugin folder's parent.
- Observe claude.ai connectors inside a routed session (expected unavailable there; the owner does not use them in desktop sessions).
