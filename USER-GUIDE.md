# claude-account-switcher — User Guide

One Claude Desktop app, several Claude subscriptions. You keep the app signed into one account; projects (or a command) decide which account actually pays for a session's model calls.

## Everyday use

**Pin a project to an account.** Put a file named `account` inside the project's `.claude` folder containing just the account's name, for example `vbp`. Every session you open in that project then bills that account. The status line under the prompt shows `💳 billing: VBP`.

**Switch one session on the fly.** Type `/account vbp` in the session; from your next message on, that session bills VBP. `/account off` puts it back on the app's own account. `/account` on its own tells you what the session is doing, whether the relay is up, which accounts have tokens, and when each token expires.

**Nothing set?** The session just uses the account the app is signed into, exactly as before.

## What the status line means

| Status line | Meaning |
|---|---|
| `💳 billing: VBP` | This session's model calls go to the VBP account. |
| `💳 billing: VBP ⚠ token expires in 9d` | Same, and VBP's token needs renewing soon (see below). |
| `⚠ VBP: relay down · billing window account` | The relay isn't running, so the session fell back to the app's account. Start the `ClaudeAccountRelay` task or log off and on. |
| `⚠ VBP: no token · billing window account` | No token stored for that name. Add one (see below). |
| (nothing) | The session is on the app's account. |

## Adding or renewing an account

Tokens last one year. To add one, or renew one that's about to expire:

1. In your normal browser, make sure claude.ai is signed in as the account you're adding (sign out and back in if needed; the approval page does not offer a picker).
2. Run, in PowerShell:
   ```powershell
   C:\Projects\claude-account-switcher\scripts\add-account.ps1 -Name vbp
   ```
3. A browser tab opens; approve. The token is saved directly; it's never shown.

Account names are lowercase, short, and yours to choose (`vbp`, `personal`, `personal2`). The name in a project's `.claude/account` file must match.

## Things to know

- The app's own usage tray shows the app's account; a routed session's own meters (in its status line) show the account it's billing.
- Inside a routed session, claude.ai connectors, cloud routines and Remote Control aren't available (the swapped login is model-only). Everything else works as normal.
- The relay only listens on your own PC (127.0.0.1); nothing is reachable from the network.
- To remove everything: `scripts\uninstall.ps1` (add `-PurgeTokens` to delete the stored tokens too).
