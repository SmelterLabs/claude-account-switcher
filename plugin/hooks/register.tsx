// account-switcher — bill a Claude Code session to a different Claude subscription.
//
// How it works: the relay (relay.py, loopback only) rewrites the Authorization header for the
// account named in the request path. This plugin points the session's API traffic at
// http://127.0.0.1:48620/acct/<name>, chosen by the project's `.claude/account` marker, by
// `/account <name>` in the session, or by a button in the band above the prompt. A session with
// no marker starts in auto: on the account with the most usage left, moving to another one when
// that account is nearly full. A pick by button or command holds until auto is chosen again. The
// desktop app keeps its own login; only this session's model requests change accounts. Fails
// open: relay down or no token → the session stays on the window's account and the status line
// says so. The plugin never reads or logs a token; expiry dates and usage come from the relay's
// heartbeat file.

import { atom, read, update } from "claude-code";
import type { Billing } from "../types";

const RELAY = "http://127.0.0.1:48620";
const STALE_S = 30;
const WARN_DAYS = 14;
const FULL = 0.95; // an auto session moves off an account once either usage window reaches this share
const HIDDEN_KEY = "band.hidden"; // $.store: the hide choice outlives the session

type Usage = {
  at: number; h5: number | null; h5_reset: number | null; d7: number | null; d7_reset: number | null;
  status?: string | null; reset?: number | null;
};
type Heartbeat = { port: number; pid: number; at: number; accounts: string[]; expires?: Record<string, string>; usage?: Record<string, Usage> };

// What the band draws from. Held by the host, so a hot reload keeps the chosen account.
const billing = atom({ plugin: "account-switcher", key: "billing" } as const, {
  account: null, source: null, accounts: [], relayUp: false, host: null,
} as Billing);
const isHidden = atom({ plugin: "account-switcher", key: "isHidden" } as const, false);
// Each account's fullness (0..1) as of the last heartbeat read, for the band's labels.
const fullnessAtom = atom({ plugin: "account-switcher", key: "fullness" } as const, {} as Record<string, number | null>);

// How full an account is, 0..1, from the relay's latest reading of its own usage windows. A window
// whose reset has passed counts as empty, a rejected status as full until its reset; null: unknown.
function fullness(u?: Usage): number | null {
  if (!u) return null;
  const now = Date.now() / 1000;
  if (u.status === "rejected" && (!u.reset || u.reset > now)) return 1;
  const w = (v: number | null, reset: number | null) => (v === null || (reset && reset < now) ? 0 : v);
  return Math.max(w(u.h5, u.h5_reset), w(u.d7, u.d7_reset));
}

// The account with the most room left; one never read counts as half full.
function roomiest(h: Heartbeat): string | null {
  let pick: string | null = null;
  let low = Infinity;
  for (const n of h.accounts) {
    const f = fullness(h.usage?.[n]) ?? 0.5;
    if (f < low) { low = f; pick = n; }
  }
  return pick;
}

// The routed account's own usage, as the API reported it on that account's last reply through the relay.
// The desktop app's usage readout is the window's login, not this.
function usageLine(name: string, u?: Usage): string | null {
  if (!u) return null;
  const pct = (v: number | null) => (v === null ? "?" : `${Math.round(v * 100)}%`);
  const when = (s: number | null) => (s ? new Date(s * 1000).toLocaleString(undefined, { weekday: "short", hour: "numeric", minute: "2-digit" }) : "?");
  const age = Math.max(0, Math.round((Date.now() / 1000 - u.at) / 60));
  const blocked = u.status === "rejected" ? " · LIMIT REACHED" : "";
  return `  ${name} usage: 5-hour ${pct(u.h5)} (resets ${when(u.h5_reset)}) · weekly ${pct(u.d7)} (resets ${when(u.d7_reset)})${blocked} · seen ${age} min ago`;
}

let store = "";
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

