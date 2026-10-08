// Notch and hover-card markup mirroring sources/Notch/CopilotRing.swift and
// CopilotSummaryView.swift. All lengths are 1x reference points; the notch SVG
// is scaled by its width/height attributes and the card by the --s variable.
import { escape as e, count, total } from "./usage.js";
import { glyphPath } from "./glyph.js";
import { layout, cellHeight, gaugeLength, notchSize, ringCenter, badgeRect, sideNotchPolygon, pathData, isVertical } from "./geometry.js";
import { palette, signals, usageDash, usageLevel, compact, calls, percent, relative, isRequest, primaryQuota, quotaTitle,
  usedFraction, accountStale, quotaWarning, reportedReset, headlineLevel, cacheDisplay, inputDisplay, breakdownIncomplete, contextReading,
  staleSessionCount, accountStatus, accountChecking } from "./presentation.js";

const icons = {
  working: '<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.3" stroke-dasharray="1.1 2.05" stroke-linecap="round"/>',
  idle: '<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M5 8h6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>',
  unknown: '<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M6.3 6.3a1.8 1.8 0 1 1 2.4 1.7c-.5.2-.7.5-.7 1v.4" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/><circle cx="8" cy="11.2" r=".8" fill="currentColor"/>',
  stopped: '<circle cx="8" cy="8" r="7" fill="currentColor"/><rect x="5.4" y="5.4" width="5.2" height="5.2" rx=".8" fill="#000"/>',
  warning: '<path d="M8 1.3 15.2 14H.8Z" fill="currentColor" stroke="currentColor" stroke-width="1" stroke-linejoin="round"/><path d="M8 5.6v4" stroke="#000" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="11.9" r=".9" fill="#000"/>',
  error: '<path d="M5.1 1h5.8L15 5.1v5.8L10.9 15H5.1L1 10.9V5.1Z" fill="currentColor"/><path d="m5.5 5.5 5 5m0-5-5 5" stroke="#000" stroke-width="1.6" stroke-linecap="round"/>',
  input: '<path d="M2.5 1.5h11a1.5 1.5 0 0 1 1.5 1.5v7.5a1.5 1.5 0 0 1-1.5 1.5H7l-3.5 3v-3h-1A1.5 1.5 0 0 1 1 10.5V3a1.5 1.5 0 0 1 1.5-1.5Z" fill="currentColor"/><path d="M6.4 5.3a1.7 1.7 0 1 1 2.3 1.6c-.5.2-.7.5-.7 1" fill="none" stroke="#000" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="9.6" r=".85" fill="#000"/>',
  approval: '<path d="M4.5 7V3.6a1 1 0 0 1 2 0V7m0-4.6V2a1 1 0 0 1 2 0v5m0-4.4a1 1 0 0 1 2 0V7m0-2.6a1 1 0 0 1 2 0v5.4A5.2 5.2 0 0 1 7.3 15 4.6 4.6 0 0 1 3 12.2L1.6 9a1 1 0 0 1 1.7-1l1.2 1.5V7" fill="currentColor"/>',
  check: '<path d="m3.5 8.5 3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
  chevron: '<path d="m4 6 4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>',
  attention: '<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M8 4.8v3.8" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="11.1" r=".85" fill="currentColor"/>',
};
export function icon(name, className = "icon") {
  const classes = name === "working" ? `${className} motion-status` : className;
  return `<svg class="${classes}" viewBox="0 0 16 16" aria-hidden="true" focusable="false">${icons[name] ?? icons.idle}</svg>`;
}
const signalClass = signal => `signal-${signal}`;

