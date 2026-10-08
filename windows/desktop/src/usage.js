export function escape(value) {
  return String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
export const sourceName = source => ({ cli: "Copilot CLI", vscode: "VS Code Local activity",
  vscodeLocal: "VS Code Local", vscodeCopilot: "VS Code Agent Host" })[source] ?? "Unavailable source";
export function count(value) { return value === null || value === undefined ? "Not reported" : new Intl.NumberFormat().format(value); }
export function total(usage) {
  return usage.input + usage.output + usage.cacheInput + usage.cacheWrite;
}
export function emptyUsage() {
  return { input: 0, output: 0, cacheInput: 0, cacheWrite: 0, calls: 0,
    cacheReportedCalls: 0, cacheUnreportedCalls: 0, writeReportedCalls: 0, writeUnreportedCalls: 0,
    durationMs: 0, durationSamples: 0, firstTokenMs: 0, firstTokenSamples: 0 };
}
export function merge(values) {
  const result = emptyUsage();
  for (const usage of values) for (const field of Object.keys(result)) result[field] += usage[field] ?? 0;
  return result;
}
export function fromTokens(tokens) {
  return { ...emptyUsage(), input: tokens.input, output: tokens.output, cacheInput: tokens.cacheInput,
    cacheWrite: tokens.cacheWrite, calls: 1,
    cacheReportedCalls: Number(tokens.cacheInputReported === true),
    cacheUnreportedCalls: Number(tokens.cacheInputReported === false),
    writeReportedCalls: Number(tokens.cacheWriteReported === true),
    writeUnreportedCalls: Number(tokens.cacheWriteReported === false),
    durationMs: tokens.durationMs ?? 0, durationSamples: Number(typeof tokens.durationMs === "number"),
    firstTokenMs: tokens.timeToFirstTokenMs ?? 0, firstTokenSamples: Number(typeof tokens.timeToFirstTokenMs === "number") };
}
export function cache(usage, write = false) {
  if (!usage || !usage.calls) return "Not reported";
  const known = usage[write ? "writeReportedCalls" : "cacheReportedCalls"];
  const absent = usage[write ? "writeUnreportedCalls" : "cacheUnreportedCalls"];
  const tokens = usage[write ? "cacheWrite" : "cacheInput"];
  if (known === usage.calls) return count(tokens);
  if (absent === usage.calls) return "Not reported";
  if (known === 0 && absent === 0 && tokens === 0) return "Unknown";
  return `${count(tokens)} *`;
}
export function dayKey(ms, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", { year: "numeric", month: "2-digit", day: "2-digit",
    ...(timeZone ? { timeZone } : {}) }).formatToParts(ms);
  return ["year", "month", "day"].map(type => parts.find(p => p.type === type).value).join("-");
}
export function todayRows(snapshot, source = "all") {
  const saved = typeof snapshot.today?.startedAt === "number";
  const rows = saved ? snapshot.today.days : snapshot.samples
    .filter(sample => dayKey(sample.date) === dayKey(snapshot.now))
    .map(sample => ({ day: dayKey(sample.date), source: sample.source, model: sample.tokens.model, usage: fromTokens(sample.tokens) }));
  return rows.filter(row => source === "all" || row.source === source);
}
export function cliReportingGap(snapshot) {
  const reported = new Set(snapshot.samples.filter(sample => sample.source === "cli").map(sample => sample.session));
  const missing = snapshot.sessions.filter(session => session.source === "cli" && !reported.has(session.id)).length;
  return missing ? `${count(missing)} observed CLI ${missing === 1 ? "session has" : "sessions have"} no retained token/model reports yet. Check the Tokenotch extension in each session; totals cover received calls only.` : "";
}
export const tokenAccountingNote = "Models are reported per API call, not inferred from the selected session model. Input excludes separately reported cache read/write tokens.";
export function modelRows(rows) {
  return modelGroups(rows).map(group => [group.label,group.usage]);
}
export function modelGroups(rows) {
  const groups = new Map();
  for (const row of rows) {
    const key = row.model ?? "";
    groups.set(key, merge([groups.get(key) ?? emptyUsage(), row.usage]));
  }
  return [...groups].map(([model, usage]) => ({ model, label: model || "Model not reported", usage }))
    .sort((a, b) => total(b.usage) - total(a.usage) || a.model.localeCompare(b.model));
}
export function contextDescription(reading, now) {
  if (!reading?.context) return "Context: Not reported";
  const { currentTokens, tokenLimit } = reading.context;
  return `Context: ${(currentTokens / tokenLimit * 100).toFixed(1)}% (${count(currentTokens)} / ${count(tokenLimit)})${now - reading.observedAtUnixMs > 300000 ? " - stale" : ""}`;
}

