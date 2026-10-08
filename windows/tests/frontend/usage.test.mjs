import test from "node:test";
import assert from "node:assert/strict";
import { fromTokens, total, cache, merge, todayRows, contextDescription, escape,
  emptyUsage, reportingDay, bucketCoverage, historyTimeline, todayTimeline, chartMarkup, cliReportingGap, modelGroups } from "../../desktop/src/usage.js";

test("inclusive-input accounting keeps cache availability separate from numeric totals", () => {
  const tokens = { input: 60, output: 20, cacheInput: 30, cacheWrite: 10, cacheInputReported: true, cacheWriteReported: true };
  const usage = fromTokens(tokens);
  assert.equal(total(usage), 120);
  assert.equal(cache(usage), "30");
  assert.equal(cache(usage, true), "10");
  const unreported = fromTokens({ ...tokens, cacheInput: 0, cacheInputReported: false });
  assert.equal(cache(unreported), "Not reported");
  assert.equal(cache(merge([usage, unreported])), "30 *");
  assert.equal(cache(fromTokens({ ...tokens, cacheInput: 0, cacheInputReported: undefined })), "Unknown");
});

test("saved today replaces rather than adds live calls, including paused history", () => {
  const row = { source: "cli", usage: { calls: 1 } };
  const snapshot = { today: { startedAt: 1, days: [row] }, samples: [{ tokens: {} }], now: Date.now() };
  assert.deepEqual(todayRows(snapshot), [row]);
  assert.deepEqual(todayRows(snapshot, "vscodeLocal"), []);
});

test("CLI totals match inclusive input while preserving the API model and missing session reports", () => {
  const now = Date.now();
  const snapshot = { now, today: null, sessions: [
    { id: "reported", source: "cli", model: "selected-session-model" },
    { id: "missing", source: "cli" }, { id: "editor", source: "vscode" },
  ], samples: [{ date: now, session: "reported", source: "cli", tokens: {
    model: "reported-api-model", input: 3, output: 5, cacheInput: 0, cacheWrite: 14454,
    cacheInputReported: true, cacheWriteReported: true,
  } }] };
  const groups = modelGroups(todayRows(snapshot, "cli"));
  assert.deepEqual(groups.map(group => group.model), ["reported-api-model"]);
  assert.equal(total(groups[0].usage), 14462);
  assert.equal(groups[0].usage.input + groups[0].usage.cacheInput + groups[0].usage.cacheWrite, 14457);
  assert.match(cliReportingGap(snapshot), /^1 observed CLI session has no retained token\/model reports/);
  snapshot.samples.push({ ...snapshot.samples[0], session: "missing", source: "vscodeLocal" });
  assert.match(cliReportingGap(snapshot), /^1 observed CLI session/);
  snapshot.samples.push({ ...snapshot.samples[0], session: "missing" });
  assert.equal(cliReportingGap(snapshot), "");
});

test("missing and stale context do not become fresh zero", () => {
  assert.equal(contextDescription(null, 0), "Context: Not reported");
  assert.match(contextDescription({ context: { currentTokens: 110, tokenLimit: 100 }, observedAtUnixMs: 0 }, 300001), /110.0%.*stale/);
});

test("all dynamic HTML strings are escaped", () => {
  assert.equal(escape('<a title="x">&'), "&lt;a title=&quot;x&quot;&gt;&amp;");
});

