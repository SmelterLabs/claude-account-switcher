// account-switcher — bill a Claude Code session to a different Claude subscription.
//
// How it works: the relay (relay.py, loopback only) rewrites the Authorization header for the
// account named in the request path. This plugin points the session's API traffic at
// http://127.0.0.1:48620/acct/<name>, chosen by the project's `.claude/account` marker or by
// `/account <name>` in the session. The desktop app keeps its own login; only this session's
// model requests change accounts. Fails open: relay down or no token → the session stays on the
// window's account and the status line says so. The plugin never reads or logs a token; expiry
// dates come from the relay's heartbeat file.

const RELAY = "http://127.0.0.1:48620";
const STALE_S = 30;
const WARN_DAYS = 14;

type Heartbeat = { port: number; pid: number; at: number; accounts: string[]; expires?: Record<string, string> };

let store = "";
let account: string | null = null;      // the account this session should bill, or null
let source: "marker" | "command" | null = null;
let origBaseUrl: string | undefined;    // what the host set, restored by /account off
let hb: Heartbeat | null = null;
let warned = false;

function dir(p: string): string { return p.replace(/[\\/][^\\/]+[\\/]?$/, ""); }

async function readHeartbeat($: any): Promise<Heartbeat | null> {
  try {
    const f = `${store}/relay.alive`;
    if (!(await $.fs.exists(f))) return null;
    const h = JSON.parse(await $.fs.read(f)) as Heartbeat;
    return (Date.now() / 1000 - Number(h.at ?? 0)) < STALE_S ? h : null;
  } catch { return null; }
}

async function readMarker($: any): Promise<string | null> {
  for (const base of [await $.session.cwd(), await $.session.root()]) {
    const f = `${base}/.claude/account`;
    if (await $.fs.exists(f)) {
      const v = (await $.fs.read(f)).trim().toLowerCase();
      if (v) return v;
    }
  }
  return null;
}

function daysLeft(iso?: string): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? Math.floor((t - Date.now()) / 86400000) : null;
}

async function apply($: any): Promise<string> {
  if (!account) {
    if (origBaseUrl !== undefined) await $.env.set("ANTHROPIC_BASE_URL", origBaseUrl);
    $.ui.status(undefined);
    return "billing: window account";
  }
  hb = await readHeartbeat($);
  const label = account.toUpperCase();
  if (!hb) {
    if (origBaseUrl !== undefined) await $.env.set("ANTHROPIC_BASE_URL", origBaseUrl);
    const s = `⚠ ${label}: relay down · billing window account`;
    $.ui.status(s); return s;
  }
  if (!hb.accounts.includes(account)) {
    if (origBaseUrl !== undefined) await $.env.set("ANTHROPIC_BASE_URL", origBaseUrl);
    const s = `⚠ ${label}: no token · billing window account`;
    $.ui.status(s); return s;
  }
  await $.env.set("ANTHROPIC_BASE_URL", `${RELAY}/acct/${account}`);
  const left = daysLeft(hb.expires?.[account]);
  let s = `💳 billing: ${label}`;
  if (left !== null && left <= WARN_DAYS) {
    s += ` ⚠ token expires in ${left}d`;
    if (!warned) { warned = true; $.ui.toast(`account-switcher: the ${label} token expires in ${left} days — run add-account.ps1 -Name ${account}`); }
  }
  $.ui.status(s);
  return s;
}

export function register(on: any) {
  on("session.start", async ($: any, e: any, next: any) => {
    store = dir($.plugin.root);
    origBaseUrl = await $.env.get("ANTHROPIC_BASE_URL");
    const m = await readMarker($);
    if (m) { account = m; source = "marker"; }
    await apply($);
    await $.command.register({
      name: "account",
      description: "Bill this session to another Claude account (via the account-switcher relay)",
      argumentHint: "[name | off | status]",
    });
    return next(e);
  });

  on("turn.start", async ($: any, e: any, next: any) => { await apply($); return next(e); });
  on("prompt.submit", async ($: any, e: any, next: any) => { await apply($); return next(e); });

  on("command.run", { command: "account" }, async ($: any, e: any) => {
    const arg = (e.args ?? "").trim().toLowerCase();
    hb = await readHeartbeat($);
    const known = hb?.accounts ?? [];
    if (!arg || arg === "status") {
      const lines = [
        account ? `This session bills: ${account.toUpperCase()} (${source})` : "This session bills: the window's own account",
        hb ? `Relay: up (pid ${hb.pid}, port ${hb.port}); accounts with tokens: ${known.join(", ") || "none"}` : "Relay: DOWN — sessions fall back to the window's account",
      ];
      for (const n of known) { const d = daysLeft(hb?.expires?.[n]); if (d !== null) lines.push(`  ${n}: token expires in ${d} days`); }
      lines.push("Usage: /account <name> · /account off · marker file .claude/account in a project");
      return { text: lines.join("\n") };
    }
    if (arg === "off") {
      account = null; source = null;
      return { text: await apply($) };
    }
    if (!known.includes(arg)) {
      return { text: hb ? `No token for '${arg}'. Known: ${known.join(", ") || "none"}. Add one with add-account.ps1 -Name ${arg}` : "Relay is down; start it (scheduled task ClaudeAccountRelay) and try again." };
    }
    account = arg; source = "command";
    return { text: `${await apply($)} — from the next message on` };
  });
}