function ringSvg(reading, cx, cy) {
  const r = layout.ringDiameter / 2 - layout.trackStroke / 2;
  const circumference = 2 * Math.PI * r;
  let progress = "";
  if (reading.fraction !== null) {
    const dash = reading.stale ? [] : usageDash(reading.fraction);
    const length = circumference * reading.fraction;
    // A dashed texture only covers the drawn part of the arc, as trim + dash does.
    const pattern = dash.length ? `${dash.join(" ")}` : `${length.toFixed(2)} ${circumference.toFixed(2)}`;
    const color = reading.stale ? palette.secondary : palette[usageLevel(reading.fraction)];
    progress = dash.length ?
      `<circle class="ring-progress" cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${color}" stroke-width="${layout.progressStroke}" stroke-dasharray="${pattern}" stroke-linecap="butt" pathLength="${circumference.toFixed(2)}" transform="rotate(-90 ${cx} ${cy})" mask="url(#ring-trim)"/>` :
      `<circle class="ring-progress" cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${color}" stroke-width="${layout.progressStroke}" stroke-dasharray="${pattern}" stroke-linecap="round" transform="rotate(-90 ${cx} ${cy})"/>`;
    if (dash.length) {
      progress = `<mask id="ring-trim" maskUnits="userSpaceOnUse"><circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="#fff" stroke-width="${layout.progressStroke + 1}" stroke-dasharray="${length.toFixed(2)} ${circumference.toFixed(2)}" transform="rotate(-90 ${cx} ${cy})"/></mask>${progress}`;
    }
  }
  const glyph = layout.glyphSize * 0.96;
  const activityRadius = layout.activityDiameter / 2;
  const activity = reading.working ? `<g class="ring-activity" aria-hidden="true"><circle class="motion-status" cx="${cx}" cy="${cy}" r="${activityRadius}" fill="none" stroke="${palette.working}" stroke-width="${layout.activityStroke}" stroke-linecap="round" stroke-dasharray="${(Math.PI * 2 * activityRadius / 4).toFixed(2)} ${(Math.PI * 2 * activityRadius).toFixed(2)}" transform-origin="${cx} ${cy}"/></g>` : "";
  const badge = reading.indicator !== "idle" && reading.indicator !== "working" ?
    `<g class="ring-badge ${signalClass(reading.indicator)}"><circle cx="${cx + layout.ringDiameter / 2 - 5.5}" cy="${cy - layout.ringDiameter / 2 + 5.5}" r="6.5" fill="#000"/><svg x="${cx + layout.ringDiameter / 2 - 11}" y="${cy - layout.ringDiameter / 2}" width="11" height="11" viewBox="0 0 16 16">${icons[reading.indicator] ?? icons.warning}</svg></g>` : "";
  return `<g class="ring${reading.stale ? " ring-stale" : ""}"><circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${palette.ringTrack}" stroke-width="${layout.trackStroke}"/>${progress}
    <svg class="ring-glyph" x="${cx - glyph / 2}" y="${cy - glyph / 2}" width="${glyph}" height="${glyph}" viewBox="0 0 100 100"><path fill-rule="evenodd" fill="#fff" d="${glyphPath}"/></svg></g>${activity}${badge}`;
}

function gaugeSvg(reading, rect, edge) {
  const vertical = isVertical(edge);
  const thickness = layout.gaugeThickness;
  const along = gaugeLength;
  const cx = rect.x + rect.width / 2;
  const cy = rect.y + rect.height / 2;
  const track = vertical ? { x: cx - thickness / 2, y: cy - along / 2, width: thickness, height: along } :
    { x: cx - along / 2, y: cy - thickness / 2, width: along, height: thickness };
  let fill = "";
  if (reading.fraction !== null) {
    const filled = Math.max(thickness, along * reading.fraction);
    const color = reading.stale ? palette.secondary : palette[usageLevel(reading.fraction)];
    fill = `<rect x="${track.x}" y="${track.y}" width="${vertical ? thickness : filled}" height="${vertical ? filled : thickness}" rx="${thickness / 2}" fill="${color}"/>`;
  }
  const lamp = vertical ? [cx, rect.y + layout.gaugeEndZone / 2] : [rect.x + layout.gaugeEndZone / 2, cy];
  const indicator = reading.indicator === "idle" ? "" : reading.indicator === "working" ?
    `<circle cx="${lamp[0]}" cy="${lamp[1]}" r="2" fill="${palette.working}"/>` :
    `<svg class="${signalClass(reading.indicator)}" x="${lamp[0] - 4.5}" y="${lamp[1] - 4.5}" width="9" height="9" viewBox="0 0 16 16">${icons[reading.indicator] ?? icons.warning}</svg>`;
  return `<g class="gauge${reading.stale ? " gauge-stale" : ""}">${reading.fraction === null ? "" :
    `<rect x="${track.x}" y="${track.y}" width="${track.width}" height="${track.height}" rx="${thickness / 2}" fill="${palette.ringTrack}"/>`}${fill}${indicator}</g>`;
}

export function notchShape(edge, scale = 1, collapsed = false) {
  const size = notchSize(edge, scale);
  const rect = badgeRect({ x: 0, y: 0, ...size }, edge, scale, collapsed);
  return { size, rect, polygon: sideNotchPolygon(edge, rect, scale) };
}

