# claude-account-switcher — User Guide

One Claude Desktop app (or one terminal), several Claude subscriptions. You keep the app signed into one account; projects (or a command) decide which account actually pays for a session's model calls.

Works on Windows and macOS with the Claude Desktop app and with terminal Claude Code. On Linux there is no Claude Desktop app, so it applies to terminal Claude Code only. The macOS installer is untested (no Mac was available); Windows and Linux are proven.

## Everyday use

**Pin a project to an account.** Put a file named `account` inside the project's `.claude` folder containing just the account's name, for example `work`. Every session you open in that project then bills that account. The status line under the prompt shows `💳 billing: WORK`.

**Switch one session with a click.** Above the prompt box there is a slim row: 💳 the account this session bills, then one button per account you have added. Click one and that session bills it from your next message on; the row and the status line both change. `off` puts it back on the app's own account. `hide` removes the row in every session (your choice is remembered); `/account show` brings it back.

**Or by keyboard.** Type `/account work` in the session; from your next message on, that session bills the `work` account. `/account off` puts it back on the app's own account. `/account` on its own tells you what the session is doing, whether the relay is up, which accounts have tokens, when each token expires, and each account's real usage (5-hour and weekly, with reset times).

**Where to read usage.** Use `/account`. The app's own usage panel, and a session asked "what's my usage", report the account the app is signed into, not the account a switched session is billing.

**Nothing set?** The session just uses the account the app is signed into, exactly as before.

## What the status line means

| Status line | Meaning |
|---|---|
| `💳 billing: WORK` | This session's model calls go to the `work` account. |
| `💳 billing: WORK ⚠ token expires in 9d` | Same, and that token needs renewing soon (see below). |
| `⚠ WORK: relay down · billing window account` | The relay isn't running, so the session fell back to the app's account. Start it (see below) or log off and on. |
| `⚠ WORK: no token · billing window account` | No token stored for that name. Add one (see below). |
| (nothing) | The session is on the app's account. |

Starting the relay by hand:

| Platform | Command |
|---|---|
| Windows | `Start-ScheduledTask ClaudeAccountRelay` |
| Linux | `systemctl --user start claude-account-relay` |
| macOS | `launchctl kickstart gui/$(id -u)/com.claude-account-switcher.relay` |

## Adding or renewing an account

Tokens last one year. To add one, or renew one that's about to expire:

1. In your normal browser, make sure claude.ai is signed in as the account you're adding (sign out and back in if needed; the approval page does not offer a picker).
2. Run, from the folder you cloned the project into:
   - Windows (PowerShell): `scripts\add-account.ps1 -Name work`
   - macOS / Linux: `scripts/add-account.sh work`
3. A browser tab opens (on a machine without a browser, a sign-in link is printed); approve. If Claude Code asks you to paste a code, paste it into the same terminal. The token is saved directly; on screen it is masked.

Account names are lowercase, short, and yours to choose (`work`, `personal`, `team`). The name in a project's `.claude/account` file must match.

## Things to know

- The app's own usage tray shows the app's account; `/account` in a routed session shows the account it's billing.
- Inside a routed session, claude.ai connectors, cloud routines and Remote Control aren't available (the swapped login is model-only). Everything else works as normal.
- The relay only listens on your own machine (127.0.0.1); nothing is reachable from the network.
- Every token is one of your own subscriptions, approved by you through Anthropic's own sign-in. Don't share tokens with other people or machines.
- To remove everything: `scripts\uninstall.ps1` on Windows, `scripts/uninstall.sh` on macOS/Linux (add `-PurgeTokens` / `--purge-tokens` to delete the stored tokens too).
