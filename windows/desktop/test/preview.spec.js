import { test, expect } from "@playwright/test";
import { emptyUsage, reportingDay } from "../src/usage.js";
import { product } from "../src/product.js";

test("browser preview states collection is off and offers working general controls", async ({ page }) => {
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Not collecting usage" })).toBeVisible();
  await expect(page.locator("#runtime")).toContainText("Browser preview");
  await page.getByRole("button", { name: "General", exact: true }).click();
  await page.getByLabel("Screen edge").selectOption("bottom");
  await expect(page.locator("#preview-widget")).toHaveAttribute("data-edge", "bottom");
  await page.getByLabel("Show activity widget", { exact: false }).uncheck();
  await expect(page.locator("#preview-widget")).toBeHidden();
  await page.getByRole("button", { name: "About", exact: true }).click();
  const release = product.channel === "release";
  await expect(page.getByRole("heading", { name: release ? "Unsigned local build" : "Not a supported Windows release", exact: true })).toBeVisible();
  await expect(page.locator(".about-list")).toContainText(release ? "Unsigned local production build" : "Unsigned development build");
  await expect(page.locator(".about-list")).toContainText(product.version);
  await expect(page.locator(".build-label")).toHaveText(release ? "Windows" : "Windows development");
  expect(errors).toEqual([]);
});

test("narrow layout keeps navigation and status reachable", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.locator("#runtime")).toContainText("Browser preview");
  await page.getByRole("button", { name: "General", exact: true }).click();
  await expect(page.getByLabel("Screen edge")).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: "../test-results/appearance-narrow.png", fullPage: true });
});

test("unconnected allowance opens Usage and offers GitHub sign-in without choosing an executable", async ({ page }) => {
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  await page.locator(".allowance").click();
  await expect(page.getByRole("heading", { name: "Usage", exact: true })).toBeVisible();
  await expect(page.locator("#usage-account-status")).toContainText("Account quota is off");
  await expect(page.locator("#quota")).toContainText("Sign in with GitHub to show your Copilot plan quota");
  await expect(page.locator("#usage-account-identity")).toHaveText("GitHub account not connected");
  await expect(page.getByRole("button", { name: "Sign in with GitHub", exact: true })).toBeVisible();
  await page.locator("#usage-account summary", { hasText: "Account options" }).click();
  await expect(page.locator("#account-cli")).toContainText("detected automatically");
  await page.getByLabel("Copilot plan quota", { exact: false }).check();
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.locator("#usage-account-status")).toContainText("existing Copilot CLI sign-in is used when available");
  await page.getByRole("button", { name: "Connections", exact: true }).click();
  await expect(page.locator('[data-view="connections"]')).not.toContainText("account quota");
});

test("History loads automatically and offers to turn on history instead of failing", async ({ page }) => {
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto("/?page=history");
  await expect(page.locator("#history-results")).toContainText("Track usage over time");
  await expect(page.getByRole("button", { name: "Turn On History\u2026", exact: true })).toBeVisible();
  await expect(page.locator("#recording-badge")).toHaveText("Off");
  await expect(page.getByLabel("Period", { exact: true })).toHaveValue("days30");
  await expect(page.locator("#error")).toBeHidden();
  expect(errors).toEqual([]);
});

test("CLI connection separates hook delivery from model usage and explains extension opt-in", async ({ page }) => {
  const now = Date.now();
  let samples = [];
  await page.route("**/src/bridge.js", async route => {
    const response = await route.fetch();
    await route.fulfill({ response, body: `${await response.text()}
      const demo = bridge.snapshot.bind(bridge);
      bridge.snapshot = async () => ({ ...await demo(), now: ${now},
        connections: { cli: true, vscode: false }, delivery: { cli: ${now} },
        sessions: [{ id: "fixture-session", source: "cli", kind: "working", working: true, observedAt: ${now}, label: "Working" },
          { id: "missing-session", source: "cli", kind: "working", working: true, observedAt: ${now}, label: "Working" }],
        samples: ${JSON.stringify(samples)} });` });
  });
  await page.goto("/");
  await expect(page.locator("#cli-status")).toContainText("Connected - Events received");
  await expect(page.locator("#cli-status .connection-state")).toHaveClass(/\bconnected\b/);
  await expect(page.locator("#vscode-status .connection-state")).toHaveText("Not connected");
  await expect(page.locator("#vscode-status .connection-state")).not.toHaveClass(/\bconnected\b/);
  await expect(page.locator("#cli-usage-status")).toContainText("No samples received");
  await expect(page.locator("#cli-usage-status")).toContainText("2 observed CLI sessions have no retained token/model reports");
  await page.locator(".connection-card summary", { hasText: "CLI tips" }).click();
  await expect(page.locator("#cli-extension-help")).toContainText("copilot --experimental");
  await expect(page.locator("#cli-extension-help")).toContainText("/env");
  await page.getByRole("button", { name: "Usage", exact: true }).click();
  await expect(page.locator("#models")).toContainText("No model usage observed");

  samples = [{ date: now, source: "cli", session: "fixture-session", linked: true,
    tokens: { input: 60, output: 20, cacheInput: 30, cacheWrite: 10,
      cacheInputReported: true, cacheWriteReported: true, model: "fixture-cli-model" } }];
  await page.reload();
  await expect(page.locator("#cli-usage-status")).toContainText("1 retained call;");
  await expect(page.locator("#cli-usage-status")).toContainText("1 observed CLI session has no retained token/model reports");
  await page.getByRole("button", { name: "Usage", exact: true }).click();
  await expect(page.locator("#models")).toContainText("fixture-cli-model");
  await expect(page.locator('#usage-summary [data-metric="tokens"]')).toContainText("120 tokens today");
  await expect(page.locator("#usage-provenance")).toContainText("Input excludes separately reported cache");
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  await expect(page.locator("#widget-models")).toContainText("fixture-cli-model");
  await expect(page.locator("#card")).not.toContainText("no retained token/model reports");
});

