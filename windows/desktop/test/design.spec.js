import { test, expect } from "@playwright/test";
import { emptyUsage, reportingDay } from "../src/usage.js";

// A realistic, clearly synthetic fixture modelled on docs/design/tokenotch-stats*.png.
const now = Date.parse("2026-09-29T15:20:00Z");
const hex = (seed) => seed.repeat(64).slice(0, 64);
const models = [
  ["gpt-6-astra", 40.3e6, 1e6, 87.7e6, 4.2e6, 1117, 14000, 23000],
  ["claude-opus-5.5", 261.3e3, 245.7e3, 38.7e6, 1.5e6, 285, 5600, 10000],
  ["claude-opus-5", 17.3e6, 128.9e3, 316.8e3, 0, 157, 8900, 17000],
  ["gpt-5.6-sol", 2.1e6, 30e3, 1.2e6, 90e3, 55, 6000, 9600],
  ["claude-sonnet-5", 0.9e6, 12.9e3, 0.4e6, 26.7e3, 23, 3600, 7500],
];
const weights = [0.24, 0.03, 0.26, 0.12, 0, 0.11, 0.04];

function usage([, input, output, cacheInput, cacheWrite, calls, firstToken, duration], weight) {
  const n = Math.max(1, Math.round(calls * weight));
  return { ...emptyUsage(), input: Math.round(input * weight), output: Math.round(output * weight),
    cacheInput: Math.round(cacheInput * weight), cacheWrite: Math.round(cacheWrite * weight), calls: n,
    cacheReportedCalls: n, writeReportedCalls: cacheWrite ? n - 1 : 0, writeUnreportedCalls: cacheWrite ? 0 : n,
    durationMs: duration * n, durationSamples: n, firstTokenMs: firstToken * n, firstTokenSamples: n };
}
function history(dayKeys) {
  const calendar = dayKeys.map(day => reportingDay(day, "UTC"));
  const days = [];
  const totals = [];
  calendar.forEach((day, index) => {
    const weight = weights[index % weights.length];
    if (!weight) return;
    const rows = models.map(model => ({ day: day.day, source: "cli", model: model[0], usage: usage(model, weight) }));
    days.push(...rows);
    const sum = { ...emptyUsage() };
    for (const row of rows) for (const key of Object.keys(sum)) sum[key] += row.usage[key];
    totals.push({ day: day.day, source: "cli", usage: sum });
  });
  const last = calendar.at(-1);
  const hours = last.hours.filter(hour => hour.start <= now).map((hour, index) => ({ hour: new Date(hour.start).toISOString().replace(".000Z", "+00:00"),
    source: "cli", usage: { ...emptyUsage(), input: [0, 0, 0, 0, 0, 0, 0, 0, 2, 5, 9, 3, 0, 4, 12, 7][index] * 1e5 || 0,
      cacheInput: [0, 0, 0, 0, 0, 0, 0, 0, 6, 12, 30, 9, 0, 11, 28, 15][index] * 1e5 || 0, calls: index > 7 ? 9 : 0 } }))
    .filter(row => row.usage.calls);
  return { generation: "history", capturedAt: now, modelFilter: null, timeZone: "UTC", startedAt: calendar[0].start, coverageBegan: calendar[0].start,
    calendar, days, totals, hours, gaps: [], sourceGaps: [], compactions: [], truncated: false,
    coverage: calendar.map(day => ({ bucket: day.day, source: "all", recordingSeconds: Math.min(86400, Math.max(0, (now - day.start) / 1000)) })),
    hourlyCoverage: last.hours.filter(hour => hour.start <= now).map(hour => ({ bucket: new Date(hour.start).toISOString().replace(".000Z", "+00:00"),
      source: "all", recordingSeconds: Math.min(3600, (now - hour.start) / 1000) })) };
}
const week = ["2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29"];
function fixture({ notices = [], autoHideNotch = false, edge = "right" } = {}) {
  const today = history(["2026-09-29"]);
  return {
    history: history(week),
    snapshot: {
      now, today, archives: { history: "history", timelines: "timelines", live: "live", timelineCutoff: now - 604800000 },
      preferences: { autoHideNotch, edge, history: true },
      connections: { cli: true, vscode: false },
      account: { login: "your-username", plan: "Pro", observedAt: now - 60000, runtimeVersion: "1.0.0", quotas: [
        { id: "premium_interactions", isUnlimitedEntitlement: false, entitlementRequests: 300, usedRequests: 144, remainingPercentage: 52, resetDate: "2026-10-01T00:00:00Z" },
        { id: "chat", isUnlimitedEntitlement: true, entitlementRequests: 0, usedRequests: 0, remainingPercentage: 100, resetDate: null },
        { id: "completions", isUnlimitedEntitlement: true, entitlementRequests: 0, usedRequests: 0, remainingPercentage: 100, resetDate: null }] },
      sessions: [
        { id: hex("9b3384"), source: "cli", kind: "active", label: "Working (live)", working: true, observedAt: now - 5000, workStartedAt: now - 16 * 60000,
          context: { observedAtUnixMs: now - 5000, context: { currentTokens: 22000, tokenLimit: 200000 } } },
        { id: hex("d9f611"), source: "cli", kind: "idle", label: "Idle (live)", working: false, observedAt: now - 19000, workStartedAt: null,
          context: { observedAtUnixMs: now - 400000, context: { currentTokens: 50000, tokenLimit: 200000 } } }],
      samples: [], notices,
    },
  };
}

