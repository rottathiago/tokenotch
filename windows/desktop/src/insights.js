import { dayKey, merge, modelGroups, historyTimeline } from "./usage.js";

export function shiftedDay(day, offset) {
  const value = new Date(`${day}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + offset);
  return value.toISOString().slice(0, 10);
}

export function insights(history, today, source = "all") {
  const first = shiftedDay(today, -14);
  const middle = shiftedDay(today, -7);
  const last = shiftedDay(today, -1);
  const rows = history.days.filter(row => row.day >= first && row.day < today &&
    (source === "all" || row.source === source));
  const periods = [rows.filter(row => row.day < middle), rows.filter(row => row.day >= middle)];
  const totals = (history.totals ?? history.days).filter(row => row.day >= first && row.day < today &&
    (source === "all" || row.source === source));
  const usage = [totals.filter(row => row.day < middle), totals.filter(row => row.day >= middle)].map(rows => merge(rows.map(row => row.usage)));
  const observedDays = new Set(rows.filter(row => row.usage.calls > 0).map(row => row.day));
  const gaps = history.gaps.filter(([start, end]) => dayKey(start, history.timeZone) <= last && dayKey(end, history.timeZone) >= first);
  const buckets = historyTimeline(history, Date.parse(`${today}T23:59:59Z`), source)
    .filter(bucket => bucket.day >= first && bucket.day < today);
  const complete = observedDays.size === 14 && typeof history.startedAt === "number" &&
    buckets.length === 14 && buckets.every(bucket => bucket.coverage === "recorded") && gaps.length === 0 && !history.truncated;
  const missing = "Directional comparison unavailable: requires observations and recorded coverage on all 14 completed days, with no known gaps. This is not billing or a productivity measure.";
  const evidence = { first, middle, last, source, timeZone: history.timeZone, observedDays: observedDays.size,
    gaps: buckets.filter(bucket => bucket.gap).length, buckets, previous: usage[0], current: usage[1],
    periods: periods.map((rows,index) => ({ first: index ? middle : first, last: index ? last : shiftedDay(middle,-1),
      usage: usage[index], models: modelGroups(rows), successes: 0, failures: 0 })),
    gapIntervals: [...history.gaps.map(([start,end]) => ({start,end})), ...(history.sourceGaps ?? []).filter(gap => gap.source === source)]
      .filter(gap => dayKey(gap.start,history.timeZone) <= last && dayKey(gap.end,history.timeZone) >= first) };
  const result = [];
  for (const [label, sum, samples] of [["First-token latency", "firstTokenMs", "firstTokenSamples"], ["Call duration", "durationMs", "durationSamples"]]) {
    const eligible = complete && usage.every(v => v[samples] >= 20 && v[samples] / v.calls >= 0.8);
    result.push({ label, samples, unit: "ms", available: eligible, previous: usage[0][samples] ? usage[0][sum] / usage[0][samples] : null,
      current: usage[1][samples] ? usage[1][sum] / usage[1][samples] : null,
      detail: eligible ? "Sample-weighted means in milliseconds. Model mix can change latency; this is not a causal diagnosis." :
        `${missing} Also requires 20 samples and 80% field coverage per week.` });
  }
  const mixes = periods.map(rows => new Map(modelGroups(rows).map(group => [group.model,group.usage])));
  const models = new Set([...mixes[0].keys(), ...mixes[1].keys()]);
  const changes = [...models].map(model => ({ model, label: model || "Model not reported",
    previousCalls: mixes[0].get(model)?.calls ?? 0, currentCalls: mixes[1].get(model)?.calls ?? 0,
    previous: usage[0].calls ? (mixes[0].get(model)?.calls ?? 0) / usage[0].calls * 100 : null,
    current: usage[1].calls ? (mixes[1].get(model)?.calls ?? 0) / usage[1].calls * 100 : null }));
  result.push({ label: "Model mix", available: complete && usage.every(v => v.calls >= 20), changes,
    detail: complete && usage.every(v => v.calls >= 20) ? "Share of observed calls, including unavailable models in the denominator." : `${missing} Also requires 20 calls per week.` });
  const compactions = [0, 0];
  for (const [day, success, failed] of history.compactions ?? []) {
    if (day >= first && day < today && (source === "all" || source === "cli")) {
      const index = Number(day >= middle);
      compactions[index] += success + failed;
      evidence.periods[index].successes += success;
      evidence.periods[index].failures += failed;
    }
  }
  const eligible = complete && (source === "all" || source === "cli") && compactions.every(v => v > 0) && usage.every(v => v.calls > 0);
  result.push({ label: "Compaction frequency", unit: "completions per 100 calls", available: eligible,
    previous: eligible ? compactions[0] / usage[0].calls * 100 : null,
    current: eligible ? compactions[1] / usage[1].calls * 100 : null,
    detail: eligible ? "Completed compactions per 100 observed calls. Starts are excluded; compactions are not attributed to models." :
      `${missing} Both weeks must report completed compactions and calls; no reports do not prove zero.` });
  return { evidence, items: result };
}
