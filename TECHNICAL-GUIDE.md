# claude-account-switcher — Technical Guide

Briefing for anyone (or any model) picking this up cold. Built 2026-10-04 on Windows against Claude Code 2.1.286 and Claude Desktop 2.19675.0; Linux path built and tested 2026-10-08 on Pop!_OS 24.04 with Claude Code 2.1.281.

## What it is

Three small parts that let one Claude Desktop app (or one terminal) bill Code sessions to different Claude subscriptions:

| Part | Where (installed) | Job |
|---|---|---|
| Relay `relay.py` | `~/.claude/account-switcher/relay.py`, run by a per-user service (see Platforms) | Loopback HTTP relay on `127.0.0.1:48620`. `/acct/<name>/<path>` → `https://api.anthropic.com/<path>` with `Authorization: Bearer <name's token>`. Streams responses. Writes `relay.alive` every 10 s (port, pid, time, account names, expiry per name, usage per name). Logs account/method/path/status/bytes/seconds to `relay.log`; never a token. |
| Plugin `plugin/` | `~/.claude/account-switcher/plugin`, loaded via `CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json` `env` | Hooks module. At `session.start` reads the marker (`<cwd>/.claude/account`, then `<session root>/.claude/account`), registers `/account`. At `session.start`, `turn.start`, `prompt.submit` re-applies: if an account is selected and the heartbeat is fresh (< 30 s) and lists the account, sets `ANTHROPIC_BASE_URL=http://127.0.0.1:48620/acct/<name>`; otherwise restores the host's original base URL and shows a warning status. `/account [name|off|status|show|hide]` switches live. Draws the `AbovePrompt` band (a `ui.render` hook): the account in force, one `Button` per account in the heartbeat (the current one `primary`), `off` while an account is selected, `hide`; a press runs the same `apply` as the command and toasts the result. The chosen account, the heartbeat's account list and the host's original `ANTHROPIC_BASE_URL` live in `$.state` (`account-switcher.billing`, contract `plugin/types/index.d.ts`) so a hot reload keeps them; the hide choice is `$.store` key `band.hidden`, read at `session.start`. Tests: `claude plugin test plugin` (terminal and desktop surfaces). Warns (status + one toast) when the token has ≤ 14 days left. |
| Token store `tokens.json` | `~/.claude/account-switcher/tokens.json` | `{ "<name>": { "token", "createdAt", "expiresAt" } }`, written by the add-account script from `claude setup-token` output (captured, regex-extracted, never printed). Bare-string values are accepted for compatibility. |

Scripts: `install.ps1` / `install.sh` (copy, settings env, service, start, heartbeat check), `add-account.ps1 -Name <n>` / `add-account.sh <n>`, `uninstall.ps1 [-PurgeTokens]` / `uninstall.sh [--purge-tokens]`.

## Platforms

| | Windows | Linux | macOS |
|---|---|---|---|
| Service | Scheduled task `ClaudeAccountRelay`: logon trigger + 5-minute repeating recovery trigger, `MultipleInstances IgnoreNew`, runs `pythonw.exe relay.py` | `~/.config/systemd/user/claude-account-relay.service`: `Restart=on-failure`, `RestartSec=5`, `WantedBy=default.target` | `~/Library/LaunchAgents/com.claude-account-switcher.relay.plist`: `RunAtLoad`, `KeepAlive.SuccessfulExit=false` (restart only on failure), stdout/stderr to `relay.launchd.log` |
| Settings env | `CLAUDE_CODE_PLUGIN_DIRS` | `CLAUDE_CODE_PLUGIN_DIRS` + `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` | same as Linux |
| Separator in `CLAUDE_CODE_PLUGIN_DIRS` | `;` | `:` | `:` |
| Covers | Desktop app sessions and terminal | terminal only (no Desktop app on Linux) | Desktop app sessions and terminal |
| Status | in daily use | tested end to end (below) | **untested** |

Why the hooks flag: in the terminal CLI, hooks-module plugins from `CLAUDE_CODE_PLUGIN_DIRS` are early access. Without the flag the CLI prints `account-switcher: hooks module not loaded: hooks modules are not turned on for installed plugins in this process (early access: set CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 ...)` and the session stays on the login account. Claude Desktop sets the flag for the sessions it spawns (the Windows install has never needed it in `settings.json`), so `install.ps1` leaves it alone; `install.sh` sets it because on Linux the terminal is the only surface. The flag works from the settings `env` block and from the process environment (both measured). The separator is `path.delimiter` in the engine (confirmed by reading the `claude` binary: `(CLAUDE_CODE_PLUGIN_DIRS ?? "").split(delimiter)`), so the shell scripts use Python's `os.pathsep`.

### Linux evidence (2026-10-08, Pop!_OS 24.04, Claude Code 2.1.281, Python 3.12.3)