const liveCalendars = new Map();
export function reportingDay(day, timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone) {
  const key = `${timeZone}:${day}`;
  if (liveCalendars.has(key)) return liveCalendars.get(key);
  const formatter = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  const anchor = Date.parse(`${day}T00:00:00Z`);
  const boundaries = [];
  let previous;
  let end;
  // UTC iteration preserves repeated, missing and half-hour reporting hours.
  for (let at = anchor - 15 * 3600000; at <= anchor + 39 * 3600000; at += 60000) {
    const parts = Object.fromEntries(formatter.formatToParts(at).map(part => [part.type, part.value]));
    const localDay = `${parts.year}-${parts.month}-${parts.day}`;
    if (localDay === day) {
      const local = Date.parse(`${localDay}T${parts.hour}:${parts.minute}:00Z`);
      const offset = local - at;
      if (previous === undefined || parts.minute === "00" || offset !== previous) boundaries.push(at);
      previous = offset;
    } else if (previous !== undefined) { end = at; break; }
  }
  if (end === undefined) throw new Error("The reporting day could not be resolved.");
  const result = { day, start: boundaries[0], end, hours: boundaries.map((start, index) => ({ start, end: boundaries[index + 1] ?? end })) };
  if (liveCalendars.size >= 14) liveCalendars.clear();
  liveCalendars.set(key, result);
  return result;
}

export function bucketCoverage(bucket, now) {
  if (bucket.start > now) return "future";
  if (!bucket.calls && !bucket.recordingSeconds) return "unavailable";
  const elapsed = Math.max(0, Math.min(now, bucket.end) - bucket.start) / 1000;
  return !bucket.gap && !bucket.legacy && elapsed > 0 && bucket.recordingSeconds >= elapsed - 0.01 ? "recorded" : "partial";
}

export function historyTimeline(history, now, source = "all", hourly = false) {
  const coverage = hourly ? history.hourlyCoverage ?? [] : history.coverage ?? [];
  const values = new Map();
  for (const row of hourly ? history.hours : typeof history.modelFilter === "string" ? history.days : history.totals ?? history.days) {
    if (source !== "all" && row.source !== source) continue;
    const key = hourly ? Date.parse(row.hour) : row.day;
    values.set(key, merge([values.get(key) ?? emptyUsage(), row.usage]));
  }
  const durations = new Map(coverage.filter(row => row.source === source)
    .map(row => [hourly ? Date.parse(row.bucket) : row.bucket, row.recordingSeconds]));
  const gaps = [...(history.sourceGaps ?? []).filter(gap => gap.source === source),
    ...(history.gaps ?? []).map(([start, end]) => ({ start, end }))];
  const intervals = hourly ? history.calendar.flatMap(day => day.hours) : history.calendar;
  return intervals.filter(interval => interval.start <= now).map(interval => {
    const key = hourly ? interval.start : interval.day;
    const usage = values.get(key) ?? emptyUsage();
    const bucket = { ...interval, usage, tokens: total(usage), calls: usage.calls, recordingSeconds: durations.get(key) ?? 0,
      gap: gaps.some(gap => gap.start < interval.end && (gap.end > interval.start || gap.start === gap.end && gap.end === interval.start)),
      legacy: history.truncated || typeof history.coverageBegan !== "number" || interval.start < history.coverageBegan };
    return { ...bucket, coverage: bucketCoverage(bucket, now), current: interval.start <= now && now < interval.end };
  });
}

