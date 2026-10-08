import test from "node:test";
import assert from "node:assert/strict";
import { layout, notchSize, ringCenter, badgeRect, sideNotchPolygon, tooltipPolygons, clampTailOffset, cardPlacement,
  tooltipDirection, clampScale } from "../../desktop/src/geometry.js";
import { glyphLoops, glyphPath } from "../../desktop/src/glyph.js";
import { compact, calls, relative, usageLevel, usageDash, sessionRows, activityTitle, sessionSignal, quotaWarning,
  modelRows, canExpandModels, cacheDisplay, inputDisplay, ringReading, provenance, headlineLevel, primaryQuota, accountStatus, accountIdentity, contextReading } from "../../desktop/src/presentation.js";
import { breakdownMarkup, modelsMarkup, sessionsMarkup } from "../../desktop/src/card.js";
import { emptyUsage, niceCeiling } from "../../desktop/src/usage.js";

const close = (actual, expected, message) => assert.ok(Math.abs(actual - expected) < 0.01, `${message}: ${actual} vs ${expected}`);

test("notch metrics are the macOS reference pixels times 44/117 and scale linearly", () => {
  close(layout.ringDiameter, 44, "ring");
  close(layout.cardWidth, 320.03, "card width");
  const right = notchSize("right");
  close(right.width, 69.95, "side depth");
  close(right.height, 2 * layout.curlRadius + layout.padStart + layout.padEnd + layout.ringDiameter + layout.ringLabelGap + layout.labelHeight, "side length");
  const top = notchSize("top");
  close(top.width, 2 * layout.curlRadius + layout.padStart + layout.padEnd + layout.ringDiameter, "top length");
  close(top.height, layout.bodyDepth + layout.ringLabelGap + layout.labelHeight, "top depth");
  close(notchSize("left", 1.5).height, right.height * 1.5, "scaled");
  assert.equal(clampScale(9), 1.5);
  assert.equal(clampScale(Number.NaN), 1);
  const center = ringCenter(right, "right");
  close(center.x, right.width / 2, "ring x");
  close(center.y, layout.curlRadius + layout.padStart + layout.ringDiameter / 2, "ring y");
});

test("the side notch is written once and placed onto every edge with the bezel outward", () => {
  for (const edge of ["right", "left", "top", "bottom"]) {
    const size = notchSize(edge);
    const polygon = sideNotchPolygon(edge, { x: 0, y: 0, ...size });
    for (const [x, y] of polygon) {
      assert.ok(x >= -0.001 && x <= size.width + 0.001 && y >= -0.001 && y <= size.height + 0.001, `${edge} point inside`);
    }
    const [x, y] = polygon[0];
    if (edge === "right") close(x, size.width, "right bezel");
    if (edge === "left") close(x, 0, "left bezel");
    if (edge === "top") close(y, 0, "top bezel");
    if (edge === "bottom") close(y, size.height, "bottom bezel");
  }
  const pill = badgeRect({ x: 0, y: 0, ...notchSize("right") }, "right", 1, true);
  close(pill.width, layout.pillWidth, "pill depth");
  close(pill.x + pill.width, notchSize("right").width, "pill on bezel");
  const polygon = sideNotchPolygon("right", pill);
  assert.ok(polygon.every(([px]) => px >= pill.x - 0.001), "pill corners claim half the width before the flare");
});

