import { escape as e, sourceName, count, total, merge, cache, fromTokens, modelGroups, historyTimeline, dayKey } from "./usage.js";

const matchesSource = (row, source) => source === "all" || row.source === source;
const matchesModel = (row, model) => model === null || (row.model ?? "") === model;
export const share = (part, denominator) => denominator ? `${count(part / denominator * 100)}%` : "Not available";

export function captureUsage({ snapshot, history = null, source = "all", model = null, bucket = null, hourly = false }) {
  const zone = history?.timeZone ?? Intl.DateTimeFormat().resolvedOptions().timeZone;
  const now = history?.capturedAt ?? snapshot.now;
  const first = bucket ? dayKey(bucket.start, zone) : history?.calendar[0]?.day ?? dayKey(snapshot.now, zone);
  const last = bucket ? dayKey(bucket.end - 1, zone) : history?.calendar.at(-1)?.day ?? first;
  let rows;
  let denominator;
  let buckets;
  if (history) {
    const selected = (hourly ? history.hours : history.days).filter(row => matchesSource(row, source) &&
      (hourly ? Date.parse(row.hour) >= bucket.start && Date.parse(row.hour) < bucket.end : row.day >= first && row.day <= last));
    denominator = merge((hourly ? selected : (history.totals ?? history.days).filter(row =>
      matchesSource(row, source) && row.day >= first && row.day <= last)).map(row => row.usage));
    rows = hourly ? [] : selected.filter(row => matchesModel(row, model));
    buckets = historyTimeline(history, now, source, hourly).filter(value => bucket ?
      value.start === bucket.start : value.day >= first && value.day <= last);
  } else {
    const selected = snapshot.samples.filter(sample => matchesSource(sample, source) && (bucket ?
      sample.date >= bucket.start && sample.date < bucket.end : dayKey(sample.date, zone) === first))
      .map(sample => ({ model: sample.tokens.model ?? null, usage: fromTokens(sample.tokens) }));
    denominator = merge(selected.map(row => row.usage));
    rows = selected.filter(row => matchesModel(row, model));
    buckets = bucket ? [bucket] : [];
  }
  return globalThis.structuredClone({ kind: history ? "history" : "live", capturedAt: now,
    archiveId: history?.generation ?? snapshot.archives?.live ?? null,
    data: { title: history ? "Selected history evidence" : "Captured live-only usage", source, model, timeZone: zone,
      first, last, start: bucket?.start ?? history?.calendar[0]?.start, end: bucket?.end ?? history?.calendar.at(-1)?.end,
      hourly, usage: (hourly && history) || model === null ? denominator : merge(rows.map(row => row.usage)),
      denominator, models: modelGroups(rows), buckets, truncated: history?.truncated ?? false,
      partial: history ? false : snapshot.partial, hourlyModelsUnavailable: Boolean(hourly && history),
      gaps: (history?.sourceGaps ?? []).filter(gap => gap.source === source && dayKey(gap.start,zone) <= last && dayKey(gap.end,zone) >= first) } });
}

export function captureInsight(history, report, item) {
  return globalThis.structuredClone({ kind: "insight", capturedAt: history.capturedAt,
    archiveId: history.generation, data: { title: item.label, evidence: report.evidence, item } });
}
export function captureTimeline(timeline) {
  return globalThis.structuredClone({ kind: "timeline", capturedAt: timeline.status.capturedAt,
    archiveId: timeline.status.generation, data: timeline });
}

export function timelineStatus(status, formatTime) {
  return `<p>Captured ${e(formatTime(status.capturedAt))}. Kept for ${e(status.retentionDays)} days; retention cutoff ${e(formatTime(status.cutoff))}.
    ${status.recording ? "Recording new observations." : "Recording paused or waiting for a client."}</p>
    ${status.interrupted ? '<p class="error">Recording was interrupted or unavailable in this archive. This timeline may be incomplete.</p>' : ""}
    ${status.pruned ? '<p class="error">Retention or capacity limits removed events or sessions from this archive.</p>' : ""}
    ${status.legacy ? '<p class="error">Earlier recording interruptions were not tracked. Legacy timeline coverage is unknown.</p>' : ""}`;
}