export function todayTimeline(snapshot, source = "all") {
  if (typeof snapshot.today?.startedAt === "number") {
    return { buckets: historyTimeline(snapshot.today, snapshot.now, source, true), timeZone: snapshot.today.timeZone, liveOnly: false };
  }
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const calendar = reportingDay(dayKey(snapshot.now, timeZone), timeZone);
  const samples = snapshot.samples.filter(sample => source === "all" || source === sample.source);
  const buckets = calendar.hours.filter(interval => interval.start <= snapshot.now).map(interval => {
    const usage = merge(samples.filter(sample => sample.date >= interval.start && sample.date < interval.end).map(sample => fromTokens(sample.tokens)));
    return { ...interval, usage, tokens: total(usage), calls: usage.calls, recordingSeconds: 0, gap: true,
      coverage: usage.calls ? "partial" : "unavailable", current: snapshot.now < interval.end };
  });
  return { buckets, timeZone, liveOnly: true };
}

const categories = [["input", "Input"], ["output", "Output"], ["cacheInput", "Cache read"], ["cacheWrite", "Cache write"]];
export function compact(value) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "-";
  if (Math.abs(value) >= 1e15) return value.toExponential(1).replace("e+", "E");
  return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
}
// A ceiling divisible into three readable gridline steps (e.g. 20M, 40M, 60M).
export function niceCeiling(value) {
  if (!(value > 0)) return 3;
  const step = value / 3;
  const power = 10 ** Math.floor(Math.log10(step));
  return 3 * power * ([1, 2, 2.5, 5, 10].find(factor => factor * power >= step) ?? 10);
}
function intervalLabel(bucket, timeZone, timeFormat, hourly) {
  if (!hourly) return bucket.day;
  return new Intl.DateTimeFormat(undefined, { timeZone, hour: "numeric", minute: "2-digit",
    hour12: timeFormat === "12", timeZoneName: "shortOffset" }).format(bucket.start);
}
export function bucketDescription(bucket, timeZone, timeFormat = "24", hourly = false) {
  if (bucket.coverage === "future") return `${intervalLabel(bucket, timeZone, timeFormat, hourly)}: Not reached yet`;
  const status = bucket.coverage === "unavailable" ? "Unavailable observations" :
    bucket.coverage === "recorded" ? "Recorded coverage" : "Partial coverage";
  const value = bucket.coverage === "unavailable" ? status :
    `${count(bucket.tokens)} observed tokens; ${count(bucket.calls)} calls; ${status}; ${count(bucket.recordingSeconds)} recording seconds`;
  return `${intervalLabel(bucket, timeZone, timeFormat, hourly)}: ${value}${bucket.current ? "; current unfinished bucket" : ""}`;
}
// Sparse axis labels: weekdays for a week, every seventh date for longer
// periods, and six-hour marks (plus the current hour) for a single day.
export function tickLabel(bucket, index, buckets, timeZone, timeFormat = "24", hourly = false) {
  if (!hourly) {
    const date = new Date(`${bucket.day}T12:00:00Z`);
    if (Number.isNaN(date.getTime())) return "";
    if (buckets.length <= 7) return new Intl.DateTimeFormat(undefined, { weekday: "short", timeZone: "UTC" }).format(date);
    return (buckets.length - 1 - index) % 7 === 0 ? new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", timeZone: "UTC" }).format(date) : "";
  }
  const hour = Number(new Intl.DateTimeFormat("en-US", { timeZone, hour: "numeric", hourCycle: "h23" }).format(bucket.start));
  if (hour % 6 !== 0 && !bucket.current) return "";
  if (timeFormat === "12" && !bucket.current && buckets.length > 12) {
    const current = buckets.findIndex(item => item.current);
    if (current >= 0 && current - index < 3 && current - index > 0) return "";
  }
  return new Intl.DateTimeFormat(undefined, { timeZone, hour: "numeric", hour12: timeFormat === "12" }).format(bucket.start);
}
function barSvg(bucket, max, stacked) {
  const height = Math.max(1, bucket.tokens / max * 100);
  const parts = stacked && bucket.usage && bucket.tokens > 0 ?
    categories.map(([key]) => [key, (bucket.usage[key] ?? 0) / bucket.tokens * height]).filter(([, value]) => value > 0) :
    [["total", height]];
  let y = 100;
  return `<svg class="bar" viewBox="0 0 18 100" preserveAspectRatio="none" aria-hidden="true" focusable="false">${parts.map(([key, value]) => {
    y -= value;
    return `<rect class="segment-${key}" x="0" y="${y.toFixed(3)}" width="18" height="${value.toFixed(3)}"/>`;
  }).join("")}</svg>`;
}
export function legendMarkup(usage = null, describe = null) {
  return `<ul class="token-legend">${categories.map(([key, label]) =>
    `<li><span class="dot dot-${key}" aria-hidden="true"></span>${escape(label)}${usage ? ` <strong>${escape(describe ? describe(key) : compact(usage[key]))}</strong>` : ""}</li>`).join("")}</ul>`;
}