export function notchMarkup(reading, edge, scale = 1, collapsed = false) {
  const size = notchSize(edge, 1);
  const { rect, polygon } = notchShape(edge, 1, collapsed);
  const center = ringCenter(size, edge, 1);
  const labelTop = center.y + layout.ringDiameter / 2 + layout.ringLabelGap;
  return `<svg class="notch-svg" width="${(size.width * scale).toFixed(2)}" height="${(size.height * scale).toFixed(2)}" viewBox="0 0 ${size.width.toFixed(3)} ${size.height.toFixed(3)}" aria-hidden="true" focusable="false">
    <path class="notch-body" d="${pathData([polygon])}"/>
    <g class="notch-cell">${ringSvg(reading, center.x, center.y)}<text class="notch-label${reading.stale ? " stale" : ""}" x="${center.x}" y="${labelTop + layout.labelHeight * 0.78}" text-anchor="middle">${e(reading.label)}</text></g>
    ${collapsed ? gaugeSvg(reading, rect, edge) : ""}</svg>`;
}
export const notchCellHeight = cellHeight;

function capsuleBar(fraction, className, label) {
  return `<svg class="capsule-bar" width="100%" height="100%" role="img" aria-label="${e(label)}"><rect class="capsule-track" width="100%" height="100%" rx="2"/>${fraction > 0 ?
    `<rect class="capsule-fill ${className}" width="${(Math.min(fraction, 1) * 100).toFixed(2)}%" height="100%" rx="2"/>` : ""}</svg>`;
}

export function cardHeader() {
  return `<div class="card-header"><svg class="copilot-glyph" viewBox="0 0 100 100" aria-hidden="true" focusable="false"><path fill-rule="evenodd" d="${glyphPath}"/></svg><h1 class="card-title">GitHub Copilot / Copilot CLI</h1>
    <button type="button" id="summary-close" class="card-icon-button" data-close-summary aria-label="Close summary" title="Close summary (Escape)">&#215;</button></div>`;
}

export function allowanceMarkup(snapshot) {
  const quota = primaryQuota(snapshot.account);
  const stale = accountStale(snapshot);
  const signedIn = snapshot.accountAuth?.status === "signedIn";
  const fetched = snapshot.account ? `Fetched ${relative(snapshot.account.observedAt, snapshot.now)}. Account request quota, not local tokens. Open full usage.` :
    signedIn ? "Open account status in Usage" : "Open account sign-in in Settings";
  let body;
  if (quota) {
    const used = usedFraction(snapshot.account);
    const headline = used === null || quota.isUnlimitedEntitlement ? "Unlimited" : `${percent(used)} used`;
    const reset = reportedReset(quota, snapshot.now);
    const warning = stale ? "Stale account reading" : quotaWarning(snapshot);
    const warningLevel = stale ? "watch" : used === null ? "watch" : usageLevel(used);
    body = `<span class="allowance-line"><strong class="allowance-headline level-${headlineLevel(snapshot)}">${e(headline)}</strong><span class="secondary truncate">${e(quotaTitle(quota))}</span></span>
      ${used === null ? "" : `<span class="allowance-bar">${capsuleBar(used, stale ? "level-stale" : `level-${usageLevel(used)}`, `${quotaTitle(quota)}, ${Math.round(used * 100)} percent used`)}</span>`}
      ${warning || reset ? `<span class="allowance-note">${warning ? `<span class="truncate level-text-${warningLevel}">${e(warning)}</span>` : ""}${reset ? `<span class="secondary">Reported reset ${e(relative(reset, snapshot.now))}</span>` : ""}</span>` : ""}`;
  } else {
    const status = accountStatus(snapshot);
    body = `<span>${snapshot.account || signedIn ? "No quota reported" : accountChecking(snapshot) ? "Checking account" : "Connect account for allowance"}</span><span class="secondary small">${e(status)}</span>`;
  }
  return `<button type="button" class="card-row allowance" data-open-page="usage" title="${e(fetched)}">${body}</button>`;
}