async function preview(page, seed) {
  await page.clock.install({ time: new Date(now) });
  await page.addInitScript(value => { window.__fixture = value; }, seed);
  await page.route("**/src/bridge.js", async route => {
    const response = await route.fetch();
    await route.fulfill({ response, body: `${await response.text()}
      const originalSnapshot = bridge.snapshot.bind(bridge);
      bridge.snapshot = async () => {
        const base = await originalSnapshot();
        const seed = structuredClone(window.__fixture.snapshot);
        return { ...base, ...seed, preferences: { ...base.preferences, ...seed.preferences } };
      };
      bridge.history = async () => structuredClone(window.__fixture.history);` });
  });
}

test("the notch carries the Copilot ring, quota percentage and working arc", async ({ page }) => {
  await preview(page, fixture());
  await page.setViewportSize({ width: 560, height: 900 });
  await page.goto("/?surface=widget");
  const notch = page.locator("#notch");
  await expect(notch).toHaveAttribute("aria-description", /48 percent used, working \(last reported\)/);
  await expect(notch.locator(".notch-label")).toHaveText("48%");
  await expect(notch.locator(".ring-activity")).toHaveCount(1);
  await expect(page.locator("#card")).toBeHidden();
  await page.screenshot({ path: "../test-results/design-notch.png" });
});

test("hovering the notch opens the stats1 card with every section in order", async ({ page }) => {
  await preview(page, fixture());
  await page.setViewportSize({ width: 560, height: 900 });
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  const card = page.locator("#card");
  await expect(card).toBeVisible();
  await expect(card.locator(".card-title")).toHaveText("GitHub Copilot / Copilot CLI");
  await expect(card.locator(".allowance-headline")).toHaveText("48% used");
  await expect(card.locator(".allowance")).toContainText("Premium requests");
  await expect(card.locator(".activity")).toContainText("1 working");
  await expect(card.locator(".session-row")).toHaveCount(2);
  await expect(card.locator(".session-row").first()).toContainText("CLI 9b3384");
  await expect(card.locator(".session-row").first()).toContainText("Observed for 16m");
  await expect(card.locator(".session-row").nth(1)).toContainText("25% (stale)");
  await expect(card.locator("#widget-chart .bucket")).not.toHaveCount(0);
  await expect(card.locator(".model-row")).toHaveCount(4);
  await expect(card.locator(".model-row").first()).toContainText("gpt-6-astra");
  await expect(card.locator(".model-row").last()).toContainText("Remaining models");
  await expect(card.locator(".card-footer")).toContainText("View history");
  await expect(card.locator("#widget-coverage")).toHaveText("Usage data saved locally");
  const headings = await card.locator(".card-heading").allTextContents();
  expect(headings).toEqual(["Usage", "Sessions", "Models' Usage Chart", "Models Breakdown"]);
  await page.getByRole("button", { name: "Last 7 days", exact: true }).click();
  await expect(page.getByRole("button", { name: "Last 7 days", exact: true })).toHaveAttribute("aria-pressed", "true");
  await expect(card.locator("#widget-chart .bucket")).toHaveCount(7);
  await expect(card.locator("#widget-chart .bucket-tick").first()).toHaveText(/Wed/);
  await page.screenshot({ path: "../test-results/design-card.png" });
  await card.getByRole("button", { name: "Show all models" }).click();
  await expect(card.locator(".model-row")).toHaveCount(5);
});