// Point the session's API traffic where the chosen account says, update the band's state and
// the status line, and return the one-line summary. Never called while drawing. In auto, keep the
// current account until it is nearly full (a move costs the prompt cache), then take the roomiest.
async function apply($: any, account: string | null, source: Billing["source"]): Promise<string> {
  const b = await read($, billing);
  const host = b.host ?? { baseUrl: await $.env.get("ANTHROPIC_BASE_URL") };
  if (!account && source === null) source = "auto"; // never chose (or chose under a version without auto)
  hb = await readHeartbeat($);
  const accounts = hb?.accounts ?? [];
  const set = (patch: Partial<Billing>) => update($, billing, (cur) => ({ ...cur, host, accounts, relayUp: !!hb, ...patch }));
  const beat = hb;
  await update($, fullnessAtom, () => Object.fromEntries(accounts.map((n) => [n, fullness(beat?.usage?.[n])])));

  const auto = source === "auto";
  if (auto && hb) {
    const cur = account && accounts.includes(account) ? account : null;
    if (!cur || (fullness(hb.usage?.[cur]) ?? 0) >= FULL) {
      const pick = roomiest(hb);
      if (cur && pick && pick !== cur) {
        $.ui.toast(`account-switcher: ${cur.toUpperCase()} is nearly at its limit — this chat moved to ${pick.toUpperCase()}`);
      }
      account = pick ?? cur;
    }
  }
  const tag = auto ? " (auto)" : "";

  if (!account) {
    await $.env.set("ANTHROPIC_BASE_URL", host.baseUrl);
    await set({ account: null, source });
    if (auto) { const s = "⚠ auto: no account available · billing window account"; $.ui.status(s); return s; }
    $.ui.status(undefined);
    return "billing: window account";
  }
  const label = account.toUpperCase();
  if (!hb) {
    await $.env.set("ANTHROPIC_BASE_URL", host.baseUrl);
    await set({ account, source });
    const s = `⚠ ${label}${tag}: relay down · billing window account`;
    $.ui.status(s); return s;
  }
  if (!accounts.includes(account)) {
    await $.env.set("ANTHROPIC_BASE_URL", host.baseUrl);
    await set({ account, source });
    const s = `⚠ ${label}: no token · billing window account`;
    $.ui.status(s); return s;
  }
  await $.env.set("ANTHROPIC_BASE_URL", `${RELAY}/acct/${account}`);
  await set({ account, source });
  const left = daysLeft(hb.expires?.[account]);
  let s = `💳 billing: ${label}${tag}`;
  if (left !== null && left <= WARN_DAYS) {
    s += ` ⚠ token expires in ${left}d`;
    if (!warned) { warned = true; $.ui.toast(`account-switcher: the ${label} token expires in ${left} days — run the add-account script for ${account} again`); }
  }
  $.ui.status(s);
  return s;
}

async function reapply($: any): Promise<string> {
  const b = await read($, billing);
  return apply($, b.account, b.source);
}

async function setHidden($: any, hidden: boolean): Promise<void> {
  await update($, isHidden, () => hidden);
  await $.store.set(HIDDEN_KEY, hidden);
}