function historyFixture() {
  const calendar = reportingDay("2026-09-30", "UTC");
  const coverageBegan = calendar.start;
  const hour = "2026-09-30T00:00:00+00:00";
  return { timeZone: "UTC", startedAt: coverageBegan, coverageBegan, calendar: [calendar], gaps: [], sourceGaps: [],
    coverage: [{ bucket: calendar.day, source: "all", recordingSeconds: 3600 }],
    hourlyCoverage: [{ bucket: hour, source: "all", recordingSeconds: 3600 }, { bucket: hour, source: "cli", recordingSeconds: 3600 }],
    days: [{ day: calendar.day, source: "cli", model: "known", usage: { ...emptyUsage(), input: 10, calls: 1 } },
      { day: calendar.day, source: "vscodeLocal", model: null, usage: { ...emptyUsage(), input: 20, calls: 1 } }],
    hours: [{ hour, source: "cli", usage: { ...emptyUsage(), input: 10, calls: 1 } },
      { hour, source: "vscodeLocal", usage: { ...emptyUsage(), input: 20, calls: 1 } }] };
}
test("coverage distinguishes unavailable, partial zero and recorded zero", () => {
  const bucket = { start: 0, end: 3600000, calls: 0, recordingSeconds: 0, gap: false };
  assert.equal(bucketCoverage(bucket, 3600000), "unavailable");
  assert.equal(bucketCoverage({ ...bucket, recordingSeconds: 60 }, 3600000), "partial");
  assert.equal(bucketCoverage({ ...bucket, recordingSeconds: 3600 }, 3600000), "recorded");
  assert.equal(bucketCoverage({ ...bucket, recordingSeconds: 3600, gap: true }, 3600000), "partial");
  assert.equal(bucketCoverage({ ...bucket, calls: 1 }, 3600000), "partial");
  assert.equal(bucketCoverage({ ...bucket, start: 4000000 }, 3600000), "future");
});
test("hourly charts aggregate selected sources and never add live samples to saved totals", () => {
  const today = historyFixture();
  const snapshot = { today, now: today.calendar[0].start + 3600000, samples: [{ tokens: { input: 999 } }] };
  const all = todayTimeline(snapshot);
  assert.equal(all.buckets.length, 2, "only elapsed hours and the unfinished current hour");
  assert.equal(all.buckets[0].tokens, total(merge(todayRows(snapshot).map(row => row.usage))));
  assert.equal(all.buckets[0].tokens, 30);
  assert.equal(all.buckets[0].recordingSeconds, 3600, "all-source duration is a union, not a sum");
  assert.equal(all.buckets[0].coverage, "recorded");
  assert.equal(all.buckets[1].coverage, "unavailable");
  assert.ok(all.buckets[1].current);
  const cli = todayTimeline(snapshot, "cli");
  assert.equal(cli.buckets[0].tokens, 10);
  assert.equal(cli.buckets[0].coverage, "recorded");
  assert.equal(todayTimeline(snapshot, "vscodeLocal").buckets[0].coverage, "partial");
  assert.equal(todayTimeline(snapshot, "vscodeCopilot").buckets[0].coverage, "unavailable");
});
test("imports and legacy migration mark partial coverage without creating opportunity", () => {
  const history = historyFixture();
  const now = history.calendar[0].end;
  history.sourceGaps.push({ source: "cli", start: history.calendar[0].start, end: history.calendar[0].start });
  assert.equal(historyTimeline(history, now, "cli", true)[0].coverage, "partial");
  history.coverageBegan = history.calendar[0].start + 1;
  assert.equal(historyTimeline(history, now, "all", true)[0].coverage, "partial");
  delete history.coverageBegan;
  assert.equal(historyTimeline(history, now, "all", true)[0].coverage, "partial");
});
test("live-only Today is source filtered and empty hours remain unavailable", () => {
  const now = new Date(2026, 8, 30, 12, 30).getTime();
  const sample = { date: now, source: "cli", tokens: { input: 100, output: 20, cacheInput: 30, cacheWrite: 10 } };
  const snapshot = { now, samples: [sample], today: null, partial: true };
  const timeline = todayTimeline(snapshot);
  assert.ok(timeline.liveOnly);
  assert.equal(timeline.buckets.reduce((sum, bucket) => sum + bucket.tokens, 0), 160);
  assert.equal(timeline.buckets.at(-1).coverage, "partial");
  assert.ok(timeline.buckets.at(-1).current);
  assert.ok(todayTimeline(snapshot, "vscodeLocal").buckets.every(bucket => bucket.coverage === "unavailable"));
  assert.ok(timeline.buckets.slice(0, -1).every(bucket => bucket.coverage === "unavailable"));
});
test("reporting hours preserve DST gaps, repeats and non-hour zones", () => {
  for (const [zone, day, count, duration] of [
    ["America/New_York", "2026-03-08", 23, 23],
    ["America/New_York", "2026-11-01", 25, 25],
    ["Australia/Lord_Howe", "2026-10-04", 24, 23.5],
    ["Australia/Lord_Howe", "2026-04-05", 25, 24.5],
    ["Asia/Kathmandu", "2026-09-30", 24, 24],
  ]) {
    const calendar = reportingDay(day, zone);
    assert.equal(calendar.hours.length, count, `${zone} ${day}`);
    assert.equal((calendar.end - calendar.start) / 3600000, duration);
    assert.equal(new Set(calendar.hours.map(hour => hour.start)).size, count);
    assert.ok(calendar.hours.every((hour, i) => i === 0 || calendar.hours[i - 1].end === hour.start));
  }
});
test("accessible charts include exact zero-based values, coverage, current marker and clock preference", () => {
  const history = historyFixture();
  const buckets = historyTimeline(history, history.calendar[0].start + 3600000, "all", true);
  const markup = chartMarkup(buckets, "UTC", "24", true);
  assert.match(markup, /data-max="30"/);
  assert.match(markup, /data-coverage="recorded" data-tokens="30"/);
  assert.match(markup, /30 observed tokens; 2 calls; Recorded coverage; 3,600 recording seconds/);
  assert.match(markup, /Unavailable observations; current unfinished bucket/);
  assert.match(markup, /data-current="true"/);
  assert.match(chartMarkup(buckets, "UTC", "12", true), /AM/);
  assert.doesNotMatch(markup, /AM/);
  const zero = chartMarkup([{ ...buckets[0], tokens: 0, calls: 0 }], "UTC");
  assert.match(zero, /data-max="3"/);
  assert.match(zero, /data-tokens="0"/);
  assert.match(zero, /mark-recorded/);
  assert.match(zero, /0 observed tokens; 0 calls; Recorded coverage/);
  const card = chartMarkup(buckets, "UTC", "24", true, null, "card");
  assert.match(card, /data-max="30"/);
  assert.doesNotMatch(card, /chart-grid|token-legend/);
});

test("seven-day charts retain missing dates and use the reporting zone at midnight", () => {
  const history = historyFixture();
  history.calendar = Array.from({ length: 7 }, (_, index) => reportingDay(`2026-09-${24 + index}`, "America/New_York"));
  history.timeZone = "America/New_York";
  history.coverage = [];
  const now = Date.parse("2026-10-01T03:59:59Z");
  const buckets = historyTimeline(history, now);
  assert.equal(buckets.length, 7);
  assert.equal(buckets.at(-1).day, "2026-09-30");
  assert.ok(buckets.at(-1).current);
  assert.ok(buckets.slice(0, -1).every(bucket => bucket.coverage === "unavailable"));
  assert.equal(buckets.at(-1).tokens, 30);
});