test("the card follows the notch onto every edge with its tail aimed at the ring", async ({ page }) => {
  for (const edge of ["left", "top", "bottom"]) {
    await preview(page, fixture({ edge }));
    await page.setViewportSize({ width: edge === "left" ? 560 : 900, height: 900 });
    await page.goto("/?surface=widget");
    await page.locator("#notch").hover();
    await expect(page.locator("#card")).toHaveAttribute("data-direction", { left: "trailing", top: "down", bottom: "up" }[edge]);
    const notch = await page.locator("#notch").boundingBox();
    const card = await page.locator("#card").boundingBox();
    if (edge === "left") expect(card.x).toBeGreaterThan(notch.x + notch.width);
    if (edge === "top") expect(card.y).toBeGreaterThan(notch.y + notch.height - 1);
    if (edge === "bottom") expect(card.y + card.height).toBeLessThan(notch.y + 1);
    await page.screenshot({ path: `../test-results/design-card-${edge}.png` });
  }
});

test("the folded notch is a slim gauge until hovered", async ({ page }) => {
  await preview(page, fixture({ autoHideNotch: true }));
  await page.setViewportSize({ width: 560, height: 900 });
  await page.goto("/?surface=widget");
  await expect(page.locator("#notch")).toHaveAttribute("data-collapsed", "true");
  await expect(page.locator("#notch .gauge")).toHaveCount(1);
  await page.screenshot({ path: "../test-results/design-pill.png" });
  await page.locator("#notch").hover();
  await expect(page.locator("#notch")).toHaveAttribute("data-collapsed", "false");
});

test("request notices show a dismiss check that never answers the request", async ({ page }) => {
  const notice = { id: "a".repeat(64), session: "c".repeat(64), source: "cli", kind: "inputRequested", timestamp: now - 7 * 60000,
    viewed: false, dismissed: false, resolved: false, restored: false };
  await preview(page, fixture({ notices: [notice] }));
  await page.setViewportSize({ width: 560, height: 900 });
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  const row = page.locator(`#notice-${notice.id}`);
  await expect(row).toContainText("Input requested");
  await expect(row).toContainText("response unknown");
  await expect(row.getByRole("button", { name: /Dismiss input requested/ })).toBeVisible();
  await expect(page.locator(".activity")).toContainText("1 session requested attention");
  await expect(page.locator("#notch .ring-badge")).toHaveCount(1);
});

test("settings Usage and History follow the grouped macOS layout", async ({ page }) => {
  await preview(page, fixture());
  await page.setViewportSize({ width: 1100, height: 1400 });
  await page.goto("/?page=usage");
  await expect(page.locator("#quota")).toContainText("@your-username");
  await expect(page.locator("#quota .plan-percent")).toContainText("48%");
  await expect(page.locator("#quota")).toContainText("Unlimited");
  await expect(page.locator('#usage-summary [data-metric="tokens"]')).toBeVisible();
  await expect(page.locator("#usage-summary .token-legend")).toContainText("Cache read");
  await expect(page.locator("#usage-sessions details.session")).toHaveCount(2);
  await page.screenshot({ path: "../test-results/design-settings-usage.png", fullPage: true });
  await page.getByRole("button", { name: "History", exact: true }).click();
  await page.getByLabel("Period", { exact: true }).selectOption("week");
  await expect(page.locator("#recording-badge")).toHaveText("Recording");
  await expect(page.locator("#history-results .chart-settings .bucket")).toHaveCount(7);
  await expect(page.locator("#history-results .models-table tbody tr")).toHaveCount(5);
  for (const heading of ["Daily tokens", "Models", "Compared with previous period", "Weekly insights"]) {
    await expect(page.locator("#history-results .section-title", { hasText: heading })).toHaveCount(1);
  }
  await expect(page.locator('#history-results [data-metric="average"]')).toContainText("Daily average");
  await expect(page.locator("#history-footer")).toContainText("Times use UTC.");
  await page.screenshot({ path: "../test-results/design-settings-history.png", fullPage: true });
});
