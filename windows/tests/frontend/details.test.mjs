import test from "node:test";
import assert from "node:assert/strict";
import { captureUsage, captureInsight, captureTimeline, detailMarkup } from "../../desktop/src/details.js";
import { emptyUsage, reportingDay, modelGroups } from "../../desktop/src/usage.js";
import { insights, shiftedDay } from "../../desktop/src/insights.js";

function fixture() {
  const calendar = reportingDay("2026-09-30","UTC");
  const usage = calls => ({ ...emptyUsage(),input:calls * 10,calls });
  const days = [
    { day:calendar.day,source:"cli",model:"named",usage:usage(2) },
    { day:calendar.day,source:"cli",model:null,usage:usage(1) },
    { day:calendar.day,source:"cli",model:"Other models (capacity limit)",usage:usage(1) },
    { day:calendar.day,source:"vscodeLocal",model:"editor",usage:usage(8) },
  ];
  return { capturedAt:calendar.start + 7200000,generation:"history-generation",timeZone:"UTC",calendar:[calendar],
    startedAt:calendar.start,coverageBegan:calendar.start,coverage:[],hourlyCoverage:[],gaps:[],sourceGaps:[],compactions:[],
    days,totals:[{day:calendar.day,source:"cli",usage:usage(4)},{day:calendar.day,source:"vscodeLocal",usage:usage(8)}],
    hours:[{hour:"2026-09-30T00:00:00+00:00",source:"cli",usage:usage(1)}],truncated:false };
}
const snapshot = { now:Date.parse("2026-09-30T12:00:00Z"),samples:[],archives:{ live:"live-generation" } };
const format = ms => new Date(ms).toISOString();

test("captured model evidence freezes exact source totals and keeps unknown/overflow denominators", () => {
  const history = fixture();
  const captured = captureUsage({ snapshot,history,source:"cli",model:"named" });
  assert.equal(captured.data.usage.calls,2);
  assert.equal(captured.data.denominator.calls,4);
  assert.equal(captured.data.models.length,1);
  history.days[0].usage.calls = 99;
  history.totals[0].usage.calls = 200;
  assert.equal(captured.data.usage.calls,2);
  assert.equal(captured.data.denominator.calls,4);
  assert.match(detailMarkup(captured,format),/Selected call share: 50%/);
  assert.equal(captureUsage({ snapshot,history:fixture(),source:"cli",model:"" }).data.usage.calls,1);
});

test("an hourly chart opens only that hour and does not substitute daily model detail", () => {
  const history = fixture();
  const captured = captureUsage({ snapshot,history,source:"cli",bucket:history.calendar[0].hours[0],hourly:true });
  assert.equal(captured.data.usage.calls,1);
  assert.deepEqual(captured.data.models,[]);
  assert.ok(captured.data.hourlyModelsUnavailable);
  assert.match(detailMarkup(captured,format),/Daily model totals are not substituted/);
});

test("large and missing model selections never renormalize partial displayed rows", () => {
  const history = fixture();
  history.truncated = true;
  history.totals[0].usage.calls = 50000;
  const all = captureUsage({ snapshot,history,source:"cli" });
  assert.equal(all.data.usage.calls,50000);
  assert.match(detailMarkup(all,format),/Unavailable \(limited model detail\)/);
  const missing = captureUsage({ snapshot,history,source:"cli",model:"missing" });
  assert.equal(missing.data.usage.calls,0);
  assert.equal(missing.data.denominator.calls,50000);
  assert.match(detailMarkup(missing,format),/Missing or overflow attribution is not proof/);
});