export function register(on: any) {
  on("session.start", async ($: any, e: any, next: any) => {
    store = dir($.plugin.root);
    const hidden = (await $.store.get(HIDDEN_KEY)) === true;
    await update($, isHidden, () => hidden);
    const b = await read($, billing);
    if (b.account || b.host) {
      await apply($, b.account, b.source);            // a reload: keep what this session chose
    } else {
      const m = await readMarker($);
      await apply($, m, m ? "marker" : null);       // no marker: auto
    }
    await $.command.register({
      name: "account",
      description: "Bill this session to another Claude account (via the account-switcher relay)",
      argumentHint: "[name | auto | off | status | show | hide]",
    });
    return next(e);
  });

  on("turn.start", async ($: any, e: any, next: any) => { await reapply($); return next(e); });
  on("prompt.submit", async ($: any, e: any, next: any) => { await reapply($); return next(e); });

  // The band above the prompt: the account in force, an auto button, and one button per account the
  // relay has a token for, labelled with how full it is. Hidden by its own button (remembered across
  // sessions); `/account show` brings it back.
  on("ui.render", { component: "AbovePrompt" }, async ($: any, e: any, next: any) => {
    if (e.props.hasSurvey || (await read($, isHidden))) return next(e);
    const b = await read($, billing);
    const full = await read($, fullnessAtom);
    const { Box, Button, Text } = $.ui.resolve(e);
    const auto = b.source === "auto";
    const current = b.account ? b.account.toUpperCase() : "window account";
    const choose = (name: string | null, source: Billing["source"]) => async () => {
      const s = await apply($, name, source);
      $.ui.toast(`account-switcher: ${s} — from the next message on`);
    };
    const pct = (n: string) => (typeof full[n] === "number" ? ` ${Math.round((full[n] as number) * 100)}%` : "");
    return (
      <Box flexDirection="row" gap={1}>
        <Text>💳 {current}{auto ? " · auto" : ""}</Text>
        {b.relayUp
          ? [
              <Button key="acct:auto" label="auto" variant={auto ? "primary" : "secondary"} onPress={choose(null, "auto")} />,
              ...b.accounts.map((name) => (
                <Button key={`acct:${name}`} label={`${name}${pct(name)}`} variant={!auto && name === b.account ? "primary" : "secondary"} onPress={choose(name, "button")} />
              )),
            ]
          : <Text dimColor>relay down</Text>}
        {b.source !== "off" && <Button key="acct:off" label="off" dimColor onPress={choose(null, "off")} />}
        <Button key="hide" label="hide" dimColor onPress={() => setHidden($, true)} />
      </Box>
    );
  });

  on("command.run", { command: "account" }, async ($: any, e: any) => {
    const arg = (e.args ?? "").trim().toLowerCase();
    hb = await readHeartbeat($);
    const known = hb?.accounts ?? [];
    const b = await read($, billing);
    if (!arg || arg === "status") {
      const lines = [
        b.account ? `This session bills: ${b.account.toUpperCase()} (${b.source})` : "This session bills: the window's own account",
        hb ? `Relay: up (pid ${hb.pid}, port ${hb.port}); accounts with tokens: ${known.join(", ") || "none"}` : "Relay: DOWN — sessions fall back to the window's account",
      ];
      for (const n of known) { const d = daysLeft(hb?.expires?.[n]); if (d !== null) lines.push(`  ${n}: token expires in ${d} days`); }
      for (const n of known) { const u = usageLine(n, hb?.usage?.[n]); if (u) lines.push(u); }
      if (hb && !Object.keys(hb.usage ?? {}).length) lines.push("  usage: none seen yet (the relay checks each account within a few minutes)");
      lines.push(`New chats start in auto: the account with the most usage left, moving on at ${Math.round(FULL * 100)}% full (a .claude/account marker overrides it)`);
      lines.push(`Band above the prompt: ${(await read($, isHidden)) ? "hidden (/account show)" : "shown (/account hide)"}`);
      lines.push("Usage: /account <name> · /account auto · /account off · marker file .claude/account in a project");
      return { text: lines.join("\n") };
    }
    if (arg === "show" || arg === "hide") {
      await setHidden($, arg === "hide");
      return { text: arg === "hide" ? "Band hidden in every session; /account show brings it back." : "Band shown above the prompt." };
    }
    if (arg === "off") {
      return { text: await apply($, null, "off") };
    }
    if (arg === "auto") {
      return { text: `${await apply($, null, "auto")} — from the next message on` };
    }
    if (!known.includes(arg)) {
      return { text: hb ? `No token for '${arg}'. Known: ${known.join(", ") || "none"}. Add one with scripts/add-account.ps1 -Name ${arg} (Windows) or scripts/add-account.sh ${arg} (macOS/Linux)` : "Relay is down; start it (Windows: scheduled task ClaudeAccountRelay · Linux: systemctl --user start claude-account-relay · macOS: launchctl kickstart gui/$(id -u)/com.claude-account-switcher.relay) and try again." };
    }
    return { text: `${await apply($, arg, "command")} — from the next message on` };
  });
}