test("the card sits beside the notch with its tail aimed at the ring and clamped to the body", () => {
  const notch = { x: 1850, y: 400, ...notchSize("right") };
  const center = { x: notch.x + notch.width / 2, y: notch.y + ringCenter(notch, "right").y };
  const placed = cardPlacement({ notch, ringCenter: center, edge: "right", work: { x: 0, y: 0, width: 1920, height: 1040 }, contentHeight: 600 });
  assert.equal(placed.direction, "leading");
  close(placed.frame.x + placed.frame.width, notch.x - layout.tailGap, "gap before notch");
  close(placed.frame.width, layout.cardWidth + layout.tailLength, "width includes the tail");
  close(placed.frame.y + placed.frame.height / 2 + placed.tailOffset, center.y, "tail aims at ring");
  const shape = tooltipPolygons("leading", placed.frame, placed.tailOffset);
  close(shape.tip[0], placed.frame.width, "tip at the trailing edge");
  close(shape.tip[1], center.y - placed.frame.y, "tip at ring height");
  const tall = cardPlacement({ notch, ringCenter: center, edge: "right", work: { x: 0, y: 0, width: 1920, height: 500 }, contentHeight: 2000 });
  assert.ok(tall.frame.height <= 484 && tall.frame.y >= 8, "height and origin stay in the work area");
  const limit = clampTailOffset("leading", { width: 300, height: 100 }, 1000);
  assert.ok(limit < 50, "the tail never leaves the straight part of the card");
  const top = cardPlacement({ notch: { x: 900, y: 0, ...notchSize("top") }, ringCenter: { x: 950, y: 30 }, edge: "top",
    work: { x: -1920, y: 0, width: 3840, height: 1040 }, contentHeight: 300 });
  assert.equal(top.direction, tooltipDirection("top"));
  assert.ok(top.frame.y >= notchSize("top").height + layout.tailGap - 0.01);
});

test("the Copilot glyph keeps its eight contours", () => {
  assert.equal(glyphLoops.length, 8);
  assert.equal(glyphPath.match(/M/g).length, 8);
  assert.ok(glyphLoops.flat().every(([x, y]) => x >= 0 && x <= 1 && y >= 0 && y <= 1));
});

test("usage colours change at 75% and 90% and carry a texture as well", () => {
  assert.equal(usageLevel(0.749), "ample");
  assert.equal(usageLevel(0.75), "watch");
  assert.equal(usageLevel(0.9), "exhausted");
  assert.deepEqual(usageDash(0.5), []);
  assert.deepEqual(usageDash(0.8), [6, 3]);
  assert.deepEqual(usageDash(0.95), [2.5, 2.5]);
});

test("numbers and times read as on the macOS card", () => {
  assert.match(compact(196_300_000), /196\.3M/);
  assert.match(compact(1_400), /1\.4K/);
  assert.equal(calls(1), "1 call");
  assert.match(calls(1637), /1,637 calls/);
  assert.equal(relative(1000, 1500), "just now");
  assert.equal(relative(0, 19_000), "19s ago");
  assert.equal(relative(0, 16 * 60_000), "16m ago");
  assert.equal(relative(2 * 86_400_000, 0), "in 2d");
  assert.equal(niceCeiling(4_000_000), 6_000_000);
  assert.equal(niceCeiling(55_000_000), 60_000_000);
});

