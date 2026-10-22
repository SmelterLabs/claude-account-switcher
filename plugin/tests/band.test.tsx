// The band above the prompt: an auto button and one button per account the relay has a token for.
// A new session starts in auto on the account with the most usage left; a press moves the session's
// API traffic to that account and holds it there, "off" moves it back to the window's own login,
// and "hide" is remembered in the store.
import { test, expect, mock } from "claude-code/testing";

const RELAY = "http://127.0.0.1:48620";
const BAND = { plugin: "account-switcher", component: "AbovePrompt" as const, props: { hasSurvey: false, isWorking: false, maxRows: 10 } };

// The world beneath the plugin: a relay heartbeat file (or none), a project with no marker,
// and an environment the plugin may write (the kit's mock.env is read-only).
function world(on: any, heartbeat: object | null, env: Record<string, string | undefined>) {
  on("fs.exists", async (_$: any, e: any) => ({ value: /relay\.alive$/.test(e.path) ? heartbeat !== null : false }));
  on("fs.read", async (_$: any, e: any) => {
    if (/relay\.alive$/.test(e.path) && heartbeat) return { value: JSON.stringify(heartbeat) };
    return { deny: `unexpected read ${e.path}` };
  });
  on("session.cwd", async () => ({ value: "C:/work/project" }));
  on("session.root", async () => ({ value: "C:/work/project" }));
  on("session.start", async (_$: any, e: any) => ({ cwd: e.cwd }));
  on("prompt.submit", async (_$: any, e: any) => ({ text: e.text }));
  on("env.get", async (_$: any, e: any) => ({ value: env[e.name] }));
  on("env.set", async (_$: any, e: any) => { env[e.name] = e.value; return { value: undefined }; });
  on("ui.status", async () => ({ value: undefined }));
  on("ui.toast", async () => ({ value: undefined }));
  on("command.register", async (_$: any, e: any) => ({ value: { command: e.name } }));
  // The engine's own band is empty: what a hidden band's next(e) reaches.
  on("ui.render", { component: "AbovePrompt" }, async () => ({ type: "Box", props: {}, children: [] }));
  return env;
}

const now = () => Date.now() / 1000;
const use = (h5: number, extra: object = {}) => ({ at: now(), h5, h5_reset: now() + 3600, d7: null, d7_reset: null, status: "allowed", ...extra });
const alive = (usage: Record<string, object> = {}) => ({ port: 48620, pid: 1, at: now(), accounts: ["vbp", "personal2", "personal"], usage });

for (const surface of ["terminal", "desktop"] as const) {
  test(`a button press holds an account and off restores the host URL (${surface})`, async ($, on) => {
    mock.store(on);
    const env = world(on, alive(), { ANTHROPIC_BASE_URL: "https://host.example" });
    await $.session.start({ cwd: "C:/work/project", surface, isInteractive: true });

    const ui = await $.ui.mount({ ...BAND, surface });
    expect(await ui.find({ key: "acct:auto" })).toBeDefined();
    expect(await ui.find({ key: "acct:vbp" })).toBeDefined();
    expect(await ui.find({ key: "acct:personal2" })).toBeDefined();
    expect(await ui.find({ type: "Text", text: /auto/ })).toBeDefined();

    await ui.press({ key: "acct:personal2" });
    expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/personal2`);
    expect(await ui.find({ type: "Text", text: /PERSONAL2/ })).toBeDefined();
    expect(await ui.find({ key: "acct:off" })).toBeDefined();

    await ui.press({ key: "acct:off" });
    expect(env.ANTHROPIC_BASE_URL).toBe("https://host.example");
    expect(await ui.find({ key: "acct:off" })).toBeUndefined();
    expect(await ui.find({ type: "Text", text: /window account/ })).toBeDefined();

    await ui.press({ key: "hide" });
    expect(await ui.find({ key: "acct:vbp" })).toBeUndefined();
    await ui.unmount();
  });
}

test("a new session starts in auto on the account with the most usage left, before any message", async ($, on) => {
  mock.store(on);
  const env = world(on, alive({ vbp: use(0.9), personal2: use(0.2), personal: use(0.5) }), { ANTHROPIC_BASE_URL: "https://host.example" });
  await $.session.start({ cwd: "C:/work/project", surface: "desktop", isInteractive: true });
  expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/personal2`);
  const ui = await $.ui.mount({ ...BAND, surface: "desktop" });
  expect(await ui.find({ key: "acct:vbp", label: "vbp 90%" })).toBeDefined();
  await ui.unmount();
});

