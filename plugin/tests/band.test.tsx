// The band above the prompt: one button per account the relay has a token for, a press moves the
// session's API traffic to that account, "off" moves it back, and "hide" is remembered in the store.
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
  on("env.get", async (_$: any, e: any) => ({ value: env[e.name] }));
  on("env.set", async (_$: any, e: any) => { env[e.name] = e.value; return { value: undefined }; });
  on("ui.status", async () => ({ value: undefined }));
  on("ui.toast", async () => ({ value: undefined }));
  on("command.register", async (_$: any, e: any) => ({ value: { command: e.name } }));
  // The engine's own band is empty: what a hidden band's next(e) reaches.
  on("ui.render", { component: "AbovePrompt" }, async () => ({ type: "Box", props: {}, children: [] }));
  return env;
}

const alive = () => ({ port: 48620, pid: 1, at: Date.now() / 1000, accounts: ["vbp", "personal2", "personal"] });

for (const surface of ["terminal", "desktop"] as const) {
  test(`a button press switches the account and off restores the host URL (${surface})`, async ($, on) => {
    mock.store(on);
    const env = world(on, alive(), { ANTHROPIC_BASE_URL: "https://host.example" });
    await $.session.start({ cwd: "C:/work/project", surface, isInteractive: true });

    const ui = await $.ui.mount({ ...BAND, surface });
    expect(await ui.find({ key: "acct:vbp" })).toBeDefined();
    expect(await ui.find({ key: "acct:personal2" })).toBeDefined();
    expect(await ui.find({ key: "acct:off" })).toBeUndefined(); // nothing to turn off yet
    expect(await ui.find({ type: "Text", text: /window account/ })).toBeDefined();

    await ui.press({ key: "acct:personal2" });
    expect(env.ANTHROPIC_BASE_URL).toBe(`${RELAY}/acct/personal2`);
    expect(await ui.find({ type: "Text", text: /PERSONAL2/ })).toBeDefined();
    expect(await ui.find({ key: "acct:off" })).toBeDefined();

    await ui.press({ key: "acct:off" });
    expect(env.ANTHROPIC_BASE_URL).toBe("https://host.example");
    expect(await ui.find({ key: "acct:off" })).toBeUndefined();

    await ui.press({ key: "hide" });
    expect(await ui.find({ key: "acct:vbp" })).toBeUndefined();
    await ui.unmount();
  });
}

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
