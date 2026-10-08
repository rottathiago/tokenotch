import test from "node:test";
import assert from "node:assert/strict";
import { insights, shiftedDay } from "../../desktop/src/insights.js";
import { emptyUsage } from "../../desktop/src/usage.js";

function fixture() {
  return { startedAt: Date.parse("2026-08-01T00:00:00Z"), coverageBegan: Date.parse("2026-08-01T00:00:00Z"),
    timeZone: "UTC", gaps: [], sourceGaps: [], compactions: [], hours: [],
    calendar: Array.from({ length: 14 }, (_, i) => {
      const day = shiftedDay("2026-09-30", i - 14);
      const start = Date.parse(`${day}T00:00:00Z`);
      return { day, start, end: start + 86400000, hours: [] };
    }),
    coverage: Array.from({ length: 14 }, (_, i) => ({ bucket: shiftedDay("2026-09-30", i - 14), source: "all", recordingSeconds: 86400 })),
    days: Array.from({ length: 14 }, (_, i) => ({ day: shiftedDay("2026-09-30", i - 14), source: "cli", model: "fixture",
      usage: { ...emptyUsage(), calls: 4, durationSamples: 4, durationMs: 400, firstTokenSamples: 4, firstTokenMs: 40 } })) };
}
test("insights require complete matched days and sampled coverage", () => {
  const history = fixture();
  assert.ok(insights(history, "2026-09-30").items[0].available);
  history.gaps.push([Date.parse("2026-09-20T10:00:00Z"), Date.parse("2026-09-20T11:00:00Z")]);
  assert.ok(insights(history, "2026-09-30").items.every(item => !item.available));
});
test("calls alone and another source's coverage cannot establish complete insight evidence", () => {
  const history = fixture();
  assert.ok(insights(history, "2026-09-30", "cli").items.every(item => !item.available));
  history.coverage = [];
  assert.ok(insights(history, "2026-09-30").items.every(item => !item.available));
});
test("today and unobserved compactions never manufacture a comparison", () => {
  const history = fixture();
  history.days[0].day = "2026-09-30";
  const report = insights(history, "2026-09-30");
  assert.equal(report.evidence.observedDays, 13);
  assert.equal(report.items.at(-1).available, false);
});