// Vertical bars on a zero baseline. Every bucket carries its exact value and
// coverage as data and accessible text; heights are relative to `data-max`.
// Bars are SVG attributes because the application CSP forbids inline styles.
// `emptyMarks: false` leaves days without calls blank, as the macOS History chart does.
export function chartMarkup(buckets, timeZone, timeFormat = "24", hourly = false, link = null, variant = "settings", options = {}) {
  const peak = Math.max(0, ...buckets.map(bucket => bucket.tokens));
  const max = variant === "card" ? Math.max(1, peak) : niceCeiling(peak);
  const stacked = variant !== "card";
  const grid = stacked ? `<div class="chart-grid" aria-hidden="true">${[3, 2, 1, 0].map(step => `<span>${escape(step ? compact(max * step / 3) : "0")}</span>`).join("")}</div>` : "";
  return `<div class="chart chart-${variant}${hourly ? " chart-hourly" : ""}" role="group" data-max="${max}" aria-label="${hourly ? "Hourly" : "Daily"} observed tokens; scale starts at zero">${grid}<div class="chart-bars">${buckets.map((bucket, index) => {
    const description = bucketDescription(bucket, timeZone, timeFormat, hourly);
    const mark = bucket.tokens > 0 ? barSvg(bucket, max, stacked) : options.emptyMarks === false ? "" : `<span class="empty-mark mark-${bucket.coverage}" aria-hidden="true"></span>`;
    const tick = `<span class="bucket-tick" aria-hidden="true">${escape(tickLabel(bucket, index, buckets, timeZone, timeFormat, hourly)) || "&nbsp;"}</span>`;
    const inner = `<span class="bucket-plot">${mark}</span>${tick}`;
    const target = link ? link(bucket) : null;
    return `<div class="bucket" data-coverage="${bucket.coverage}" data-tokens="${bucket.tokens}"${bucket.current ? ' data-current="true"' : ""}>${target ?
      `<button type="button" class="bucket-hit" data-detail="${escape(target)}" data-focus-key="${escape(target)}" title="${escape(description)}" aria-label="Open details for ${escape(description)}">${inner}</button>` :
      `<span class="bucket-hit" role="img" title="${escape(description)}" aria-label="${escape(description)}">${inner}</span>`}<span class="bucket-current" aria-hidden="true"></span></div>`;
  }).join("")}</div>${stacked ? legendMarkup() : ""}</div>`;
}