function contextMeter(session, now) {
  const reading = contextReading(session, now);
  const cli = session?.source === "cli";
  const details = reading ?
    `${count(reading.currentTokens)} of ${count(reading.tokenLimit)} context tokens (${percent(reading.fraction)}${reading.stale ? " (stale)" : ""}). Current context, not cumulative session tokens.` :
    cli ? "Context not reported. Waiting for a current CLI reading; no usage or model limit is assumed." :
      "Context not reported. VS Code telemetry does not expose context-window occupancy.";
  const value = reading ? `${percent(reading.fraction)}${reading.stale ? " (stale)" : ""}` : "Not reported";
  return { details, markup: `<span class="context-meter" title="${e(details)}"><span class="context-line"><span>Context</span><span class="numeric">${e(value)}</span></span>${reading ?
    `<span class="context-bar">${capsuleBar(reading.fraction, reading.stale ? "level-stale" : `level-${usageLevel(reading.fraction)}`, details)}</span>` :
    '<span class="context-missing" aria-hidden="true"></span>'}</span>` };
}

export function sessionsMarkup(snapshot, rows, title, signal) {
  const working = (snapshot.sessions ?? []).filter(session => session.working).length;
  const counts = working ? `, CLI ${(snapshot.sessions ?? []).filter(s => s.working && s.source === "cli").length} / VS Code ${(snapshot.sessions ?? []).filter(s => s.working && s.source !== "cli").length}` : "";
  const items = rows.slice(0, 3).map(row => {
    const color = signalClass(row.signal);
    const unseen = row.notice && row.unseen ? `<span class="unseen-dot ${color}" role="img" aria-label="New update"></span>` : "";
    if (row.notice) {
      const notice = row.notice;
      const dismiss = isRequest(notice.kind) ? `<button type="button" class="card-icon-button" data-notice="${e(notice.id)}" data-dismiss="true" data-focus-key="notice-${e(notice.id)}" title="Dismiss" aria-label="Dismiss ${e(row.title.toLowerCase())} for ${e(row.label)}" aria-description="Dismiss this notice without answering or approving the request.">${icon("check")}</button>` : "";
      return `<article class="notice-row session-row" id="notice-${e(notice.id)}" tabindex="-1">
        <button type="button" class="card-row row-main" data-notification="${e(JSON.stringify({ kind: "notice", id: notice.id }))}" data-focus-key="notice-open-${e(notice.id)}" title="${e(`${row.label}: ${row.title}. ${row.detail}. Open session details.`)}">
          ${icon(row.signal, `icon ${color}`)}<span class="row-text"><span class="row-title"><span class="secondary">${e(row.label)}</span> <span class="${color} truncate">${e(row.title)}</span>${unseen}</span><span class="secondary truncate">${e(row.detail)}</span></span>
        </button>${dismiss}</article>`;
    }
    const meter = contextMeter(row.session, snapshot.now);
    const client = row.session.source === "cli" ? "cli" : "vscode";
    return `<div class="session-row"><button type="button" class="card-row row-main" data-session="${e(row.session.id)}" data-session-source="${client}" data-focus-key="session-${client}-${e(row.session.id)}" title="${e(`${row.label}: ${row.title}. ${row.detail}. ${meter.details} Open session details.`)}">
      ${icon(row.signal, `icon ${color}`)}<span class="row-text"><span class="row-title"><span class="secondary">${e(row.label)}</span> <span class="${color} truncate">${e(row.title)}</span></span><span class="secondary truncate">${e(row.detail)}</span>${meter.markup}</span>
    </button></div>`;
  }).join("");
  const lastReported = working && signals[signal].priority < signals.stopped.priority ?
    `<p class="card-note">${working} working (last reported)</p>` : "";
  const missing = staleSessionCount(snapshot);
  const coverage = missing ? `<button type="button" class="card-link secondary" data-open-page="connections" title="Open Connections. Update the CLI integration and reload extensions in each existing session.">${missing} ${missing === 1 ? "session" : "sessions"} without recent updates</button>` : "";
  const capacity = snapshot.noticeCapacityReached ? '<button type="button" class="card-link level-text-warning" data-open-page="sessions">Notice capacity reached; older notices were removed</button>' : "";
  return `<h2 class="card-heading">Sessions</h2>
    <button type="button" class="card-row activity" data-open-page="sessions" title="Counts observed work, not open windows. Missing updates are not task completion. Open details." aria-label="${e(title + counts)}">
      ${icon(signal, `icon ${signalClass(signal)}`)}<span class="${signalClass(signal)} truncate">${e(title)}</span><span class="row-trailing secondary">Details</span>
    </button>${items}${lastReported}${capacity}${coverage}`;
}

