import assert from "node:assert/strict";
import process from "node:process";
import { Buffer } from "node:buffer";
import { clearTimeout, setTimeout } from "node:timers";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, URL } from "node:url";
import { createServer } from "node:net";
import { createRequire } from "node:module";
import { chromium } from "@playwright/test";
import { product } from "../src/product.js";

assert.equal(process.platform, "win32", "Native smoke requires Windows");
const binaryArgument = process.argv.slice(2).find(argument => !argument.startsWith("--"));
const binary = binaryArgument ? resolve(binaryArgument) : fileURLToPath(new URL("../../target/debug/Tokenotch.exe", import.meta.url));
const fullscreenOnly = process.argv.includes("--fullscreen");
const realBrowser = process.argv.includes("--real-browser");
const identityOnly = process.argv.includes("--identity");
const fixtureCLI = join(dirname(binary), "examples", "fixture_copilot.exe");
const require = createRequire(import.meta.url);
const { WindowsStore } = require("../../../integrations/VSCode/src/windows-store.cjs");
const { Companion } = require("../../../integrations/VSCode/src/companion.cjs");
const { fakeVSCode } = require("../../../integrations/VSCode/test/helpers.cjs");
const root = await mkdtemp(join(tmpdir(), "tokenotch-native-"));
const privateRoot = join(root, ".tokenotch");
for (const name of ["Roaming", "Local", "copilot"]) await mkdir(join(root, name));
const environment = { ...process.env, TOKENOTCH_TEST_HOME: root, COPILOT_HOME: join(root, "copilot"),
  WEBVIEW2_USER_DATA_FOLDER: join(root, "webview"), GITHUB_TOKEN: "synthetic-must-not-reach-account-runtime" };
// Building the desktop copies the staged sidecar beside it. A release helper ignores
// TOKENOTCH_TEST_HOME and would deliver synthetic hooks to the user's real Tokenotch, so refuse
// to run unless the helper is a debug build. Empty input means neither build can send anything.
{
  const probe = spawn(join(dirname(binary), "TokenotchHook.exe"), ["cli", "usage"],
    { env: { ...environment, TOKENOTCH_TEST_HOME: "relative-test-home" }, windowsHide: true, stdio: ["pipe", "ignore", "pipe"] });
  let diagnostics = "";
  probe.stderr.on("data", bytes => { diagnostics += bytes; });
  probe.stdin.end();
  await new Promise(resolve => probe.once("exit", resolve));
  if (!diagnostics.includes("isolated test home is invalid")) {
    await rm(root, { recursive: true, force: true });
    assert.fail("The helper beside the native build does not honor TOKENOTCH_TEST_HOME. Stage the debug helper with " +
      "scripts\\prepare.py --helper target\\debug\\TokenotchHook.exe and rebuild before running native smoke checks.");
  }
}
let child;
let browser;
let page;
let output = "";
const originalTestHome = process.env.TOKENOTCH_TEST_HOME;
process.env.TOKENOTCH_TEST_HOME = root;