test("widget hover expands without invented usage values", async ({ page }) => {
  await page.goto("/?surface=widget");
  await expect(page.locator("#notch .notch-label")).toHaveText("\u2014");
  await page.locator("#notch").hover();
  await expect(page.locator("#card")).toContainText("Connect account for allowance");
  await expect(page.locator("#card .activity")).toContainText("No recent activity observed");
  await expect(page.locator("#widget-models")).toContainText("No samples observed.");
  await page.screenshot({ path: "../test-results/widget.png" });
  await page.getByRole("button", { name: "Settings\u2026", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Connections", exact: true })).toBeVisible();
});

test("live-only charts label unknown hours and never manufacture seven-day history", async ({ page }) => {
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  await expect(page.locator("#widget-coverage")).toHaveText("Live usage only; not saved");
  await expect(page.locator("#widget-chart .bar")).toHaveCount(0);
  await expect(page.locator("#widget-chart [data-current]")).toHaveCount(1);
  await expect(page.locator('#widget-chart [data-current]')).toHaveAttribute("data-coverage", "unavailable");
  await page.getByRole("button", { name: "Last 7 days", exact: true }).click();
  await expect(page.locator("#widget-chart")).toContainText("Earlier data cannot be reconstructed");
});

test("saved charts share Usage totals, source filters, explicit coverage and clock labels", async ({ page }) => {
  const day = reportingDay("2026-09-30", "UTC");
  const now = Date.parse("2026-09-30T02:30:00Z");
  const hour = "2026-09-30T00:00:00+00:00";
  const archive = { startedAt: day.start, coverageBegan: day.start, timeZone: "UTC", calendar: [day],
    gaps: [], sourceGaps: [], compactions: [], truncated: false,
    days: [{ day: day.day, source: "cli", model: "CLI model", usage: { ...emptyUsage(), input: 10, calls: 1 } },
      { day: day.day, source: "vscodeLocal", model: null, usage: { ...emptyUsage(), input: 20, calls: 1 } }],
    hours: [{ hour, source: "cli", usage: { ...emptyUsage(), input: 10, calls: 1 } },
      { hour, source: "vscodeLocal", usage: { ...emptyUsage(), input: 20, calls: 1 } }],
    coverage: [{ bucket: day.day, source: "all", recordingSeconds: 5400 }],
    hourlyCoverage: [{ bucket: hour, source: "all", recordingSeconds: 3600 },
      { bucket: "2026-09-30T01:00:00+00:00", source: "all", recordingSeconds: 1800 },
      { bucket: hour, source: "cli", recordingSeconds: 3600 }] };
  await page.route("**/src/bridge.js", async route => {
    const response = await route.fetch();
    await route.fulfill({ response, body: `${await response.text()}
      const demo = bridge.snapshot.bind(bridge);
      bridge.snapshot = async () => ({ ...await demo(), now: ${now}, today: ${JSON.stringify(archive)},
        archives: { history: "history", historyRevision: 1, timelines: "timelines", live: "live", timelineCutoff: 0 },
        samples: [{ date: ${now}, source: "cli", tokens: { input: 999, output: 0, cacheInput: 0, cacheWrite: 0 } }] });
      bridge.history = async () => (${JSON.stringify(archive)});` });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Usage", exact: true }).click();
  await expect(page.locator('#usage-summary [data-metric="tokens"]')).toContainText("30 tokens today");
  await expect(page.locator("#usage-chart .bucket")).toHaveCount(3);
  await expect(page.locator("#usage-chart .bucket").first()).toHaveAttribute("data-tokens", "30");
  await expect(page.locator("#usage-chart .bucket-hit").nth(1)).toHaveAttribute("aria-label", /0 observed tokens; 0 calls; Partial coverage/);
  await expect(page.locator("#usage-chart [data-current]")).toHaveAttribute("data-coverage", "unavailable");
  await page.getByLabel("Usage source", { exact: true }).selectOption("cli");
  await expect(page.locator('#usage-summary [data-metric="tokens"]')).toContainText("10 tokens today");
  await expect(page.locator("#usage-chart .bucket").first()).toHaveAttribute("data-tokens", "10");
  await page.getByRole("button", { name: "General", exact: true }).click();
  await page.getByLabel("Time format", { exact: true }).selectOption("12");
  await page.getByRole("button", { name: "Usage", exact: true }).click();
  await expect(page.locator("#usage-chart .bucket-hit").first()).toHaveAttribute("aria-label", /AM/);
  await page.getByRole("button", { name: "History", exact: true }).click();
  await expect(page.locator("#history-results .chart .bucket").first()).toHaveAttribute("data-tokens", "30");
  await page.locator("#history-results summary", { hasText: "Daily breakdown" }).click();
  await expect(page.locator("#history-results .daily-breakdown")).toContainText("1 h 30 min");
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  await expect(page.locator("#widget-chart .bucket").first()).toHaveAttribute("data-tokens", "30");
  await page.getByLabel("Usage source", { exact: true }).selectOption("cli");
  await expect(page.locator("#widget-chart .bucket").first()).toHaveAttribute("data-tokens", "10");
  await page.getByRole("button", { name: "Last 7 days", exact: true }).click();
  await expect(page.locator("#widget-chart .bucket").first()).toHaveAttribute("data-tokens", "10");
  await expect(page.locator("#widget-models")).toContainText("CLI model");
  await expect(page.locator("#error")).toBeHidden();
});