function usageTable(usage) {
  return `<dl class="detail-values"><dt>Observed tokens</dt><dd>${count(total(usage))}</dd><dt>Calls</dt><dd>${count(usage.calls)}</dd>
    <dt>Input (excluding known cache)</dt><dd>${count(usage.input)}</dd><dt>Output</dt><dd>${count(usage.output)}</dd>
    <dt>Cache read</dt><dd>${cache(usage)}</dd><dt>Cache write</dt><dd>${cache(usage,true)}</dd>
    <dt>Mean call duration</dt><dd>${usage.durationSamples ? `${count(usage.durationMs / usage.durationSamples)} ms` : "Not reported"} (${count(usage.durationSamples)} samples)</dd>
    <dt>Mean first token</dt><dd>${usage.firstTokenSamples ? `${count(usage.firstTokenMs / usage.firstTokenSamples)} ms` : "Not reported"} (${count(usage.firstTokenSamples)} samples)</dd></dl>`;
}
function coverageTable(buckets, formatTime) {
  return `<div class="table-scroll" data-scroll-key="coverage"><table><caption>Captured recording coverage</caption><thead><tr><th>Period start</th><th>State</th><th>Recording seconds</th><th>Known gap</th></tr></thead>
    <tbody>${buckets.map(bucket => `<tr><th>${e(formatTime(bucket.start))}</th><td>${e(bucket.coverage)}</td><td>${count(bucket.recordingSeconds)}</td><td>${bucket.gap ? "Yes" : "No known gap"}</td></tr>`).join("")}</tbody></table></div>`;
}
function gapList(gaps, formatTime) {
  return gaps.length ? `<h3>Captured gaps</h3><ul>${gaps.map(gap => `<li>${e(formatTime(gap.start))} - ${e(formatTime(gap.end))}</li>`).join("")}</ul>` : "<p>No known gap intervals in this captured selection. This is not proof of complete delivery.</p>";
}