test("context percentages preserve over-limit readings while the bar remains capped", () => {
  const now = 1_000_000;
  for (const [currentTokens, fraction, label, width] of [
    [0, 0, "0%", null], [75, 0.75, "75%", "75.00%"],
    [100, 1, "100%", "100.00%"], [120, 1.2, "120%", "100.00%"],
  ]) {
    for (const age of [0, 300_001]) {
      const session = { id: "abcdef", source: "cli", kind: "active", working: true, observedAt: now,
        context: { context: { currentTokens, tokenLimit: 100 }, observedAtUnixMs: now - age } };
      const reading = contextReading(session, now);
      assert.equal(reading.fraction, fraction);
      assert.equal(reading.stale, age > 300_000);
      const snapshot = { now, sessions: [session], notices: [] };
      const markup = sessionsMarkup(snapshot, sessionRows(snapshot), "Working", "working");
      assert.ok(markup.includes(`${currentTokens} of 100 context tokens (${label}${age ? " (stale)" : ""})`));
      assert.ok(markup.includes(`class="numeric">${label}${age ? " (stale)" : ""}</span>`));
      const fill = markup.match(/class="capsule-fill [^"]+" width="([^"]+)"/);
      assert.equal(fill?.[1] ?? null, width, "Only the SVG bar width is capped");
      assert.ok(markup.includes(`aria-label="${currentTokens} of 100 context tokens (${label}`));
    }
  }
  assert.equal(contextReading({}, now), null);
});

test("session rows put errors and requests first and describe live work without inventing success", () => {
  const now = 10_000_000;
  const snapshot = { now, sessions: [
    { id: "9b3384aaaa", source: "cli", kind: "active", working: true, observedAt: now - 1000, workStartedAt: now - 16 * 60_000 },
    { id: "d9f611bbbb", source: "cli", kind: "idle", working: false, observedAt: now - 19_000 },
    { id: "eeeeeecccc", source: "vscode", kind: "working", working: false, observedAt: now - 400_000 },
    { id: "ffffffdddd", source: "cli", kind: "ended", working: false, observedAt: now - 1000 },
  ], notices: [] };
  const rows = sessionRows(snapshot);
  assert.deepEqual(rows.map(row => [row.label, row.title]), [
    ["CLI 9b3384", "Working"], ["VS Code eeeeee", "Activity updates missing"], ["CLI d9f611", "Idle"]]);
  assert.equal(rows[0].detail, "Observed for 16m");
  assert.equal(rows[2].detail, "Last reported 19s ago");
  assert.equal(activityTitle(snapshot, rows), "1 working");
  snapshot.notices = [{ id: "n1", session: "123456789", source: "cli", kind: "inputRequested", timestamp: now - 1000, viewed: false, dismissed: false, resolved: false, restored: false }];
  const attention = sessionRows(snapshot);
  assert.equal(attention[0].title, "Input requested");
  assert.match(attention[0].detail, /response unknown/);
  assert.equal(activityTitle(snapshot, attention), "1 session requested attention");
  assert.equal(sessionSignal(snapshot, attention), "input");
  assert.equal(activityTitle({ now, sessions: [], notices: [] }), "No recent activity observed");
});

test("quota readings follow the primary quota, staleness and the shared watch threshold", () => {
  const now = 1_000_000;
  const account = { observedAt: now, quotas: [{ id: "chat", isUnlimitedEntitlement: true, remainingPercentage: 100 },
    { id: "premium_interactions", isUnlimitedEntitlement: false, remainingPercentage: 20 }] };
  assert.equal(primaryQuota(account).id, "premium_interactions");
  const snapshot = { now, account, sessions: [], notices: [] };
  assert.equal(ringReading(snapshot).label, "80%");
  assert.equal(quotaWarning(snapshot), "Premium requests: near reported limit");
  assert.equal(headlineLevel(snapshot), "watch");
  assert.equal(ringReading({ ...snapshot, now: now + 200_000 }).stale, true);
  assert.equal(headlineLevel({ ...snapshot, now: now + 200_000 }), "stale");
  assert.equal(ringReading({ now, account: null, sessions: [], notices: [] }).label, "\u2014");
  assert.equal(ringReading({ now, account: { observedAt: now, quotas: [account.quotas[0]] }, sessions: [], notices: [] }).label, "\u221E");
  account.quotas[1].remainingPercentage = 0;
  assert.equal(quotaWarning(snapshot), "Premium requests: reported allowance exhausted");
});

test("account status explains sign-in reuse, quota enablement and reported entitlement", () => {
  const snapshot = { preferences: { accountEnabled: false, cliExecutable: null }, account: null };
  assert.match(accountStatus(snapshot), /quota is off.*Sign in with GitHub/);
  snapshot.preferences.accountEnabled = true;
  assert.match(accountStatus(snapshot), /existing Copilot CLI sign-in is used/);
  assert.equal(accountIdentity(snapshot), "Sign-in status not yet verified");
  snapshot.accountBusy = true;
  assert.equal(accountIdentity(snapshot), "Checking GitHub sign-in...");
  snapshot.accountAuth = { status: "signedOut" };
  assert.equal(accountIdentity(snapshot), "Signed out of GitHub");
  assert.match(accountStatus(snapshot), /in progress/);
  snapshot.accountBusy = false;
  snapshot.account = { quotas: [] };
  assert.match(accountStatus(snapshot), /Signed in.*no account quota/);
  snapshot.account.quotas = [{ id: "premium_interactions" }];
  assert.equal(accountStatus(snapshot), "Account quota connected.");
  snapshot.accountShared = true;
  assert.equal(accountStatus(snapshot), "Account quota connected. Using your Copilot CLI sign-in.");
  snapshot.accountError = "Quota refresh failed.";
  assert.equal(accountStatus(snapshot), snapshot.accountError);
});

test("model rows show the top three named models then fold the rest", () => {
  const usage = tokens => ({ ...emptyUsage(), input: tokens, calls: 1, cacheReportedCalls: 1, writeReportedCalls: 1 });
  const groups = [["a", 50], ["b", 40], ["c", 30], ["d", 20], ["", 10]].map(([model, tokens]) => ({ model, usage: usage(tokens) }));
  const rows = modelRows(groups);
  assert.deepEqual(rows.map(row => row.title), ["a", "b", "c", "Other / unavailable models"]);
  assert.equal(rows[3].usage.input, 30);
  assert.equal(canExpandModels(groups), true);
  assert.deepEqual(modelRows(groups, true).map(row => row.title), ["a", "b", "c", "d", "Other / unavailable models"]);
  assert.deepEqual(modelRows(groups.slice(0, 4)).map(row => row.title), ["a", "b", "c", "Remaining models"]);
});

test("cache values keep reported, partial, omitted and unknown distinct", () => {
  const base = { ...emptyUsage(), calls: 2, cacheInput: 1_500_000, cacheWrite: 0 };
  assert.match(cacheDisplay({ ...base, cacheReportedCalls: 2 }), /^1\.5M$/);
  assert.match(cacheDisplay({ ...base, cacheReportedCalls: 1 }), /^1\.5M\*$/);
  assert.equal(cacheDisplay({ ...base, writeUnreportedCalls: 2 }, true), "n/r");
  assert.equal(cacheDisplay({ ...base }, true), "?");
  assert.equal(cacheDisplay(emptyUsage()), "-");
  assert.equal(provenance({ saved: true, recording: false }), "Saved locally; recording paused");
  assert.equal(provenance({ saved: false, partial: true }), "Live only; sample limit reached");
});

test("one asterisk meaning: every starred value shares the incomplete-cache footnote", () => {
  const usage = (reads, writes) => ({ ...emptyUsage(), calls: 2, input: 1_000, cacheInput: 400,
    cacheReportedCalls: reads, cacheUnreportedCalls: 2 - reads, writeReportedCalls: writes, writeUnreportedCalls: 2 - writes });
  const row = value => ({ model: "m", title: "m", usage: value });
  const complete = usage(2, 2);
  assert.equal(inputDisplay(complete), compact(1_000));
  assert.doesNotMatch(breakdownMarkup(complete), /\*/);
  assert.doesNotMatch(modelsMarkup([row(complete)], null, false, false, false), /card-note/);
  // Unreported everywhere: no partial cache value, but input still carries cache, so it is starred and explained.
  const omitted = usage(0, 0);
  assert.equal(inputDisplay(omitted), `${compact(1_000)}*`);
  assert.doesNotMatch(breakdownMarkup(omitted), /Input\*/);
  assert.match(modelsMarkup([row(omitted)], null, false, false, false), /\* Some calls did not report cache tokens/);
  const partial = usage(1, 2);
  assert.match(breakdownMarkup(partial), new RegExp(`${compact(400)}\\*`));
  assert.match(modelsMarkup([row(partial)], null, false, false, false), /\* Some calls did not report cache tokens/);
  assert.doesNotMatch(modelsMarkup([row(partial)], null, false, false, false), /Input breakdown incomplete/);
});
