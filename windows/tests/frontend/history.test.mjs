import test from "node:test";
import assert from "node:assert/strict";
import { addDays, dayCount, periodInterval, priorInterval, completedComparison, elapsedDays, periodTitle, shortPeriod,
  formatChange, percentage, latency, recordedDuration, modelTitle, insightHeadline, orderedInsights } from "../../desktop/src/history.js";

const today = "2026-10-01";
test("periods match macOS HistoryCalendar, including month and leap boundaries", () => {
  assert.deepEqual(periodInterval("today", today, today), { start: "2026-10-01", end: "2026-10-02" });
  assert.deepEqual(periodInterval("week", today, today), { start: "2026-09-25", end: "2026-10-02" });
  assert.deepEqual(periodInterval("days30", today, today), { start: "2026-09-02", end: "2026-10-02" });
  assert.deepEqual(periodInterval("month", today, today), { start: "2026-10-01", end: "2026-11-01" });
  assert.deepEqual(periodInterval("previousMonth", today, "2026-03-31"), { start: "2026-02-01", end: "2026-03-01" });
  assert.deepEqual(periodInterval("day", "2024-02-29", today), { start: "2024-02-29", end: "2024-03-01" });
  assert.deepEqual(periodInterval("chosenMonth", "2026-12-15", today), { start: "2026-12-01", end: "2027-01-01" });
  assert.equal(dayCount(periodInterval("days30", today, today)), 30);
  assert.equal(addDays("2026-12-31", 1), "2027-01-01");
  assert.throws(() => periodInterval("week", today, "2026-02-30"));
});

test("prior periods use the comparison date for chosen periods and previous months for monthly ranges", () => {
  const week = periodInterval("week", today, today);
  assert.deepEqual(priorInterval("week", week, null, today), { start: "2026-09-18", end: "2026-09-25" });
  assert.deepEqual(priorInterval("month", periodInterval("month", today, today), null, today), { start: "2026-09-01", end: "2026-10-01" });
  assert.deepEqual(priorInterval("day", periodInterval("day", "2026-09-10", today), "2026-08-05", today), { start: "2026-08-05", end: "2026-08-06" });
});

test("comparisons trim an unfinished period to completed days on both sides", () => {
  const week = periodInterval("week", today, today);
  assert.deepEqual(completedComparison(week, priorInterval("week", week, null, today), today),
    [{ start: "2026-09-25", end: "2026-10-01" }, { start: "2026-09-19", end: "2026-09-25" }]);
  const month = periodInterval("month", "2026-10-15", "2026-10-15");
  assert.deepEqual(completedComparison(month, priorInterval("month", month, null, "2026-10-15"), "2026-10-15", true),
    [{ start: "2026-10-01", end: "2026-10-15" }, { start: "2026-09-01", end: "2026-09-15" }]);
  const first = periodInterval("month", today, today);
  assert.deepEqual(completedComparison(first, priorInterval("month", first, null, today), today, true),
    [{ start: today, end: today }, { start: "2026-09-01", end: "2026-09-01" }]);
  const todayOnly = periodInterval("today", today, today);
  const prior = priorInterval("today", todayOnly, null, today);
  assert.deepEqual(completedComparison(todayOnly, prior, today), [todayOnly, prior]);
  assert.equal(elapsedDays(periodInterval("month", today, today), today), 1);
});

test("labels and formats follow macOS MetricFormat", () => {
  assert.match(periodTitle({ start: today, end: "2026-10-02" }), /October/);
  assert.match(periodTitle({ start: "2026-09-25", end: "2026-10-02" }), /Sep 25 \u2013 Oct 1, 2026/);
  assert.equal(shortPeriod({ start: today, end: today }), "\u2014");
  assert.equal(formatChange(percentage(110, 100)), "+10.0%");
  assert.equal(formatChange(percentage(90, 100)), "-10.0%");
  assert.equal(formatChange(percentage(1, 0)), "\u2014");
  assert.equal(latency(850), "850 ms");
  assert.equal(latency(1500), "1.5 s");
  assert.equal(latency(12500), "13 s");
  assert.equal(latency(null), "\u2014");
  assert.equal(recordedDuration(5400), "1 h 30 min");
  assert.equal(recordedDuration(59), "0 min");
  assert.equal(modelTitle(""), "Model unavailable");
  assert.equal(modelTitle("Other models (capacity limit)"), "Other models (detail limit)");
});

test("insight headlines and order match macOS", () => {
  const items = [
    { label: "First-token latency", available: true, previous: 100, current: 120 },
    { label: "Call duration", available: false, previous: null, current: null },
    { label: "Model mix", available: true, changes: [{ model: "a", previous: 50, current: 40 }, { model: "b", previous: 20, current: 45 }] },
    { label: "Compaction frequency", available: true, previous: 3, current: 1 },
  ];
  assert.deepEqual(orderedInsights(items).map(insightHeadline), [
    "Observed b call share increased", "Observed first-token latency increased",
    "Call duration: comparison unavailable", "Observed compaction frequency decreased"]);
});