Run on a second machine with a throwaway `HOME=/tmp/acctsw-home` (the machine's live `~/.claude` was not touched; its `settings.json`, `.credentials.json` and `.claude.json` had identical SHA-256 before and after). The systemd unit went to the real `~/.config/systemd/user` via `XDG_CONFIG_HOME`, because the user manager only reads that folder.

1. **Install.** `install.sh` wrote the files (store mode 700), merged `env` into a pre-existing `settings.json` while keeping its other keys (`KEEP_ME`, `model`), left one timestamped backup, registered and enabled the unit, and reported a fresh heartbeat: `Relay running: pid 2750162, port 48620, accounts: none`. `systemctl --user show` confirmed `Restart=on-failure`, `UnitFileState=enabled`, `ExecStart=/usr/bin/python3 .../relay.py`. `GET /health` → `{"ok": true, "accounts": []}`.
2. **Restart on failure.** `kill -9` of the relay's pid; 8 s later the unit was `active` with a new pid (2750162 → 2750740) and `/health` answered.
3. **Idempotent re-run.** A second `install.sh` over the running install succeeded (second backup, unit restarted, heartbeat fresh, existing `test` account still listed).
4. **Routing.** With `.claude/account` = `test` in a scratch project, `claude -p "Reply with exactly the word ROUTED" --model haiku --strict-mcp-config` answered `ROUTED` and `relay.log` gained `test POST /v1/messages?beta=true -> 200 1499B 2.5s`; 11 s later `relay.alive` carried `usage.test` with that account's 5-hour and 7-day utilization and reset times. Control: the same prompt with the marker removed answered `DIRECT` and added no relay.log line. (Token used for the proof: the test machine's own CLI access token copied into the throwaway store, deleted afterwards. A deliberately fake token also routed, which is how the missing hooks flag was found: the request went direct and the relay log stayed empty.)
5. **`--strict-mcp-config` in the proof** only shrinks the prompt. That machine's MCP tool list is ~261k tokens, which the API rejected as too long through the relay while the direct path accepted it; the difference is the engine's own behaviour when `ANTHROPIC_BASE_URL` is set (it drops its large-context request), not a relay fault. Noted under Open items.
6. **add-account dry run.** `add-account.sh dryrun --wait 8` without a sign-in rendered Claude Code's setup-token screen through the pty (sign-in URL, "Paste code here if prompted"), timed out, printed `No token captured for 'dryrun' (sign-in not completed?)`, exited 1, left `tokens.json` unchanged and removed its scratch config dir. `add-account.sh 'Bad Name'` was rejected with exit 2. A real token capture on Linux has **not** been exercised (needs a browser sign-in on that machine).
7. **Uninstall.** `uninstall.sh --purge-tokens`: unit file gone, `systemctl --user list-unit-files` shows nothing, no `relay.py` process, no listener on 48620, store directory gone, `settings.json` back to exactly `{"env": {"KEEP_ME": "1"}, "model": "sonnet"}`, the user-unit folder listing identical to before the test.

### macOS (untested)

Written against the launchd documentation and shellcheck-clean, nothing more. Things most likely to need a fix on first contact: `launchctl bootstrap gui/<uid>` failing over ssh (the script falls back to `launchctl load -w`); `/usr/bin/python3` being the Xcode Command Line Tools stub (the script prefers `/opt/homebrew/bin/python3` and `/usr/local/bin/python3`); whether Claude Desktop on macOS also sets the hooks flag (harmless either way, `install.sh` sets it in settings).

## Why this design (what was measured)

Evidence was produced with fake tokens against a local header-logging sink, then with one real token, on Windows with Claude Desktop (2026-10-04).