test("an auto session stays put until its account is nearly full, then moves to the roomiest", async ($, on) => {
  mock.store(on);
  const hb = alive({ vbp: use(0.3), personal2: use(0.2), personal: use(0.5) });
  const env = world(on, hb, { ANTHROPIC_BASE_URL: "https://host.example" });
  await $.session.start({ cwd: "C:/work/project", surface: "desktop", isInteractive: true });
  expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/personal2`);

  hb.usage = { vbp: use(0.1), personal2: use(0.6), personal: use(0.5) }; // another is roomier, but this one is fine
  await $.prompt.submit({ text: "next" });
  expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/personal2`);

  hb.usage = { vbp: use(0.1), personal2: use(0.97), personal: use(0.5) };
  await $.prompt.submit({ text: "next" });
  expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/vbp`);
});

test("a limit the API reported counts as full; a picked account is never moved", async ($, on) => {
  mock.store(on);
  const hb = alive({ vbp: use(0.1, { status: "rejected", reset: now() + 600 }), personal2: use(0.4), personal: use(0.3) });
  const env = world(on, hb, { ANTHROPIC_BASE_URL: "https://host.example" });
  await $.session.start({ cwd: "C:/work/project", surface: "terminal", isInteractive: true });
  expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/personal`);

  await $.command.run({ command: "account", args: "personal2" });
  hb.usage = { vbp: use(0.1), personal2: use(0.99), personal: use(0.3) };
  await $.prompt.submit({ text: "next" });
  expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/personal2`);

  await $.command.run({ command: "account", args: "auto" });
  expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/vbp`);
});

// A session with no choice on record (new, or left that way by a version without auto) is in auto;
// a deliberate off is kept across messages.
test("no choice on record means auto; off stays off across messages", async ($, on) => {
  mock.store(on);
  const env = world(on, alive({ vbp: use(0.6), personal2: use(0.1), personal: use(0.5) }), { ANTHROPIC_BASE_URL: "https://host.example" });
  await $.session.start({ cwd: "C:/work/project", surface: "desktop", isInteractive: true });
  expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/personal2`);

  await $.command.run({ command: "account", args: "off" });
  expect(env.ANTHROPIC_BASE_URL).toBe("https://host.example");
  await $.prompt.submit({ text: "next" });
  expect(env.ANTHROPIC_BASE_URL).toBe("https://host.example");
});

test("relay down: no account buttons, the band says so, and the session keeps the host URL", async ($, on) => {
  mock.store(on);
  const env = world(on, null, { ANTHROPIC_BASE_URL: "https://host.example" });
  await $.session.start({ cwd: "C:/work/project", surface: "terminal", isInteractive: true });
  const ui = await $.ui.mount({ ...BAND, surface: "terminal" });
  expect(await ui.find({ key: "acct:vbp" })).toBeUndefined();
  expect(await ui.find({ type: "Text", text: /relay down/ })).toBeDefined();
  expect(env.ANTHROPIC_BASE_URL).toBe("https://host.example");
  await ui.unmount();
});

test("a hide remembered in the store keeps the band away; /account show brings it back", async ($, on) => {
  mock.store(on, { "band.hidden": true });
  world(on, alive(), {});
  await $.session.start({ cwd: "C:/work/project", surface: "terminal", isInteractive: true });
  const ui = await $.ui.mount({ ...BAND, surface: "terminal" });
  expect(await ui.find({ key: "acct:vbp" })).toBeUndefined();
  const { text } = await $.command.run({ command: "account", args: "show" });
  expect(text).toMatch(/shown/);
  expect(await ui.find({ key: "acct:vbp" })).toBeDefined();
  await ui.unmount();
});