export function attentionMarkup(snapshot, incident) {
  if (!incident) return "";
  return `<button type="button" class="card-link level-text-watch" data-link="status" title="Open GitHub Status">${icon("attention")} Copilot service incident</button>`;
}

export function breakdownMarkup(usage) {
  const metric = (key, label, value) => `<span class="metric"><span class="dot dot-${key}" aria-hidden="true"></span><span class="secondary">${e(label)}</span> <span class="numeric">${e(value)}</span></span>`;
  return `<span class="breakdown">${metric("input", "Input", inputDisplay(usage))}${metric("output", "Output", compact(usage.output))}${metric("cacheInput", "Cache Read", cacheDisplay(usage))}${metric("cacheWrite", "Cache Write", cacheDisplay(usage, true))}</span>`;
}
export function breakdownLabel(usage) {
  return `${count(total(usage))} observed tokens, ${count(usage.calls)} calls: ${count(usage.input)} ${breakdownIncomplete(usage) ? "Input (breakdown incomplete)" : "Input"}, ${count(usage.output)} output, cache read ${cacheDisplay(usage)}, cache write ${cacheDisplay(usage, true)}.`;
}

export function chartHeaderMarkup({ usage, period, source, sources }) {
  const totals = usage && usage.calls > 0 ?
    `<span class="chart-totals" title="${e(breakdownLabel(usage))}" aria-label="Total: ${e(breakdownLabel(usage))}"><span class="secondary">Tokens</span> <span class="numeric">${e(compact(total(usage)))}</span> <span class="secondary">\u00B7</span> <span class="secondary numeric">${e(calls(usage.calls))}</span></span>` : "<span></span>";
  return `<div class="card-heading-row"><h2 class="card-heading">Models' Usage Chart</h2>
      <label class="source-menu"><span class="visually-hidden">Usage source</span><select id="widget-source" aria-label="Usage source">${sources}</select>${icon("chevron", "icon chevron")}</label></div>
    <div class="period-row" role="group" aria-label="Chart and model usage period">${totals}
      <span class="period-switch"><button type="button" class="period" data-widget-period="1" aria-pressed="${period === "1"}">Today</button><button type="button" class="period" data-widget-period="7" aria-pressed="${period === "7"}">Last 7 days</button></span></div>`
    .replace(`value="${source}"`, `value="${source}" selected`);
}

export const incompleteNote = "* Some calls did not report cache tokens";
const incompleteDetail = "Starred input may include unreported cache activity; starred cache counts cover only the calls that reported them.";

export function modelsMarkup(rows, link, expandable, expanded, incomplete) {
  return `${rows.map(row => {
    const usage = row.usage;
    const target = link && row.model !== null ? link(row.model) : null;
    const label = `${row.title}, ${count(total(usage))} observed tokens, ${count(usage.calls)} calls, ${count(usage.input)} input, ${count(usage.output)} output tokens.`;
    const inner = `<span class="token-line"><span class="truncate model-name">${e(row.title)}</span><span class="numeric">${e(compact(total(usage)))}</span><span class="secondary">\u00B7</span><span class="secondary numeric">${e(calls(usage.calls))}</span></span>${breakdownMarkup(usage)}`;
    return target ? `<button type="button" class="card-row model-row" data-detail="${e(target)}" data-focus-key="${e(target)}" title="${e(label)}" aria-label="${e(label)} Open details">${inner}</button>` :
      `<div class="card-row model-row" title="${e(label)}">${inner}</div>`;
  }).join("")}${incomplete || rows.some(row => breakdownIncomplete(row.usage)) ?
    `<p class="card-note" title="${e(incompleteDetail)}">${e(incompleteNote)}</p>` : ""}${expandable ?
    `<button type="button" class="card-link" data-toggle-models aria-expanded="${expanded}">${expanded ? "Show fewer models" : "Show all models"}</button>` : ""}`;
}

export function footerMarkup() {
  return `<div class="card-footer"><button type="button" class="footer-button" data-open-page="history">View history</button>
    <button type="button" class="footer-button" id="open-settings">Settings\u2026</button>
    <button type="button" class="footer-button footer-link" data-link="pricing" title="https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing" aria-label="GitHub model pricing" aria-description="Opens GitHub's Copilot model pricing page in your browser.">GitHub model pricing \u2197</button></div>`;
}