1. **Claude Desktop is the login holder.** Each Code session it spawns receives `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_ACCOUNT_UUID`, `CLAUDE_CODE_USER_EMAIL`, `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH=1`, `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH=1` in its environment. The desktop does **not** set `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST`.
2. **In a plain CLI engine, `$.env.set("CLAUDE_CODE_OAUTH_TOKEN", …)` from a plugin wins per request** (sink saw the plugin's token on every request, including the first with `--plugin-dir`). A settings-file `env` block value also reaches auth (401 with a bogus value), contradicting the settings reference's "CLAUDE_CODE_* ignored in env" line; but when the process already holds the variable, the process value wins.
3. **In a desktop session the variable route is dead.** Both `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_AUTH_TOKEN` set by the plugin left the requests on the window's account. The engine binary explains it: a host-auth channel (`CLAUDE_CODE_HOST_AUTH_ENV_VAR`, `CLAUDE_CODE_HOST_CREDS_FILE`, control request `host_auth_token_refresh`, "the session token held in process", `cli_worker_auth_refresh_adopted`) adopts the host's credential into memory.
4. **`ANTHROPIC_BASE_URL` is read per request even in a desktop session.** With the plugin setting it, every request (and every retry) from a real desktop session arrived at the local sink on the `/acct/<name>/` path. Hence the relay.
5. **Proof on the live surface:** a desktop session in a marker project answered normally with `💳 billing: <NAME>` and reported the routed account's rate-limit windows (1 % / 18 %, its own reset times) while the window's account sat at 5 % / 37 %; the relay log shows its `messages` and `count_tokens` calls as `<name> → 200`.

Rejected / closed routes:
- Native: the desktop only switches between a same-email individual + Team pair; different emails mean logout/login. Feature requests anthropics/claude-code#18435 and #30565 are open or closed-as-duplicate. A popped-out session window is a bare session (no sidebar).
- `apiKeyHelper`: docs state desktop sessions never call it (and the OAuth-via-helper bug #97350 is open anyway).
- Per-project settings `env` alone: the host's process value wins.
- Swapping the Electron profile's login files and relaunching: workable fallback but needs a restart; not needed now.

## Gotchas found while building

- `$.http.fetch` answers `{ status, ok, headers, text }`; there is no `.json()`. The first relay health check threw on it and the plugin (correctly) fell open. Liveness now uses the heartbeat file.
- Desktop sessions do not hot-reload a `CLAUDE_CODE_PLUGIN_DIRS` plugin on edit unless `CLAUDE_CODE_PLUGIN_DIR_WATCH=1` is set; each iteration needs a fresh session.
- The Claude Code auto-mode classifier refused the plugin-authoring session's own edit of `~/.claude/settings.json` (self-modification) until the user widened permissions; the install scripts do that edit from a normal shell.
- PowerShell: `ConvertFrom-Json` turns ISO dates into `DateTime`; format with `"$($x)"` before `.Substring`. A script parameter named `-Settings` shadows a `$settings` local when calling `Register-ScheduledTask -Settings`.
- Windows: a `claude setup-token` run with redirected stdout still opens the browser and prints the token to stdout; capture to a file, extract by regex, delete the file.
- Linux: the same trick prints **nothing**. `claude setup-token` renders an Ink screen only on a TTY; with stdout redirected and stdin `/dev/null` it sits silent until killed. On a machine without a browser it also expects the user to paste a code back. `add-account.sh` therefore runs it on a pseudo-terminal (`pty.fork`, 220 columns so the token never wraps), forwards stdin, masks `sk-ant-oat01-…` in what it echoes (holding back a trailing fragment that could be the start of a token), captures the token, and stops the child 3 s after the capture.
- A bash background job (`cmd &`) in a non-interactive script gets `/dev/null` as stdin, which is why a simple "run it in the background and poll a file" port of the PowerShell script cannot work on POSIX.
- `systemctl --user` only reads units under the user manager's own config dir; a throwaway `HOME` needs `XDG_CONFIG_HOME` pointed at the real one (the script honours it).
- `install.ps1` references a `relay.pid` file that `relay.py` never writes; the heartbeat's `pid` is the real handle and the shell scripts use that.
- The desktop's sidebar/session list is per Electron profile (`claude-code-sessions\<account>\<org>\local_*.json`); a second full window is a second app copy with its own list.

## Operating

- Relay health: `GET http://127.0.0.1:48620/health`, or read `relay.alive` (fresh if `at` is within 30 s). Service handles: Windows `Get-ScheduledTask ClaudeAccountRelay`; Linux `systemctl --user status claude-account-relay`; macOS `launchctl print gui/$(id -u)/com.claude-account-switcher.relay`. A second relay start exits immediately because the port is held.
- Add/renew an account: `add-account.ps1 -Name <n>` / `add-account.sh <n>`; the relay re-reads `tokens.json` on every request, no restart.
- Which account a session bills: the status line, or `/account`. Ground truth: `relay.log`, and the routed account's own usage windows.
- **Usage readouts that do NOT follow the switch (found 2026-10-04):** the desktop app's usage panel and any in-session "get usage" tool report the window's login, and the session's startup "user email" comes from the CLI login stored in `~/.claude.json`. A routed session therefore showed the window account's usage and the CLI login's email while billing the routed account correctly. The relay records each account's `anthropic-ratelimit-unified-*` reply headers (5-hour and 7-day utilization and reset) in memory and writes them into `relay.alive` under `usage`; `/account` prints them per account with their age. They exist only after that account's first reply through the relay since the relay started. The relay tokens (`claude setup-token`) are inference-only: `/api/oauth/profile` and `/api/oauth/usage` return 403, so identity is proven by organization id and usage windows on a reply, not by a profile call.
- Rollback: the uninstall script for the platform; the install scripts leave a timestamped `settings.json` backup.

## Open items

- macOS: first real run of `install.sh` / `add-account.sh` / `uninstall.sh` on a Mac.
- Linux: a real token capture through `add-account.sh` (needs a browser sign-in on that machine); only the no-sign-in path has been run.
- Routed sessions with very large tool lists: through the relay the engine seems not to request the large-context window it uses on the direct path, so a ~261k-token prompt got "Prompt is too long" only when routed. Find which request header or model variant differs and whether the relay can restore it.
- `install.ps1` could also set `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` so terminal Claude Code on Windows loads the plugin outside the Desktop app; not changed because the Windows path is in daily use and was not re-tested.
- Make the store path a plugin option instead of deriving it from the plugin folder's parent.
- Observe claude.ai connectors inside a routed session (expected unavailable there).