test("live-only capture remains fixed after later samples, source changes and cap warnings", () => {
  const live = { ...snapshot,partial:true,samples:[{date:snapshot.now,source:"cli",tokens:{input:30,output:2,cacheInput:0,cacheWrite:0,model:"live"}}] };
  const captured = captureUsage({ snapshot:live,source:"cli",model:"live" });
  live.samples[0].tokens.input = 900;
  live.samples.push({date:snapshot.now,source:"vscodeLocal",tokens:{input:900}});
  assert.equal(captured.kind,"live");
  assert.equal(captured.archiveId,"live-generation");
  assert.equal(captured.data.usage.input,30);
  assert.match(detailMarkup(captured,format),/Live sample capacity was reached/);
});

test("unreported models do not share selection keys with a literal model label", () => {
  const groups = modelGroups([{ model:null,usage:emptyUsage() },{ model:"Model not reported",usage:emptyUsage() }]);
  assert.equal(groups.length,2);
  assert.notEqual(groups[0].model,groups[1].model);
});

test("insight evidence captures matched periods, independent sample fields, compactions and gaps", () => {
  const history = fixture();
  history.calendar = Array.from({length:14},(_,i) => {
    const day = shiftedDay("2026-09-30",i - 14);
    return {day,start:Date.parse(`${day}T00:00:00Z`),end:Date.parse(`${day}T00:00:00Z`) + 86400000,hours:[]};
  });
  history.days = history.calendar.flatMap(day => [
    {day:day.day,source:"cli",model:"named",usage:{...emptyUsage(),calls:3,durationSamples:1,durationMs:10,firstTokenSamples:3,firstTokenMs:9}},
    {day:day.day,source:"cli",model:null,usage:{...emptyUsage(),calls:1,durationSamples:0,firstTokenSamples:1,firstTokenMs:3}},
  ]);
  history.totals = history.days;
  history.compactions = [["2026-09-18",2,1],["2026-09-28",1,2]];
  history.sourceGaps = [{source:"cli",start:Date.parse("2026-09-18T01:00:00Z"),end:Date.parse("2026-09-18T01:05:00Z")}];
  const report = insights(history,"2026-09-30","cli");
  const latency = captureInsight(history,report,report.items[0]);
  const mix = captureInsight(history,report,report.items[2]);
  assert.equal(latency.data.evidence.periods[0].usage.firstTokenSamples,28);
  assert.equal(latency.data.evidence.periods[0].usage.durationSamples,7);
  assert.equal(latency.data.evidence.periods[0].successes,2);
  assert.equal(latency.data.evidence.periods[1].failures,2);
  assert.equal(latency.data.evidence.gapIntervals.length,1);
  assert.equal(mix.data.item.changes.find(change => change.model === "named").previous,75);
  history.days.length = 0;
  report.evidence.periods[0].usage.calls = 999;
  assert.equal(latency.data.evidence.periods[0].usage.calls,28);
  assert.match(detailMarkup(latency,format),/Independent field coverage: 28 \/ 28/);
  assert.match(detailMarkup(mix,format),/Model not reported/);
});

test("complete retained timelines paginate captured events and expose reporting and compaction fields", () => {
  const now = snapshot.now;
  const timeline = {status:{generation:"timeline-generation",capturedAt:now,retentionDays:7,cutoff:now-604800000,pruned:true,interrupted:true,legacy:true},
    session:"a".repeat(64),truncated:true,events:Array.from({length:101},(_,i) => ({timestamp:now+i,source:"cli",event:{
      kind:"usage",tokens:{input:1,output:0,cacheInput:0,cacheWrite:0,cacheInputReported:false,cacheWriteReported:true,durationMs:7},
      compaction:{success:false,before:100,after:80}}}))};
  const captured = captureTimeline(timeline);
  timeline.events.pop();
  const last = detailMarkup(captured,format,1);
  assert.match(last,/Showing 101-101 of 101/);
  assert.match(last,/Failed completion/);
  assert.match(last,/Cache read<\/dt><dd>Not reported/);
  assert.match(last,/Mean first token<\/dt><dd>Not reported/);
  assert.match(last,/Earlier recording interruptions were not tracked/);
  assert.match(last,/Some events from this session were removed/);
});