async function availablePort() {
  const server = createServer();
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}
async function launch() {
  const port = await availablePort();
  child = spawn(binary, [], { env: { ...environment,
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port} --remote-debugging-address=127.0.0.1` },
  cwd: dirname(binary), stdio: ["ignore", "pipe", "pipe"] });
  child.stdout.on("data", bytes => { output += bytes; });
  child.stderr.on("data", bytes => { output += bytes; });
  let ready = false;
  for (let i = 0; i < 150; i++) {
    if (child.exitCode !== null) throw new Error(`Native app exited (${child.exitCode}). Build with the isolated .smoke application identifier to avoid an installed instance. ${output}`);
    try { if ((await globalThis.fetch(`http://127.0.0.1:${port}/json/version`)).ok) { ready = true; break; } }
    catch (error) { if (!(error instanceof TypeError)) throw error; }
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  assert.ok(ready, `WebView2 did not become responsive (PID ${child.pid}): ${output}`);
  browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
  for (let i = 0; i < 100; i++) {
    page = browser.contexts().flatMap(context => context.pages()).find(candidate => !candidate.url().includes("surface="));
    if (page && await page.locator("#runtime").count()) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.ok(page, "Native settings page was not created");
  await page.waitForFunction(() => window.__TAURI_INTERNALS__ && document.querySelector("#runtime")?.textContent.includes("Windows build"));
}
async function stop() {
  if (browser) { await browser.close(); browser = undefined; }
  if (child && child.exitCode === null) {
    const exited = new Promise(resolve => child.once("exit", resolve));
    child.kill(); await exited;
  }
  child = undefined;
}
const invoke = (command, args = {}) => page.evaluate(({ command, args }) => window.__TAURI_INTERNALS__.invoke(command, args), { command, args });
async function pollSnapshots(duration) {
  let timer;
  try {
    await Promise.race([
      (async () => {
        const until = Date.now() + duration;
        do {
          await invoke("app_snapshot");
          await new Promise(resolve => setTimeout(resolve, 10));
        } while (Date.now() < until);
      })(),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("Native snapshot polling timed out")), duration + 10000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
async function hook(name, fields) {
  const helper = spawn(join(privateRoot, "TokenotchHook.exe"), ["cli", name], { env: environment, windowsHide: true,
    stdio: ["pipe", "pipe", "pipe"] });
  let errors = "";
  helper.stderr.on("data", bytes => { errors += bytes; });
  helper.stdin.end(JSON.stringify({ sessionId: "synthetic-native-session", timestamp: Date.now(), ...fields }));
  const code = await new Promise(resolve => helper.once("exit", resolve));
  assert.equal(code, 0, errors);
  if (errors) console.log(`Hook ${name} diagnostics: ${errors}`);
}
// Opt-in: a real browser takes the foreground in fullscreen while the pointer rests on the notch.
async function edgeFullscreen(notchFrame, waitVisible, assertFolded, snapshot) {
  const edge = [process.env["ProgramFiles(x86)"], process.env.ProgramFiles]
    .filter(Boolean).map(base => join(base, "Microsoft", "Edge", "Application", "msedge.exe"));
  const { existsSync } = await import("node:fs");
  const executable = edge.find(existsSync);
  assert.ok(executable, "--real-browser requires Microsoft Edge");
  const profile = await mkdtemp(join(tmpdir(), "tokenotch-edge-"));
  const browserProcess = spawn(executable, [`--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check",
    "--disable-sync", "--start-fullscreen", "about:blank"], { stdio: "ignore" });
  try {
    await waitVisible(false);
    await assertFolded();
    assert.equal((await snapshot("notch")).widgetVisible, false);
  } finally {
    // Edge may hand its window to a child process; stop every process using this temporary profile.
    const { execFileSync } = await import("node:child_process");
    execFileSync("powershell.exe", ["-NoProfile", "-Command",
      `Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" | Where-Object { $_.CommandLine -like '*${profile.replaceAll("'", "''")}*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }`]);
    if (browserProcess.exitCode === null) await once(browserProcess, "exit");
    await rm(profile, { recursive: true, force: true, maxRetries: 30, retryDelay: 200 });
  }
  await waitVisible(true);
  assert.ok(notchFrame.width > 0);
  console.log("PASS: real Edge fullscreen hid the hovered notch and restored it on exit.");
}
async function fullscreenSmoke() {
  const original = (await invoke("app_snapshot")).preferences;
  const displays = await invoke("displays");
  assert.ok(displays.length > 0);
  console.log("Fullscreen display fixture:", JSON.stringify(displays));
  const screen = displays[0];
  const fixture = spawn(join(dirname(binary), "examples", "fullscreen_fixture.exe"), [], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  let errors = "";
  fixture.stderr.on("data", bytes => { errors += bytes; });
  await once(fixture, "spawn");
  const replies = createInterface({ input: fixture.stdout });
  const lines = replies[Symbol.asyncIterator]();
  const request = async fields => {
    let timer;
    try {
      fixture.stdin.write(`${JSON.stringify(fields)}\n`);
      const response = await Promise.race([
        lines.next(),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error(`Fullscreen fixture timed out: ${errors}`)), 5000);
        }),
      ]);
      assert.equal(response.done, false, errors);
      return JSON.parse(response.value);
    } finally { clearTimeout(timer); }
  };
  const surfaces = () => browser.contexts().flatMap(context => context.pages());
  const surface = kind => {
    const found = surfaces().find(candidate => candidate.url().includes(`surface=${kind}`));
    assert.ok(found, `Native ${kind} surface is missing`);
    return found;
  };
  const waitSurfaces = async () => {
    for (let i = 0; i < 100; i++) {
      if (["notch", "card"].every(kind => surfaces().some(candidate => candidate.url().includes(`surface=${kind}`)))) break;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    await Promise.all(["notch", "card"].map(kind => surface(kind).waitForFunction(id =>
      window.__TAURI_INTERNALS__ && document.getElementById(id), kind)));
  };
  const snapshot = kind => surface(kind).evaluate(() => window.__TAURI_INTERNALS__.invoke("app_snapshot"));
  const inspect = () => request({ command: "inspect", pid: child.pid });
  const place = (mode, monitor = screen, bounds = monitor) => request({
    command: "place", mode, x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height,
  });
  const preferences = async change => invoke("set_preferences", {
    preferences: { ...(await invoke("app_snapshot")).preferences, ...change },
  });
  const waitVisible = async visible => {
    const deadline = Date.now() + 3000;
    do {
      if ((await snapshot("notch")).widgetVisible === visible) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    assert.fail(`Native notch did not become ${visible ? "visible" : "hidden"} within 3 seconds`);
  };
  const assertFolded = async () => {
    const state = await snapshot("card");
    assert.equal(state.widgetExpanded, false, JSON.stringify({
      visible: state.widgetVisible, pinned: state.widgetPinned, dismissed: state.widgetDismissed,
      warning: state.warning,
    }));
    assert.equal(state.widgetPinned, false);
    assert.equal(state.widgetDismissed, true);
    assert.equal(state.widgetAutomatic, false);
    assert.equal(state.widgetAlert, null);
    await surface("card").waitForFunction(() => document.querySelector("#card")?.inert === true, null, { timeout: 3000 });
    const cards = (await inspect()).filter(window => window.title === "Tokenotch summary");
    assert.ok(cards.length > 0 && cards.every(window => window.emptyRegion),
      "Hidden/folded cards must have empty native painting and hit regions");
  };
  const waitExpanded = async (expected, message, timeout = 3000) => {
    const deadline = Date.now() + timeout;
    while ((await snapshot("card")).widgetExpanded !== expected && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    const actual = (await snapshot("card")).widgetExpanded;
    if (actual !== expected) {
      const notch = await surface("notch").evaluate(() => ({ ariaExpanded: document.querySelector("#notch")?.getAttribute("aria-expanded"),
        hover: document.querySelector("#notch")?.matches(":hover"), collapsed: document.querySelector("#notch")?.dataset.collapsed }));
      const cardState = await surface("card").evaluate(() => ({ inert: document.querySelector("#card")?.inert,
        hover: document.querySelector("#card")?.matches(":hover") }));
      assert.fail(`${message}: ${JSON.stringify({ expected, actual, notch, card: cardState,
        windows: (await inspect()).filter(window => window.visible && window.title.startsWith("Tokenotch")).map(window => [window.title, window.frame, window.emptyRegion]),
        cursor: await request({ command: "cursor" }) })}`);
    }
  };
  const moveTo = (x, y) => request({ command: "cursor", x: Math.round(x), y: Math.round(y) });
  const away = () => moveTo(screen.x + screen.width / 4, screen.y + screen.height / 4);
  const notchCollapsed = () => surface("notch").evaluate(() => document.querySelector("#notch")?.dataset.collapsed);
  const waitNotch = async (expected, message, timeout = 2000) => {
    const deadline = Date.now() + timeout;
    while (await notchCollapsed() !== expected && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 50));
    const actual = await notchCollapsed();
    assert.equal(actual, expected, `${message}: ${JSON.stringify({ expected, actual,
      native: (await snapshot("notch")).widgetExpanded, preferences: (await snapshot("notch")).preferences.autoHideNotch,
      aria: await surface("notch").evaluate(() => document.querySelector("#notch")?.getAttribute("aria-expanded")) })}`);
  };
  // The folded (auto-hidden) gauge hugs the screen edge, so hover just inside that edge.
  const hoverPoint = (frame, edge) => ({
    right: [frame.x + frame.width - 3, frame.y + frame.height / 2],
    left: [frame.x + 3, frame.y + frame.height / 2],
    top: [frame.x + frame.width / 2, frame.y + 3],
    bottom: [frame.x + frame.width / 2, frame.y + frame.height - 3],
  })[edge];
  // Real pointer paths: the card must fold whichever way the pointer leaves, without extra movement.
  const pointerPaths = async notchFrame => {
    const { edge, autoHideNotch } = (await invoke("app_snapshot")).preferences;
    const notchCenter = hoverPoint(notchFrame, edge);
    const folded = String(Boolean(autoHideNotch));
    await away();
    await waitExpanded(false, "The card starts folded");
    await waitNotch(folded, "An idle notch follows the auto-hide preference", 5000);
    await moveTo(...notchCenter);
    await waitExpanded(true, "Hovering the notch opens the card");
    await waitNotch("false", "Hovering expands the notch");
    await new Promise(resolve => setTimeout(resolve, 600));
    await waitExpanded(true, "A resting pointer on the notch keeps the card open", 0);
    await away();
    await waitExpanded(false, "Leaving the notch directly folds the card");
    await waitNotch(folded, "Leaving the notch directly re-folds an auto-hidden notch");
    await moveTo(...notchCenter);
    await waitExpanded(true, "Hovering the notch reopens the card");
    const card = (await inspect()).find(window => window.title === "Tokenotch summary").frame;
    await moveTo(card.x + card.width / 2, card.y + card.height / 2);
    await new Promise(resolve => setTimeout(resolve, 600));
    await waitExpanded(true, "Moving onto the card keeps it open", 0);
    await away();
    await waitExpanded(false, "Leaving the card folds it");
    await waitNotch(folded, "Leaving the card re-folds an auto-hidden notch");
  };
  // Resting on the notch alone views the notices its card shows, as on macOS: a seen stop clears the
  // notch badge and a seen request is dismissed when the card folds.
  const hoverNotices = async notchFrame => {
    const notchPoint = hoverPoint(notchFrame, (await invoke("app_snapshot")).preferences.edge);
    const badge = () => surface("notch").evaluate(() => document.querySelector(".ring-badge")?.getAttribute("class") ?? null);
    await invoke("connection", { source: "cli", operation: "install", metrics: false });
    try {
      // Lifecycle events are ordered by timestamp, so give each hook a distinct one.
      for (const [name, fields] of [["sessionStart", { source: "new" }],
        ["userPromptSubmitted", { prompt: "SYNTHETIC CONTENT MUST BE DISCARDED" }], ["agentStop", { stopReason: "end_turn" }]]) {
        await new Promise(resolve => setTimeout(resolve, 20));
        await hook(name, fields);
      }
      let notices = [];
      for (let attempt = 0; attempt < 40 && !notices.some(notice => notice.kind === "stopped"); attempt++) {
        notices = (await invoke("app_snapshot")).notices;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      const stopped = notices.find(notice => notice.kind === "stopped" && !notice.viewed);
      assert.ok(stopped, `A stopped notice is reported: ${JSON.stringify({ notices, sessions: (await invoke("app_snapshot")).sessions,
        delivery: (await invoke("app_snapshot")).delivery, live: (await invoke("app_snapshot")).liveGeneration,
        warning: (await invoke("app_snapshot")).warning, connections: (await invoke("app_snapshot")).connections })}`);
      await surface("notch").waitForFunction(() => document.querySelector(".ring-badge")?.classList.contains("signal-stopped"),
        null, { timeout: 4000 });
      await moveTo(...notchPoint);
      await waitExpanded(true, "Hovering the notch opens the card over the stopped notice");
      const deadline = Date.now() + 4000;
      do {
        notices = (await invoke("app_snapshot")).notices;
        if (notices.find(notice => notice.id === stopped.id)?.viewed) break;
        await new Promise(resolve => setTimeout(resolve, 100));
      } while (Date.now() < deadline);
      assert.equal(notices.find(notice => notice.id === stopped.id)?.viewed, true,
        "Resting on the notch views the stopped notice without entering the card");
      await away();
      await waitExpanded(false, "Leaving the notch folds the card");
      await surface("notch").waitForFunction(() => !document.querySelector(".ring-badge"), null, { timeout: 4000 });
      assert.equal(await badge(), null, "A viewed stopped notice no longer marks the notch");

      await hook("notification", { hook_event_name: "Notification", notification_type: "elicitation_dialog" });
      notices = (await invoke("app_snapshot")).notices;
      const request = notices.find(notice => notice.kind === "inputRequested" && !notice.dismissed);
      assert.ok(request, "An input request notice is reported");
      await surface("notch").waitForFunction(() => document.querySelector(".ring-badge") !== null, null, { timeout: 4000 });
      await moveTo(...notchPoint);
      await waitExpanded(true, "Hovering the notch opens the card over the request");
      await new Promise(resolve => setTimeout(resolve, 1600));
      await away();
      await waitExpanded(false, "Leaving the notch folds the card");
      const until = Date.now() + 4000;
      do {
        notices = (await invoke("app_snapshot")).notices;
        if (notices.find(notice => notice.id === request.id)?.dismissed) break;
        await new Promise(resolve => setTimeout(resolve, 100));
      } while (Date.now() < until);
      assert.equal(notices.find(notice => notice.id === request.id)?.dismissed, true,
        "Folding dismisses a request seen while resting on the notch");
      assert.equal(notices.find(notice => notice.id === request.id)?.resolved, false, "Dismissal does not answer the request");
      await surface("notch").waitForFunction(() => !document.querySelector(".ring-badge"), null, { timeout: 4000 });
    } finally {
      await invoke("connection", { source: "cli", operation: "remove", metrics: false });
      await invoke("clear_data", { kind: "notices" });
    }
  };
  try {
    await preferences({ display: screen.name, allDisplays: false, widgetVisible: true,
      hideFullscreen: true, collapseIdle: true, notifications: false });
    await waitSurfaces();
    await page.mouse.move(150, 150);
    await waitVisible(true);
    const cursor = await request({ command: "cursor" });
    try {
      // A real pointer resting on the notch hovers it natively; fullscreen must still hide it.
      const notchFrame = (await inspect()).find(window => window.title === "Tokenotch activity" && window.visible).frame;
      await request({ command: "cursor", x: notchFrame.x + Math.round(notchFrame.width / 2),
        y: notchFrame.y + Math.round(notchFrame.height / 2) });
      const deadline = Date.now() + 3000;
      while (!(await snapshot("card")).widgetExpanded && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 50));
      assert.equal((await snapshot("card")).widgetExpanded, true, "Resting the real pointer on the notch opens its card");
      await place("fullscreen");
      await waitVisible(false);
      await assertFolded();
      await request({ command: "hide" });
      await waitVisible(true);
      await assertFolded();
      await pointerPaths(notchFrame);
      for (const autoHideNotch of [false, true]) {
        await preferences({ autoHideNotch });
        for (let attempt = 0; attempt < 5; attempt++) {
          await pointerPaths((await inspect()).find(window => window.title === "Tokenotch activity" && window.visible).frame);
        }
      }
      await preferences({ autoHideNotch: false });
      await hoverNotices(notchFrame);
      if (realBrowser) {
        await request({ command: "cursor", x: notchFrame.x + Math.round(notchFrame.width / 2) + 1,
          y: notchFrame.y + Math.round(notchFrame.height / 2) });
        const until = Date.now() + 3000;
        while (!(await snapshot("card")).widgetExpanded && Date.now() < until) await new Promise(resolve => setTimeout(resolve, 50));
        assert.equal((await snapshot("card")).widgetExpanded, true, "The real pointer reopens the card by hovering");
        await edgeFullscreen(notchFrame, waitVisible, assertFolded, snapshot);
      }
    } finally {
      await request({ command: "cursor", x: cursor.x, y: cursor.y });
      await request({ command: "hide" });
    }
    for (const mode of ["fullscreen", "border", "maximizedFullscreen"]) {
      await surface("notch").evaluate(() => window.__TAURI_INTERNALS__.invoke("set_expanded", {
        expanded: true, pinned: true,
      }));
      assert.equal((await snapshot("card")).widgetPinned, true);
      const placed = await place(mode);
      assert.equal(placed.visible, true);
      assert.equal(placed.maximized, mode === "maximizedFullscreen");
      assert.equal(placed.captionBits, mode === "border" ? 0x800000 : 0);
      await waitVisible(false);
      await assertFolded();
      await assert.rejects(surface("notch").evaluate(() => window.__TAURI_INTERNALS__.invoke("set_expanded", {
        expanded: true, pinned: true,
      })), error => String(error).includes("widget is hidden"));
      await surface("notch").evaluate(() => window.__TAURI_INTERNALS__.invoke("open_settings", { page: "general" }));
      await page.locator("#hideFullscreen").uncheck();
      await waitVisible(true);
      await assertFolded();
      assert.equal((await invoke("app_snapshot")).windowFocused, true, "Restoring the notch must not steal focus");
      await page.locator("#hideFullscreen").check();
      await waitVisible(false);
      await request({ command: "hide" });
      await waitVisible(true);
      await assertFolded();
      assert.equal((await invoke("app_snapshot")).windowFocused, true);
    }
    for (const mode of ["windowed", "maximized"]) {
      const placed = await place(mode);
      assert.equal(placed.captionBits, 0xc00000);
      await new Promise(resolve => setTimeout(resolve, 1100));
      assert.equal((await snapshot("notch")).widgetVisible, true,
        "A full-monitor outer frame with a real title bar is not fullscreen content");
    }
    await place("fullscreen", screen, screen.workArea);
    if (screen.workArea.width !== screen.width || screen.workArea.height !== screen.height) {
      await new Promise(resolve => setTimeout(resolve, 1100));
      assert.equal((await snapshot("notch")).widgetVisible, true, "Work-area-only windows are not fullscreen");
    }
    await request({ command: "hide" });
    await preferences({ collapseIdle: false });
    await surface("notch").evaluate(async () => {
      await window.__TAURI_INTERNALS__.invoke("set_expanded", { expanded: true });
      await window.__TAURI_INTERNALS__.invoke("set_expanded", { expanded: false });
    });
    await surface("card").waitForFunction(() => document.querySelector("#card")?.inert === false);
    await place("fullscreen");
    await waitVisible(false);
    await assertFolded();
    await preferences({ notifications: true, notifyStopped: true, expandCard: true, desktopBanner: false, sound: false,
      quietHours: false, muteNotifications: false, snoozedUntil: 0 });
    assert.equal(await invoke("test_notification"), true);
    await pollSnapshots(1100);
    await assertFolded();
    await request({ command: "hide" });
    await waitVisible(true);
    await pollSnapshots(1100);
    await assertFolded();
    await preferences({ notifications: false, collapseIdle: true, widgetVisible: false });
    await place("fullscreen");
    await request({ command: "hide" });
    await pollSnapshots(1100);
    assert.equal((await snapshot("notch")).widgetVisible, false, "Fullscreen exit must respect master visibility");
    await preferences({ widgetVisible: true });
    await place("border");
    await stop();
    await launch();
    await waitSurfaces();
    await waitVisible(false);
    await assertFolded();
    await preferences({ hideFullscreen: false });
    await stop();
    await launch();
    await waitSurfaces();
    await waitVisible(true);
    assert.equal((await invoke("app_snapshot")).preferences.hideFullscreen, false,
      "Fullscreen preference persists across restart");
    await preferences({ hideFullscreen: true });
    await waitVisible(false);
    await request({ command: "hide" });
    await waitVisible(true);
    if (displays.length > 1) {
      await preferences({ allDisplays: true });
      for (const monitor of displays) {
        await place("fullscreen", monitor);
        await pollSnapshots(1100);
        const notches = (await inspect()).filter(window => window.title === "Tokenotch activity");
        assert.equal(notches.length, displays.length);
        assert.equal(notches.filter(window => window.visible).length, displays.length - 1);
        const hidden = notches.find(window => !window.visible);
        assert.ok(hidden.frame.x >= monitor.x && hidden.frame.x < monitor.x + monitor.width
          && hidden.frame.y >= monitor.y && hidden.frame.y < monitor.y + monitor.height);
      }
    } else {
      console.log("LIMITATION: only one monitor is available; multi-monitor fullscreen acceptance remains open.");
    }
    console.log("PASS: native fullscreen detection, live/persisted toggle, per-display hiding, card clipping, pin dismissal, always-open suppression, late requests, hidden alerts, startup and focus-preserving restoration.");
  } finally {
    replies.close();
    if (fixture.exitCode === null) {
      const exited = once(fixture, "exit");
      fixture.kill();
      await exited;
    }
    await invoke("set_preferences", { preferences: original });
  }
}
async function run() {
  await launch();
  const status = await invoke("runtime_status");
  assert.ok(status.applicationId.endsWith(".smoke"), "Native tests require the isolated .smoke build identity");
  assert.equal(status.version, product.version);
  assert.equal(status.channel, product.channel);
  if (identityOnly) {
    await page.getByRole("button", { name: "About", exact: true }).click();
    assert.equal(await page.locator(".build-label").textContent(), product.channel === "release" ? "Windows" : "Windows development");
    const about = await page.locator(".about-list").textContent();
    assert.ok(about.includes(product.version));
    assert.ok(about.includes(product.channel === "release" ? "Unsigned local production build" : "Unsigned development build"));
    assert.equal(await page.locator("#error").isVisible(), false);
    console.log(`PASS: native ${status.channel} ${status.version} identity and unsigned distribution presentation.`);
    return;
  }
  if (fullscreenOnly) {
    await fullscreenSmoke();
    return;
  }
  console.log("Native display fixture:", JSON.stringify(await invoke("displays")));
  let state = await invoke("app_snapshot");
  assert.equal(state.preferences.history, true, "Fresh installations enable usage history");
  assert.equal(state.connections.cli, false);
  await invoke("set_preferences", { preferences: { ...state.preferences, history: false } });
  assert.equal((await invoke("app_snapshot")).preferences.history, false, "History can be paused before connecting");
  await page.waitForFunction(() => document.querySelector("#usage-account-status")?.textContent.includes("Account quota is off"));
  await invoke("connection", { source: "cli", operation: "install", metrics: false });
  state = await invoke("app_snapshot");
  assert.equal(state.connections.cli, true);
  assert.equal(state.preferences.history, true, "Connecting a client starts usage history");
  await invoke("set_preferences", { preferences: { ...state.preferences, history: true, timelines: true,
    rememberNotices: true, edge: "left", onboardingComplete: true } });
  await hook("userPromptSubmitted", { prompt: "SYNTHETIC CONTENT MUST BE DISCARDED" });
  await hook("sessionStart", { source: "new" });
  state = await invoke("app_snapshot");
  assert.equal(state.sessions[0].working, true, "A late CLI startup hook cannot cancel the first prompt");
  await page.getByRole("button", { name: "Refresh status" }).click();
  await page.locator("#cli-usage-status").filter({ hasText: "No samples received" }).waitFor();
  const usage = { eventId: "synthetic-call", usageContract: 1, inputTokens: 1000, outputTokens: 200,
    cacheReadTokens: 300, cacheReadTokensReported: true, cacheWriteTokens: 100, cacheWriteTokensReported: true,
    model: "synthetic-model", durationMs: 1000, timeToFirstTokenMs: 100 };
  await hook("usage", usage);
  await hook("usage", usage);
  await hook("context", { eventId: "synthetic-context", currentTokens: 800, tokenLimit: 1000 });
  await hook("notification", { hook_event_name: "Notification", notification_type: "elicitation_dialog",
    message: "SYNTHETIC CONTENT MUST BE DISCARDED" });
  state = await invoke("app_snapshot");
  assert.equal(state.samples.length, 1);
  assert.equal(state.samples[0].tokens.model, "synthetic-model");
  assert.equal(state.sessions[0].working, true);
  assert.equal(state.sessions[0].context.context.currentTokens, 800);
  assert.equal(state.today.days[0].usage.calls, 1);
  assert.ok(state.today.coverageBegan >= state.today.startedAt);
  assert.ok(state.today.hourlyCoverage.some(row => row.source === "cli" && row.recordingSeconds > 0));
  assert.ok(state.today.hourlyCoverage.some(row => row.source === "all" && row.recordingSeconds > 0));
  await invoke("connection", { source: "vscode", operation: "install", metrics: true });
  const fake = fakeVSCode();
  fake.snapshotConfiguration = true;
  const nativeStore = new WindowsStore(root);
  await nativeStore.assertRoot();
  const companion = new Companion(fake.vscode, { platform: "win32", store: nativeStore,
    context: fake.context, environment: {} });
  const setup = await companion.run();
  assert.equal(setup.status, "configured", setup.message);
  state = await invoke("app_snapshot");
  assert.equal(state.connections.vscode, true);
  assert.equal(state.receiverRunning, true);
  await page.waitForFunction(async () => {
    const snapshot = await window.__TAURI_INTERNALS__.invoke("app_snapshot");
    return ["vscodeLocal", "vscodeCopilot"].every(source =>
      snapshot.today.hourlyCoverage.some(row => row.source === source && row.recordingSeconds > 0));
  });
  state = await invoke("app_snapshot");
  assert.ok(state.today.hourlyCoverage.some(row => row.source === "vscodeLocal" && row.recordingSeconds > 0));
  assert.ok(state.today.hourlyCoverage.some(row => row.source === "vscodeCopilot" && row.recordingSeconds > 0));
  await invoke("connection", { source: "vscode", operation: "disableMetrics", metrics: false });
  const usageRemoval = await companion.run();
  assert.equal(usageRemoval.status, "removed", usageRemoval.message);
  assert.equal((await invoke("app_snapshot")).connections.vscode, true, "usage removal must preserve lifecycle setup");
  await invoke("connection", { source: "vscode", operation: "remove", metrics: false });
  const editorRemoval = await companion.run();
  assert.equal(editorRemoval.status, "removed", editorRemoval.message);
  assert.equal((await invoke("app_snapshot")).connections.vscode, false);
  assert.equal(state.today.days[0].usage.input, 600);
  assert.equal(state.notices[0].kind, "inputRequested");
  assert.ok((await invoke("timelines", { session: null })).length >= 3);
  await page.getByRole("button", { name: "Usage", exact: true }).click();
  await page.getByRole("button", { name: "Refresh status" }).click();
  await page.locator('#usage-summary [data-metric="tokens"]').filter({ hasText: "1,200 tokens today" }).waitFor();
  await page.locator("#models").filter({ hasText: "synthetic-model" }).waitFor();
  const usageBars = page.locator("#usage-chart .bucket");
  assert.equal(await usageBars.evaluateAll(bars => bars.reduce((sum, bar) => sum + Number(bar.dataset.tokens), 0)), 1200);
  assert.equal(await page.locator("#usage-chart [data-current]").count(), 1);
  const pages = () => browser.contexts().flatMap(context => context.pages());
  const notch = pages().find(candidate => candidate.url().includes("surface=notch"));
  assert.ok(notch, "Native notch page was not created");
  await notch.locator("#notch .notch-label").waitFor();
  const widget = pages().find(candidate => candidate.url().includes("surface=card"));
  assert.ok(widget, "Native summary card page was not created");
  assert.ok(state.accessibility?.textScale >= 1, state.accessibilityError ?? "Windows visual preferences unavailable");
  // Motion follows only Tokenotch's Reduce motion toggle, even when Windows animation effects are off.
  const motionAllowed = !state.preferences.reduceMotion;
  await notch.locator(".ring-activity circle").waitFor();
  // Refreshes may replace the node between calls; always read the live one.
  await notch.waitForFunction(name => {
    const node = document.querySelector(".ring-activity circle");
    return node && window.getComputedStyle(node).animationName === name;
  }, motionAllowed ? "notch-spin" : "none");
  if (motionAllowed) {
    const elapsed = () => document.querySelector(".ring-activity circle")?.getAnimations()[0]?.currentTime ?? null;
    const start = await notch.waitForFunction(elapsed).then(handle => handle.jsonValue());
    await notch.waitForFunction(begin => (document.querySelector(".ring-activity circle")?.getAnimations()[0]?.currentTime ?? 0) > begin + 100, start);
  }
  await widget.waitForFunction(() => document.querySelector("#card")?.inert === true);
  await notch.locator("#notch").hover();
  await widget.waitForFunction(() => document.querySelector("#card")?.inert === false);
  await widget.waitForFunction(name => {
    const node = document.querySelector(".session-row .icon.signal-working");
    return node && window.getComputedStyle(node).animationName === name;
  }, motionAllowed ? "session-spin" : "none");
  assert.equal((await invoke("app_snapshot")).windowFocused, true, "Hover must preserve Settings focus");
  assert.equal(await widget.evaluate(async () => (await window.__TAURI_INTERNALS__.invoke("app_snapshot")).windowFocused), false);
  await widget.evaluate(() => window.__TAURI_INTERNALS__.invoke("set_expanded",{expanded:false,dismiss:true}));
  await widget.waitForFunction(() => document.querySelector("#card")?.inert === true);
  await invoke("show_summary");
  await widget.waitForFunction(() => !document.querySelector("#card")?.inert && document.activeElement?.id === "summary-close");
  assert.equal(await widget.evaluate(async () => (await window.__TAURI_INTERNALS__.invoke("app_snapshot")).windowFocused), true);
  await widget.keyboard.press("Escape");
  await widget.waitForFunction(() => document.querySelector("#card")?.inert === true);
  assert.equal((await invoke("app_snapshot")).windowFocused, true, "Escape must restore the initiating Settings window");
  await widget.waitForFunction(() => [...document.querySelectorAll("#widget-chart .bucket")].reduce((sum, bar) => sum + Number(bar.dataset.tokens), 0) === 1200);
  assert.equal(await page.locator("#error").isVisible(), false);
  const savedSessions = await invoke("timeline_sessions");
  assert.equal(savedSessions.sessions.length, 1);
  const sessionDetail = await invoke("timeline_detail", { session: state.sessions[0].id, source: "cli" });
  assert.equal(sessionDetail.session, savedSessions.sessions[0].session);
  assert.ok(sessionDetail.events.length >= 3);
  assert.ok(sessionDetail.events.some(row => row.event.tokens?.durationMs === 1000));
  await page.locator("#usage-sessions .session summary").click();
  await page.locator("#usage-sessions [data-session]").click();
  await page.locator("#detail-heading").filter({ hasText: "Session" }).waitFor();
  assert.ok((await page.locator("#detail-content").textContent()).includes("Mean first token"));
  await page.getByRole("button", { name: "Back to previous view", exact: true }).click();
  assert.equal(await page.locator("#usage-sessions [data-session]").evaluate(button => button === document.activeElement), true);
  await widget.evaluate(() => window.__TAURI_INTERNALS__.invoke("set_expanded", { expanded: true }));
  await widget.locator(".widget-root.expanded").waitFor();
  await widget.locator("#widget-source").selectOption("cli");
  await widget.locator('[data-detail="widget-model:synthetic-model"]').click();
  await page.locator("#detail-heading").filter({ hasText: "Selected history evidence" }).waitFor();
  assert.ok((await page.locator("#detail-content").textContent()).includes("Model: synthetic-model"));
  assert.ok((await page.locator("#detail-content").textContent()).includes("1,200 tokens; 1 calls"));
  await hook("usage", { ...usage, eventId: "synthetic-second-call", model: "second-model" });
  await page.getByRole("button", { name: "Refresh status", exact: true }).click();
  assert.equal((await invoke("app_snapshot")).samples.length, 2);
  assert.ok((await page.locator("#detail-content").textContent()).includes("1,200 tokens; 1 calls"), "The selected snapshot must not be recomputed after new delivery");
  await widget.evaluate(() => window.__TAURI_INTERNALS__.invoke("set_expanded", { expanded: false, dismiss: true }));
  state = await invoke("app_snapshot");
  try {
    assert.equal(typeof await invoke("notification_status"), "string");
  } catch (error) {
    assert.ok(String(error).includes("Windows notification settings could not be read") || String(error).includes("Windows notification identity is unavailable"),
      `Unexpected Windows permission error: ${error}`);
    console.log("LIMITATION: the unregistered .smoke identity cannot read Windows notification permission; registered-installation acceptance remains open.");
  }
  await invoke("set_preferences", { preferences: {...state.preferences,notifications:true,notifyContext:true,
    notifyStopped:false,notifyErrors:false,notifyRequests:false,desktopBanner:false,sound:false,expandCard:true,
    quietHours:false,muteNotifications:false,snoozedUntil:0} });
  await hook("notification", {hook_event_name:"Notification",notification_type:"elicitation_dialog"});
  await hook("context", {eventId:"notification-low",currentTokens:690,tokenLimit:1000});
  await hook("context", {eventId:"notification-high",currentTokens:800,tokenLimit:1000});
  await widget.waitForFunction(() => document.querySelector(".widget-root")?.classList.contains("expanded")
    && document.querySelector(".delivery-card")?.textContent.includes("above 80%"));
  state = await invoke("app_snapshot");
  const untouchedRequest = state.notices.find(notice => notice.kind === "inputRequested");
  assert.ok(untouchedRequest && !untouchedRequest.viewed && !untouchedRequest.dismissed);
  assert.equal(state.windowFocused, true, "Automatic expansion must not steal Settings focus");
  assert.equal(await widget.evaluate(async () => (await window.__TAURI_INTERNALS__.invoke("app_snapshot")).windowFocused), false);
  await pollSnapshots(4000);
  await widget.waitForFunction(() => !document.querySelector(".widget-root")?.classList.contains("expanded"));
  state = await invoke("app_snapshot");
  assert.equal(state.notices.find(notice => notice.id === untouchedRequest.id).viewed,false);
  assert.equal(state.notices.find(notice => notice.id === untouchedRequest.id).dismissed,false);
  assert.equal(state.notificationDelivery.desktop,null);
  assert.equal(state.notificationDelivery.sound,null);
  assert.ok(state.notificationDelivery.card.includes("eligible displays"));
  await Promise.all([
    pollSnapshots(1000),
    invoke("set_widget_visible", { visible: false }),
  ]);
  assert.equal(await notch.evaluate(async () => (await window.__TAURI_INTERNALS__.invoke("app_snapshot")).widgetVisible), false);
  await invoke("set_widget_visible", { visible: true });
  assert.equal(await widget.evaluate(async () => (await window.__TAURI_INTERNALS__.invoke("app_snapshot")).widgetAlertUntil), 0,
    "A hidden card must not replay an expired alert");
  await invoke("open_notification", {target:{kind:"notice",id:untouchedRequest.id}});
  await page.locator(`#notice-${untouchedRequest.id}`).waitFor();
  assert.equal((await invoke("app_snapshot")).notices.find(notice => notice.id === untouchedRequest.id).resolved,false);
  await invoke("acknowledge", {id:untouchedRequest.id,dismiss:true});
  assert.equal((await invoke("app_snapshot")).notices.find(notice => notice.id === untouchedRequest.id).resolved,false);
  await invoke("open_notification", {target:{kind:"service"}});
  await page.getByRole("heading",{name:"Notifications",exact:true}).waitFor();
  assert.equal((await invoke("app_snapshot")).preferences.serviceHealth,false);
  const suppressionReceipts = await readFile(join(privateRoot,"notification-receipts.json"));
  await invoke("clear_data",{kind:"notices"});
  assert.deepEqual(await readFile(join(privateRoot,"notification-receipts.json")),suppressionReceipts);
  await invoke("open_notification",{target:{kind:"notice",id:untouchedRequest.id}});
  await page.waitForFunction(() => document.querySelector("#error")?.textContent.includes("expired"));
  state = await invoke("app_snapshot");
  await invoke("set_preferences",{preferences:{...state.preferences,notifications:false}});
  await page.getByRole("button",{name:"Refresh status",exact:true}).click();
  state = await invoke("app_snapshot");
  await invoke("set_preferences", { preferences: { ...state.preferences, accountEnabled: true, cliExecutable: fixtureCLI } });
  await page.getByRole("button", { name: "Usage", exact: true }).click();
  await page.getByRole("button", { name: "Refresh status", exact: true }).click();
  await page.getByRole("button", { name: "Sign in with GitHub", exact: true }).click();
  await page.locator("#usage-account-identity").filter({hasText:"Signed in as @synthetic-user"}).waitFor();
  await page.locator("#quota .plan-percent").filter({hasText:"25% used"}).waitFor();
  state = await invoke("app_snapshot");
  assert.equal(state.accountAuth.status, "signedIn");
  assert.equal(state.account.login, "synthetic-user");
  assert.equal(state.account.quotas[0].usedRequests, 75);
  await writeFile(join(privateRoot,"account","fixture-mode"),"quotaDenied");
  await page.getByRole("button", { name: "Refresh quota", exact: true }).click();
  await page.locator("#quota .plan-percent").filter({hasText:"25% used (stale)"}).waitFor();
  assert.equal((await invoke("app_snapshot")).accountAuth.status, "signedIn");
  await writeFile(join(privateRoot,"account","fixture-mode"),"otherAccount");
  await page.getByRole("button", { name: "Refresh quota", exact: true }).click();
  await page.locator("#usage-account-identity").filter({hasText:"Signed in as @other-user"}).waitFor();
  await page.locator("#quota").filter({hasText:"Usage percentage: Not reported"}).waitFor();
  assert.equal((await invoke("app_snapshot")).account,null,"Never show the previous account's quota");
  await writeFile(join(privateRoot,"account","fixture-mode"),"signedOut");
  await page.getByRole("button", { name: "Refresh quota", exact: true }).click();
  await page.locator("#usage-account-identity").filter({hasText:"Signed in as @synthetic-user"}).waitFor();
  assert.equal((await invoke("app_snapshot")).accountShared, true, "Signed-out private home falls back to the user's CLI sign-in");
  await writeFile(join(root,"copilot","fixture-mode"),"signedOut");
  await page.getByRole("button", { name: "Refresh quota", exact: true }).click();
  await page.locator("#usage-account-identity").filter({hasText:"Signed out of GitHub"}).waitFor();
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await page.locator("#usage-account-identity").filter({hasText:"Signed out of GitHub"}).waitFor();
  assert.equal((await invoke("app_snapshot")).account, null);
  await invoke("clear_data", { kind: "live" });
  state = await invoke("app_snapshot");
  assert.equal(state.samples.length, 0);
  assert.equal(state.today.days.reduce((sum,row) => sum + row.usage.calls,0), 2);
  assert.ok(state.today.sourceGaps.some(gap => gap.source === "cli" && gap.end >= gap.start));
  assert.ok(!(await readFile(join(privateRoot, "usage.sqlite"))).includes(Buffer.from("SYNTHETIC CONTENT")));
  await stop();
  await launch();
  state = await invoke("app_snapshot");
  assert.equal(state.preferences.edge, "left");
  assert.equal(state.samples.length, 0);
  assert.equal(state.sessions.length, 0);
  assert.equal(state.today.days.reduce((sum,row) => sum + row.usage.calls,0), 2);
  await invoke("connection", { source: "cli", operation: "remove", metrics: false });
  assert.equal((await invoke("app_snapshot")).connections.cli, false);
  await invoke("clear_data", { kind: "timelines" });
  await assert.rejects(invoke("timeline_detail", { session: sessionDetail.session, source: null }),
    error => String(error).includes("no retained timeline"));
  await invoke("clear_data", { kind: "history" });
  assert.equal((await invoke("app_snapshot")).today.days.length, 0);
  await fullscreenSmoke();
  console.log("PASS: native WebView2, Windows visual preferences, passive hover, deliberate keyboard summary focus, Escape focus restoration, inert folded cards, isolated CLI/VS Code integration, captured navigation, untouched automatic alerts, typed activation, durable suppression and restart. Actual Windows toasts/audio were not emitted.");
}
try {
  await run();
} finally {
  if (originalTestHome === undefined) delete process.env.TOKENOTCH_TEST_HOME;
  else process.env.TOKENOTCH_TEST_HOME = originalTestHome;
  await stop();
  await rm(root, { recursive: true, force: true, maxRetries: 30, retryDelay: 200 });
}