export function detailMarkup(request, formatTime, page = 0) {
  const data = request.data;
  if (request.kind === "timeline") {
    const rows = data.events.slice(page * 100,(page + 1) * 100);
    return `<h1 tabindex="-1" id="detail-heading">Session ${e(data.session.slice(0,8))}</h1>
      ${timelineStatus(data.status,formatTime)}${data.truncated ? '<p class="error">Some events from this session were removed by retention or capacity limits.</p>' : ""}
      <p>Showing ${page * 100 + 1}-${page * 100 + rows.length} of ${data.events.length} retained events. Historical context below is not a live context reading.</p>
      ${pagination(page,data.events.length,"detail-page")}
      ${rows.map(row => {
        const event = row.event;
        return `<article class="timeline-event"><h2>${e(event.kind)} - ${e(sourceName(row.source))}</h2><p>${e(formatTime(row.timestamp))}</p>
          ${event.tokens ? `<p>Model: ${e(event.tokens.model ?? "Not reported")}</p>${usageTable(fromTokens(event.tokens))}` : "<p>Token and response-time fields: Not reported for this event.</p>"}
          ${event.context ? `<p>Historical context: ${count(event.context.currentTokens)} / ${count(event.context.tokenLimit)} tokens.</p>` : ""}
          ${event.compaction ? `<p>Compaction: ${event.compaction.success === true ? "Completed successfully" : event.compaction.success === false ? "Failed completion" : "Started; completion not reported"}.
            Before: ${count(event.compaction.before)}. After: ${count(event.compaction.after)}.</p>` : ""}</article>`;
      }).join("")}`;
  }
  if (request.kind === "insight") {
    const { evidence, item } = data;
    return `<h1 tabindex="-1" id="detail-heading">${e(item.label)} evidence</h1><p>${e(item.detail)}</p>
      <p>Captured ${e(formatTime(request.capturedAt))}; ${e(evidence.source === "all" ? "All sources" : sourceName(evidence.source))}; reporting zone ${e(evidence.timeZone)}.
        Previous ${e(evidence.first)} through ${e(evidence.periods[0].last)}; current ${e(evidence.middle)} through ${e(evidence.last)}.</p>
      <p>${item.available ? "Comparison eligible" : "Comparison unavailable"}.
        ${item.changes ? "Individual model shares are shown below." : `Previous: ${count(item.previous)}${item.unit ? ` ${e(item.unit)}` : ""}; current: ${count(item.current)}${item.unit ? ` ${e(item.unit)}` : ""}.`}</p>
      ${item.changes ? `<div class="table-scroll" data-scroll-key="mix"><table><caption>Observed call shares; all calls remain in the denominator</caption><thead><tr><th>Model</th><th>Previous calls</th><th>Previous share</th><th>Current calls</th><th>Current share</th></tr></thead><tbody>${item.changes.map(change =>
        `<tr><th>${e(change.label)}</th><td>${count(change.previousCalls)}</td><td>${change.previous === null ? "Not available" : `${count(change.previous)}%`}</td><td>${count(change.currentCalls)}</td><td>${change.current === null ? "Not available" : `${count(change.current)}%`}</td></tr>`).join("")}</tbody></table></div>` : ""}
      ${evidence.periods.map((period,index) => `<h2>${index ? "Current" : "Previous"} completed period</h2>${usageTable(period.usage)}
        ${item.samples ? `<p>Independent field coverage: ${count(period.usage[item.samples])} / ${count(period.usage.calls)} calls (${share(period.usage[item.samples],period.usage.calls)}); ${count(period.usage.calls - period.usage[item.samples])} calls did not report this field.</p>` : ""}
        ${item.label === "Compaction frequency" ? `<p>Successful completions: ${count(period.successes)}. Failed completions: ${count(period.failures)}. Starts excluded; not model-attributed. No reports do not establish zero.</p>` : ""}`).join("")}
      ${coverageTable(evidence.buckets,formatTime)}${gapList(evidence.gapIntervals,formatTime)}`;
  }
  return `<h1 tabindex="-1" id="detail-heading">${e(data.title)}</h1><p>Captured ${e(formatTime(request.capturedAt))}; ${e(data.source === "all" ? "All sources" : sourceName(data.source))}.
    ${data.hourly ? `${e(formatTime(data.start))} - ${e(formatTime(data.end))}` : `${e(data.first)} through ${e(data.last)}`}. Reporting zone: ${e(data.timeZone)}.</p>
    <p>Model: ${e(data.model === null ? "All models" : data.model || "Model not reported")}. Values remain fixed to this selection; live context is independent.</p>
    ${data.truncated ? '<p class="error">Model detail exceeded the display limit. Full period denominators are preserved; model shares are unavailable until the range or model is narrowed.</p>' : ""}
    ${data.partial ? '<p class="error">Live sample capacity was reached. This captured breakdown is partial.</p>' : ""}
    ${usageTable(data.usage)}<p>All-model denominator: ${count(total(data.denominator))} tokens; ${count(data.denominator.calls)} calls, including unreported and overflow models.
      Selected call share: ${data.truncated ? "Unavailable (limited model detail)" : share(data.usage.calls,data.denominator.calls)}.</p>
    ${data.hourlyModelsUnavailable ? "<p>Hourly model attribution was not saved. Daily model totals are not substituted for this hour.</p>" :
      `<div class="table-scroll" data-scroll-key="detail-models"><table><caption>Captured model breakdown</caption><thead><tr><th>Model</th><th>Tokens</th><th>Calls</th><th>Call share</th></tr></thead><tbody>${data.models.map(group =>
        `<tr><th>${e(group.label)}</th><td>${count(total(group.usage))}</td><td>${count(group.usage.calls)}</td><td>${data.truncated ? "Unavailable" : share(group.usage.calls,data.denominator.calls)}</td></tr>`).join("")}</tbody></table></div>`}
    ${data.model !== null && !data.usage.calls ? '<p>No calls for this model were observed in the selected snapshot. Missing or overflow attribution is not proof of no model use.</p>' : ""}
    ${coverageTable(data.buckets,formatTime)}${gapList(data.gaps,formatTime)}`;
}

export function pagination(page, count, action) {
  const pages = Math.max(1,Math.ceil(count / 100));
  return `<div class="buttons"><button data-${action}="${page - 1}" data-focus-key="${action}-previous"${page === 0 ? " disabled" : ""}>Previous page</button>
    <span>Page ${page + 1} of ${pages}</span><button data-${action}="${page + 1}" data-focus-key="${action}-next"${page + 1 >= pages ? " disabled" : ""}>Next page</button></div>`;
}
