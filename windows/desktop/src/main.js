import "./styles.css";
import mark from "../../../sources/Resources/Brand/TokenotchMarkDark.png";
import { bridge } from "./bridge.js";
import { product } from "./product.js";
import { runtimeDescription, exposureAllowed } from "./state.js";
import { NoticeExposure, clippedFraction, visualPreferences } from "./interaction.js";
import { escape as e, sourceName, count, total, merge, cache, todayRows, contextDescription, dayKey, fromTokens, emptyUsage,
  historyTimeline, todayTimeline, chartMarkup, modelGroups, legendMarkup, cliReportingGap, tokenAccountingNote } from "./usage.js";
import { insights } from "./insights.js";
import { HISTORY_RANGES, DEFAULT_RANGE, addDays, dayCount, isMonthly, periodInterval, priorInterval, completedComparison, elapsedDays,
  periodTitle, shortPeriod, dayLabel, percentage, formatChange, latency, meanFirstToken, meanDuration, recordedDuration, modelTitle,
  insightHeadline, orderedInsights } from "./history.js";
import { captureUsage, captureInsight, captureTimeline, detailMarkup, timelineStatus, pagination } from "./details.js";
import { clampScale, notchSize, tooltipPolygons, cardPlacement, layout, pathData } from "./geometry.js";
import { glyphPath } from "./glyph.js";
import { icon, notchMarkup, notchShape, cardHeader, allowanceMarkup, sessionsMarkup, attentionMarkup, breakdownMarkup, breakdownLabel,
  chartHeaderMarkup, modelsMarkup, footerMarkup } from "./card.js";
import { ringReading, sessionRows, activityTitle, sessionSignal, modelRows, canExpandModels,
  provenance, healthIncident, compact as compactNumber, relative, usageLevel, contextReading, hasMissingActivity, accountStale,
  primaryQuota, quotaTitle, cacheDisplay, inputDisplay, breakdownIncomplete, accountStatus, accountIdentity, vscodeSetupStatus } from "./presentation.js";

const app = document.querySelector("#app");
const surface = new URLSearchParams(window.location.search).get("surface");
const widget = ["widget", "notch", "card"].includes(surface);
const showNotch = surface === "widget" || surface === "notch";
const showCard = surface === "widget" || surface === "card";
let actions = Promise.resolve();
let snapshot;
let source = "all";
let editorMetricsChoice;
let currentPage = "connections";
let pinned = false;
let expanded = false;
let widgetPeriod = "1";
let widgetHistory;
let modelsExpanded = false;
let cardGeometry = null;
let renderNotch = () => {};
let layoutCard = () => {};
let historyModels = new Set();
let insightGeneration;
let timelineList;
let timelinePage = 0;
let activeDetail;
let detailPage = 0;
let returnFrame;
const detailTargets = new Map();
let syncWidgetExpansion;
let focusSummary = () => {};

function action(operation, clearError = true) {
  actions = actions.then(async () => {
    if (clearError) document.querySelector("#error").hidden = true;
    await operation();
  }).catch(error => {
    const output = document.querySelector("#error");
    output.hidden = false;
    output.textContent = typeof error === "string" ? error : error instanceof Error ? error.message :
      "The operation failed. Restart Tokenotch and retry.";
  });
  return actions;
}
function html(id, value) {
  const target = document.getElementById(id);
  if (!target || target.innerHTML === value) return;
  const active = target.contains(document.activeElement) ? document.activeElement : null;
  const focus = active?.dataset.focusKey ?? active?.id;
  const open = new Map([...target.querySelectorAll("details[data-key]")].map(node => [node.dataset.key,node.open]));
  const scroll = [...target.querySelectorAll("[data-scroll-key]")].map(node => [node.dataset.scrollKey,node.scrollLeft,node.scrollTop]);
  const position = [window.scrollX,window.scrollY,document.querySelector("#card-scroll")?.scrollTop];
  target.innerHTML = value;
  // Status text refreshes must not restart a spinner's revolution.
  for (const animation of target.getAnimations({ subtree: true })) {
    if (["notch-spin", "session-spin"].includes(animation.animationName)) animation.startTime = 0;
  }
  for (const node of target.querySelectorAll("details[data-key]")) if (open.has(node.dataset.key)) node.open = open.get(node.dataset.key);
  for (const [key,left,top] of scroll) {
    const node = target.querySelector(`[data-scroll-key="${window.CSS.escape(key)}"]`);
    if (node) { node.scrollLeft = left; node.scrollTop = top; }
  }
  if (active) {
    const next = active === target ? target : focus ? target.querySelector(`[data-focus-key="${window.CSS.escape(focus)}"],[id="${window.CSS.escape(focus)}"]`) : null;
    if (next) next.focus({ preventScroll: true });
    else { target.tabIndex = -1; target.focus({ preventScroll: true }); }
  }
  window.scrollTo(position[0],position[1]);
  if (position[2] !== undefined) document.querySelector("#card-scroll").scrollTop = position[2];
}
function time(ms, timeZone = undefined) {
  return ms === null || ms === undefined ? "Not observed" : new Intl.DateTimeFormat(undefined, { dateStyle: "short", timeStyle: "short",
    hour12: snapshot?.preferences.timeFormat === "12", ...(timeZone ? {timeZone} : {}) }).format(ms);
}
function toggle(key, label, detail = "") {
  return `<div class="control-row"><label for="${key}">${label}<span>${detail}</span></label><input id="${key}" data-preference="${key}" type="checkbox"></div>`;
}
const sources = `<option value="all">All sources</option><option value="cli">Copilot CLI</option><option value="vscodeLocal">VS Code Local</option><option value="vscodeCopilot">VS Code Agent Host</option>`;
const seconds = (ms, samples) => {
  if (!samples) return "\u2014";
  const value = ms / samples / 1000;
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} s`;
};
function stackedBar(usage) {
  const sum = total(usage);
  if (!sum) return '<div class="stacked-bar empty" aria-hidden="true"></div>';
  let x = 0;
  const parts = [["input", usage.input], ["output", usage.output], ["cacheInput", usage.cacheInput], ["cacheWrite", usage.cacheWrite]]
    .filter(([, value]) => value > 0).map(([key, value]) => {
      const width = value / sum * 100;
      const rect = `<rect class="segment-${key}" x="${x.toFixed(3)}%" y="0" width="${Math.max(0.4, width - 0.3).toFixed(3)}%" height="100%" rx="3"/>`;
      x += width;
      return rect;
    }).join("");
  return `<svg class="stacked-bar" width="100%" height="8" aria-hidden="true" focusable="false">${parts}</svg>`;
}
function categoryLegend(usage) {
  const value = key => key === "input" ? inputDisplay(usage) :
    key === "output" ? compactNumber(usage.output) : key === "cacheInput" ? cacheDisplay(usage) : cacheDisplay(usage, true);
  return legendMarkup(usage, value);
}
function tile(key, label, value, detail = "") {
  return `<div class="tile" data-metric="${key}"><span class="tile-label">${e(label)}</span><strong class="tile-value">${e(value)}</strong>${detail ? `<span class="tile-detail">${e(detail)}</span>` : ""}</div>`;
}
function usageGroup(usage, tiles) {
  return `<div class="tiles">${tiles.join("")}</div><div class="usage-bar" title="${e(breakdownLabel(usage))}">${stackedBar(usage)}${categoryLegend(usage)}</div>`;
}
function models(rows, compact = false, link = null) {
  const groups = modelGroups(rows);
  if (!groups.length) return `<p class="empty">No model usage observed in this period.</p>`;
  const sum = groups.reduce((value, group) => value + total(group.usage), 0);
  return `<div class="table-scroll" data-scroll-key="models"><table class="models-table"><caption class="visually-hidden">Observed tokens, not account billing</caption><thead><tr><th>Model</th><th class="share-column">Share</th><th>Tokens</th>${compact ? "" : "<th>Calls</th><th>First token</th><th>Duration</th>"}</tr></thead><tbody>${groups.map(({ model, label, usage: value }) => {
    const share = sum ? total(value) / sum : 0;
    const exact = `${count(total(value))} tokens: ${count(value.input)} input${breakdownIncomplete(value) ? " (breakdown incomplete)" : ""}, ${count(value.output)} output, cache read ${cache(value)}, cache write ${cache(value, true)}; ${count(value.calls)} calls.`;
    return `<tr title="${e(exact)}"><th>${link ? `<button class="model-link" data-detail="${e(link(model))}" data-focus-key="${e(link(model))}">${e(label)}</button>` : `<span>${e(label)}</span>`}${compact ? "" : breakdownMarkup(value)}</th>
      <td class="share-column"><span class="share"><svg class="share-bar" width="100%" height="5" aria-hidden="true" focusable="false"><rect class="share-track" width="100%" height="100%" rx="2.5"/><rect class="share-fill" width="${Math.max(share * 100, 1).toFixed(2)}%" height="100%" rx="2.5"/></svg><span>${Math.round(share * 100)}%</span></span></td>
      <td><strong>${e(compactNumber(total(value)))}</strong></td>${compact ? "" : `<td>${compactNumber(value.calls)}</td><td>${seconds(value.firstTokenMs, value.firstTokenSamples)}</td><td>${seconds(value.durationMs, value.durationSamples)}</td>`}</tr>`;
  }).join("")}</tbody></table></div><p class="table-note">Select a model to open its captured details.</p>`;
}
function usageLinks(prefix, history, selected, hourly = false, forModel = false) {
  for (const key of detailTargets.keys()) if (key.startsWith(`${prefix}:`)) detailTargets.delete(key);
  const captured = snapshot;
  return value => {
    const key = `${prefix}:${encodeURIComponent(forModel ? value : value.start)}`;
    detailTargets.set(key, () => captureUsage({ snapshot: captured, history, source: selected,
      model: forModel ? value : history?.modelFilter ?? null, bucket: forModel ? null : value, hourly }));
    return key;
  };
}
function context(session) {
  const description = contextDescription(session.context, snapshot.now);
  const reading = contextReading(session, snapshot.now);
  return `<span class="context" title="${e(description)}"><span class="context-line"><span>Context</span><span>${reading ? `${Math.round(reading.fraction * 100)}%${reading.stale ? " (stale)" : ""}` : "Not reported"}</span></span>${reading ?
    `<svg class="context-bar" width="100%" height="4" role="img" aria-label="${e(description)}"><rect class="capsule-track" width="100%" height="100%" rx="2"/><rect class="capsule-fill ${reading.stale ? "level-stale" : `level-${usageLevel(reading.fraction)}`}" width="${(reading.fraction * 100).toFixed(2)}%" height="100%" rx="2"/></svg>` :
    '<span class="missing-track" aria-hidden="true"></span>'}</span>`;
}
function sessionStatus(session) {
  if (session.working) return "working";
  if (hasMissingActivity(session, snapshot.now)) return "unknown";
  if (["stopped", "ended", "cancelled"].includes(session.kind)) return "idle";
  if (session.kind === "failed") return "error";
  return session.kind === "idle" ? "idle" : "unknown";
}
function sessions(compact = false) {
  const client = source => source === "cli" ? "cli" : "vscode";
  const rows = [...snapshot.sessions].sort((a, b) => Number(b.working) - Number(a.working) || b.observedAt - a.observedAt);
  const ids = new Set(rows.map(row => `${client(row.source)}:${row.id}`));
  for (const sample of snapshot.samples) {
    const key = `${client(sample.source)}:${sample.session}`;
    if (sample.linked && !ids.has(key)) {
      ids.add(key);
      rows.push({ id: sample.session, source: sample.source, working: false, observedAt: sample.date,
        label: "Usage observed; lifecycle not reported", context: null });
    }
  }
  const unlinked = snapshot.samples.some(sample => sample.source !== "cli" && !sample.linked) ?
    '<p class="row-note">Unlinked VS Code usage has no reported session identity and cannot open a session timeline.</p>' : "";
  return (rows.length ? rows.slice(0, compact ? 3 : 100).map(session => {
    const samples = snapshot.samples.filter(v => v.session === session.id && client(v.source) === client(session.source));
    const usage = merge(samples.map(v => fromTokens(v.tokens)));
    const key = `${client(session.source)}:${session.id}`;
    const status = sessionStatus(session);
    return `<details class="session" data-key="${e(key)}"><summary data-focus-key="session-${e(key)}">
      ${icon(status, `icon signal-${status}`)}<span class="session-name"><strong>${e(sourceName(session.source))}</strong> <span class="session-id">${e(session.id.slice(0, 8))}</span>
      <span class="session-status">${e(session.label)} <span class="tertiary">${e(relative(session.observedAt, snapshot.now))}</span></span></span>
      ${context(session)}<span class="session-tokens">${usage.calls ? e(compactNumber(total(usage))) : ""}</span><span class="more" aria-hidden="true">\u22EF</span></summary>
      <div class="session-detail"><p>Last observed ${e(time(session.observedAt))}. ${session.working && session.workStartedAt ? `${Math.max(0, Math.floor((snapshot.now - session.workStartedAt) / 60000))} minutes of observed work; not an ETA.` : "A stop does not establish task success."}</p>
      <p>${usage.calls ? `${count(total(usage))} retained tokens; ${count(usage.calls)} calls. Read: ${cache(usage)}. Write: ${cache(usage, true)}.` : "No linked token calls observed."}</p>
      <button data-session="${e(session.id)}" data-session-source="${client(session.source)}" data-focus-key="timeline-${e(key)}">Open saved session timeline</button></div>
      </details>`;
  }).join("") : '<p class="empty">No live sessions observed. Start Tokenotch before your next Copilot session.</p>') + unlinked;
}
const noticeLabels = { stopped: "Execution stopped (not proof of success)", error: "Error last reported",
  inputRequested: "Input requested - response status unknown", approvalRequested: "Approval requested - response status unknown",
  compactionFailed: "Compaction failed (last reported)", highContext: "Context crossed 80%" };
const noticeIcon = { stopped: "stopped", error: "error", inputRequested: "input", approvalRequested: "approval", compactionFailed: "warning", highContext: "warning" };
function notices(compact = false, prefix = "notice") {
  const rows = snapshot.notices.filter(n => !compact || !n.dismissed && !n.resolved && !(n.kind === "stopped" && n.viewed));
  return rows.length ? rows.map(n => {
    const state = n.resolved ? "Superseded by later evidence" : n.dismissed ? "Dismissed, not confirmed resolved" : n.viewed ? "Viewed" : "Unseen";
    const stale = n.restored || snapshot.now - n.timestamp > 300000;
    return `<article class="notice-row group" id="${prefix}-${e(n.id)}" tabindex="-1">
      ${icon(noticeIcon[n.kind] ?? "warning", `icon notice-icon signal-${noticeIcon[n.kind] ?? "warning"}`)}
      <div class="notice-text"><p class="notice-title"><strong>${e(noticeLabels[n.kind] ?? "Session notice")}</strong>${stale ? ' <span class="status-pill neutral">Stale</span>' : ""}</p>
      <p>${e(sourceName(n.source))} ${e(n.session.slice(0, 6))} <span class="tertiary">${e(relative(n.timestamp, snapshot.now))}</span>${n.restored ? " - last reported before restart" : ""}</p>
      <p class="tertiary">${e(time(n.timestamp))} - ${state}</p></div>
      ${prefix === "attention" ? `<button class="link-button" data-view-notice="${e(n.id)}">View</button>` : ""}
      ${n.resolved || n.dismissed ? "" : `<button class="${prefix === "attention" ? "icon-button" : ""}" data-notice="${e(n.id)}" data-focus-key="${prefix}-${e(n.id)}" data-dismiss="${n.kind !== "stopped"}"${prefix === "attention" ? ` aria-label="${n.kind === "stopped" ? "Mark viewed" : "Dismiss"}" title="${n.kind === "stopped" ? "Mark viewed" : "Dismiss without answering"}"` : ""}>${prefix === "attention" ? "\u2715" : n.kind === "stopped" ? "Mark viewed" : "Dismiss"}</button>`}</article>`;
  }).join("") : '<p class="empty">No session notices.</p>';
}
function quota() {
  const account = snapshot.account;
  if (!account) return `<div class="plan-header"><span class="avatar" aria-hidden="true"></span><div><strong>Account quota unavailable</strong><p class="tertiary">${e(accountStatus(snapshot))}</p><p class="plan-percent">Usage percentage: Not reported</p></div></div>`;
  const stale = accountStale(snapshot);
  const primary = primaryQuota(account);
  const header = `<div class="plan-header"><span class="avatar" aria-hidden="true"></span><div><strong>@${e(account.login)}</strong><p class="tertiary">${e(account.plan ? `GitHub Copilot ${account.plan}` : "GitHub Copilot")}</p></div>${stale ? '<span class="status-pill warn">Stale</span>' : ""}</div>`;
  if (!primary) return `${header}<div class="plan-row"><span>No quota reported. Usage percentage: Not reported.</span></div>`;
  const rows = account.quotas.map(quota => {
    if (quota.isUnlimitedEntitlement) return `<div class="plan-row"><span>${e(quotaTitle(quota))}</span><span class="status-pill ok">Unlimited</span></div>`;
    const used = Math.min(Math.max(1 - quota.remainingPercentage / 100, 0), 1);
    const level = stale ? "stale" : usageLevel(used);
    return `<div class="plan-quota"><div class="plan-quota-line"><span>${e(quotaTitle(quota))}</span><span class="tertiary">${e(count(quota.usedRequests))} of ${e(count(quota.entitlementRequests))}</span></div>
      <p class="plan-percent"><strong>${Math.round(used * 100)}%</strong> used${stale ? " (stale)" : ""}</p>
      <svg class="plan-bar" width="100%" height="8" role="img" aria-label="${e(quotaTitle(quota))}, ${Math.round(used * 100)} percent used"><rect class="capsule-track" width="100%" height="100%" rx="4"/><rect class="capsule-fill settings-${level}" width="${(used * 100).toFixed(2)}%" height="100%" rx="4"/></svg>
      <p class="tertiary">${(100 - used * 100).toFixed(0)}% remaining${quota.resetDate ? `. Reported reset: ${e(Number.isFinite(Date.parse(quota.resetDate)) ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(Date.parse(quota.resetDate)) : quota.resetDate)}` : ""}</p></div>`;
  });
  return header + rows.join("");
}

function showPage(page) {
  activeDetail = undefined;
  returnFrame = undefined;
  const detail = document.querySelector("#detail-view");
  if (detail) { detail.hidden = true; document.querySelector("#detail-content").innerHTML = ""; }
  currentPage = page;
  for (const button of document.querySelectorAll("[data-page]")) {
    if (button.dataset.page === page) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  }

  for (const view of document.querySelectorAll("[data-view]")) view.hidden = view.dataset.view !== page;
  if (page === "history" && !widget && snapshot && (!historyView || historyLoadedKey !== historyReloadKey())) action(loadHistory);
}

async function openDetail(request) {
  if (widget) { await bridge.openDetail(request); return; }
  const focused = document.activeElement;
  const frame = { page: currentPage, focus: focused?.dataset.focusKey ?? focused?.id, x: window.scrollX, y: window.scrollY };
  const current = await bridge.snapshot();
  if (current.archives && (request.archiveId !== current.archives[request.kind === "timeline" ? "timelines" : request.kind === "live" ? "live" : "history"] ||
    request.kind === "timeline" && request.data.events[0]?.timestamp < current.archives.timelineCutoff)) {
    throw new Error("This selected evidence was cleared or expired. Reload the original view.");
  }
  showPage(request.kind === "timeline" ? "sessions" : request.kind === "live" ? "usage" : "history");
  returnFrame = frame;
  activeDetail = request;
  detailPage = 0;
  for (const view of document.querySelectorAll("[data-view]")) view.hidden = true;
  document.querySelector("#detail-view").hidden = false;
  renderDetail();
  document.querySelector("#detail-heading").focus();
  document.querySelector("#detail-view").scrollIntoView({ block: "start" });
}
function renderDetail() {
  const zone = activeDetail.data.timeZone ?? activeDetail.data.evidence?.timeZone;
  html("detail-content", detailMarkup(activeDetail,ms => time(ms,zone),detailPage));
}
function renderTimelineList() {
  if (!timelineList) return;
  const rows = timelineList.sessions.slice(timelinePage * 100,(timelinePage + 1) * 100);
  html("timeline-results", `<h2>Saved session timelines</h2>${timelineStatus(timelineList.status,time)}
    <p>${count(timelineList.sessions.length)} retained sessions. Select a session to browse all its retained events.</p>
    ${pagination(timelinePage,timelineList.sessions.length,"timeline-page")}
    <div class="table-scroll" data-scroll-key="timelines"><table><thead><tr><th>Session</th><th>Sources</th><th>First / last observed</th><th>Events</th><th>Detail</th></tr></thead><tbody>${rows.map(row =>
      `<tr><th><button data-session="${e(row.session)}" data-focus-key="saved-${e(row.session)}">${e(row.session.slice(0,8))}</button></th><td>${e(row.sources.map(sourceName).join(", "))}</td><td>${e(time(row.first))} / ${e(time(row.last))}</td><td>${count(row.count)}</td><td>${row.truncated ? "Events removed" : "All retained events available"}</td></tr>`).join("")}</tbody></table></div>`);
}

async function confirmAction(message) {
  const dialog = document.querySelector("#confirm");
  dialog.querySelector("p").textContent = message;
  dialog.showModal();
  return new Promise(resolve => dialog.addEventListener("close", () => resolve(dialog.returnValue === "continue"), { once: true }));
}

if (widget) {
  document.body.classList.add("widget-surface", `surface-${surface}`);
  const notchHtml = showNotch ? `<button class="notch" id="notch" type="button" aria-label="GitHub Copilot / Copilot CLI" aria-description="Show allowance, activity and usage by model" aria-expanded="false" aria-haspopup="dialog"></button>` : "";
  const cardHtml = showCard ? `<section class="card" id="card" role="dialog" aria-modal="false" aria-label="GitHub Copilot summary" tabindex="-1" aria-hidden="true" inert data-direction="leading">
    <svg class="card-shape" aria-hidden="true" focusable="false"><path id="card-shape-path"/></svg>
    <div class="card-body">
      <div class="card-scroll" id="card-scroll"><div class="card-content" id="card-content">
        ${cardHeader()}
        <p id="error" class="error" role="alert" hidden></p>
        <div id="widget-notification"></div>
        <section class="card-section"><h2 class="card-heading">Usage</h2><div id="widget-quota"></div></section>
        <hr class="card-rule">
        <section class="card-section" id="widget-sessions"></section>
        <div id="widget-attention"></div>
        <hr class="card-rule">
        <section class="card-section"><div id="widget-chart-header"></div><div id="widget-chart"></div><div id="widget-breakdown"></div></section>
        <hr class="card-rule">
        <section class="card-section"><h2 class="card-heading">Models Breakdown</h2><div id="widget-models"></div></section>
      </div></div>
      <hr class="card-rule">
      ${footerMarkup()}
      <p class="card-provenance" id="widget-coverage"></p>
    </div></section>` : `<p id="error" class="visually-hidden" role="alert" hidden></p>`;
  app.innerHTML = `<div class="widget-root" id="widget-root" data-edge="right">${notchHtml}${cardHtml}</div>`;
  const root = document.querySelector("#widget-root");
  const notch = document.querySelector("#notch");
  const card = document.querySelector("#card");
  const exposure = new NoticeExposure();
  let engaged = false;
  let notchEngaged = false;
  let revision = -1;
  let interacted = false;
  let automatic = false;
  let visible = true;
  let until = 0;
  let manuallyDismissed = false;
  let leaveTimer;
  let region = "";
  let cardRegion = "";
  let reportedHeight = 0;
  let regionReady = !bridge.native;
  const isExpanded = () => expanded || (snapshot?.preferences.collapseIdle === false && !manuallyDismissed);
  const applyExpansion = () => {
    root.classList.toggle("expanded", isExpanded());
    notch?.setAttribute("aria-expanded", String(isExpanded()));
    if (card) {
      card.inert = !isExpanded() || !visible;
      card.setAttribute("aria-hidden", String(card.inert));
      if (card.inert) exposure.clear();
    }
    renderNotch();
    layoutCard();
  };
  renderNotch = () => {
    if (!notch || !snapshot) return;
    const edge = snapshot.preferences.edge;
    const scale = clampScale(snapshot.preferences.scale);
    const collapsed = Boolean(snapshot.preferences.autoHideNotch) && !isExpanded();
    const reading = ringReading(snapshot);
    root.dataset.edge = edge;
    notch.dataset.collapsed = String(collapsed);
    notch.setAttribute("aria-description", `${reading.accessibilityValue}. Show allowance, activity and usage by model`);
    html("notch", notchMarkup(reading, edge, scale, collapsed));
    if (bridge.native && surface === "notch") {
      const polygon = notchShape(edge, scale, collapsed).polygon;
      const viewport = [window.innerWidth,window.innerHeight,window.devicePixelRatio];
      const key = JSON.stringify([viewport,polygon]);
      if (key !== region) {
        region = key;
        action(async () => {
          let accepted = false;
          try { accepted = await bridge.setRegion([polygon],null,viewport); }
          finally { if (!accepted && region === key) region = ""; }
        }, false);
      }
    }
  };
  // The card measures its own natural height; native code (or this preview)
  // places it beside the notch with NotchCardPlacement and returns the tail offset.
  layoutCard = () => {
    if (!card || !snapshot) return;
    const scale = clampScale(snapshot.preferences.scale);
    const edge = snapshot.preferences.edge;
    const content = document.querySelector("#card-content");
    const body = card.querySelector(".card-body");
    const style = window.getComputedStyle(body);
    const chrome = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom)
      + [...body.children].filter(child => child.id !== "card-scroll").reduce((sum,child) => {
        const childStyle = window.getComputedStyle(child);
        return sum+child.getBoundingClientRect().height+parseFloat(childStyle.marginTop)+parseFloat(childStyle.marginBottom);
      },0)
      + parseFloat(style.rowGap)*(body.children.length-1);
    const natural = Math.ceil(content.scrollHeight + chrome);
    let size, direction, offset;
    if (surface === "card") {
      if (bridge.native && Math.abs(natural - reportedHeight) > 1) {
        reportedHeight = natural;
        action(() => bridge.setCardHeight(natural), false);
      }
      size = { width: window.innerWidth, height: window.innerHeight };
      direction = cardGeometry?.direction ?? "leading";
      offset = cardGeometry?.tailOffset ?? 0;
    } else {
      const notchRect = notch.getBoundingClientRect();
      const nSize = notchSize(edge, scale);
      const center = { x: notchRect.x + (edge === "top" || edge === "bottom" ? (layout.curlRadius + layout.padStart + layout.ringDiameter / 2) * scale : nSize.width / 2),
        y: notchRect.y + (edge === "left" || edge === "right" ? (layout.curlRadius + layout.padStart + layout.ringDiameter / 2) * scale : layout.bodyDepth / 2 * scale) };
      const placed = cardPlacement({ notch: { x: notchRect.x, y: notchRect.y, width: notchRect.width, height: notchRect.height }, ringCenter: center, edge,
        work: { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight }, contentHeight: natural, scale });
      size = { width: placed.frame.width, height: placed.frame.height };
      direction = placed.direction; offset = placed.tailOffset;
      card.style.left = `${placed.frame.x}px`; card.style.top = `${placed.frame.y}px`;
      card.style.width = `${size.width}px`; card.style.height = `${size.height}px`;
    }
    const shape = tooltipPolygons(direction, size, offset, scale);
    card.dataset.direction = direction;
    const svg = card.querySelector(".card-shape");
    svg.setAttribute("viewBox", `0 0 ${size.width} ${size.height}`);
    document.querySelector("#card-shape-path").setAttribute("d", pathData(shape.polygons));
    if (bridge.native && surface === "card") {
      const viewport = [window.innerWidth,window.innerHeight,window.devicePixelRatio];
      const geometry = cardGeometry;
      const key = JSON.stringify([direction,size,offset,scale,viewport,geometry]);
      if (key !== cardRegion) {
        cardRegion = key;
        action(async () => {
          let accepted = false;
          try { accepted = await bridge.setRegion(shape.polygons,geometry,viewport); regionReady = accepted; }
          finally { if (!accepted && cardRegion === key) cardRegion = ""; }
        }, false);
      }
    }
  };
  syncWidgetExpansion = state => {
    // Native presentations are ordered: an event supersedes snapshots with older revisions, and a
    // snapshot with the event's revision read at least as new a state. Ignore anything older.
    if (typeof state.revision === "number") {
      if (state.revision < revision || state.revision === revision && !state.snapshot) { applyExpansion(); return false; }
      revision = state.revision;
    }
    if (state.automatic && (!automatic || state.until !== until)) {
      engaged = false; interacted = false; exposure.clear();
    }
    automatic = state.automatic;
    until = state.until ?? 0;
    visible = state.visible !== false;
    const wasExpanded = isExpanded();
    expanded = Boolean(state.expanded);
    if (typeof state.pinned === "boolean") pinned = state.pinned;
    if (typeof state.dismissed === "boolean") manuallyDismissed = state.dismissed;
    if (!expanded) { pinned = false; cardRegion = ""; }
    // Native folds (pointer left, notch click, outside click) arrive here, not through expand().
    if (wasExpanded && !isExpanded()) finishExposure();
    if (state.geometry) {
      if (bridge.native && JSON.stringify(state.geometry) !== JSON.stringify(cardGeometry)) regionReady = false;
      cardGeometry = state.geometry;
    }
    if (!visible) { engaged = false; interacted = false; exposure.clear(); }
    applyExpansion();
    if (!card) return true;
    const alert = state.alert;
    html("widget-notification", alert ? `<article class="delivery-card"><strong>${e(alert.title)}</strong><p>${e(alert.body)}</p>
      <p class="secondary">Observed ${e(time(alert.observedAt))}. Automatic display does not mark notices viewed.</p>
      <button type="button" class="card-link" data-notification="${e(JSON.stringify(alert.target))}" data-focus-key="notification-details">Open notification details</button></article>` : "");
    return true;
  };
  const acknowledgeVisible = quick => {
    if (!card) return;
    const rows = [...card.querySelectorAll(".notice-row")].flatMap(article => {
      const notice = snapshot?.notices.find(notice => `notice-${notice.id}` === article.id);
      return notice ? [{...notice,fraction:clippedFraction(article)}] : [];
    });
    const eligible = exposureAllowed({engaged:engaged || notchEngaged,expanded:isExpanded(),visible:visible && regionReady && !document.hidden,automatic,interacted});
    for (const due of exposure.update(window.performance.now(),rows,eligible,quick)) {
      action(async () => { await bridge.acknowledge(due.id,due.dismiss); await refresh(); },false);
    }
  };
  const finishExposure = () => {
    if (!card) return;
    for (const due of exposure.finish()) {
      const notice = snapshot?.notices.find(notice => notice.id === due.id);
      if (!notice || notice.dismissed || notice.resolved) continue;
      action(async () => { await bridge.acknowledge(due.id,true); await refresh(); },false);
    }
  };
  if (card) {
    // The notch is a separate native window: ask native whether the pointer rests on it.
    let engagementPending = false;
    window.setInterval(() => {
      if (!bridge.native || !isExpanded() || !visible) { notchEngaged = false; acknowledgeVisible(false); return; }
      if (engagementPending) return;
      engagementPending = true;
      bridge.pointerEngaged().then(value => { notchEngaged = value; }, () => { notchEngaged = false; })
        .finally(() => { engagementPending = false; acknowledgeVisible(false); });
    },250);
    document.querySelector("#card-scroll").addEventListener("scroll",() => acknowledgeVisible(false),{passive:true});
    new window.MutationObserver(() => acknowledgeVisible(false)).observe(document.querySelector("#widget-sessions"),{childList:true,subtree:true});
  }
  const expand = async (value, dismiss = false, restoreFocus = false) => {
    await bridge.setExpanded(value, dismiss, pinned, restoreFocus);
    expanded = value;
    if (value) manuallyDismissed = false;
    else { if (dismiss) manuallyDismissed = true; finishExposure(); }
    applyExpansion();
    if (!bridge.native && !value && restoreFocus) notch?.focus({preventScroll:true});
  };
  focusSummary = () => {
    if (!card || card.inert) return;
    interacted = true; engaged = true;
    card.querySelector("button:not([disabled]),select:not([disabled])")?.focus({preventScroll:true});
  };
  const enter = () => {
    window.clearTimeout(leaveTimer);
    if (automatic && !interacted) return;
    engaged = true;
    if (!isExpanded() || automatic) action(() => expand(true));
  };
  // Leaving one surface for the other must not fold the card: native code
  // checks the pointer against the notch, card and the bridge between them,
  // and the preview waits briefly for the pointer to arrive on the other side.
  const leave = () => {
    if (pinned) {
      if (!document.hasFocus()) { engaged = false; exposure.clear(); }
      return;
    }
    if (card && engaged && (!automatic || interacted)) acknowledgeVisible(true);
    exposure.clear();
    engaged = false;
    if (bridge.native) { action(() => bridge.pointerLeft(), false); return; }
    window.clearTimeout(leaveTimer);
    leaveTimer = window.setTimeout(() => {
      if (!notch?.matches(":hover") && !card?.matches(":hover") && !pinned) action(() => expand(false));
    }, 250);
  };
  for (const target of [notch, card]) {
    target?.addEventListener("mouseenter", enter);
    target?.addEventListener("mouseleave", leave);
  }
  notch?.addEventListener("click", () => {
    interacted = true;
    pinned = !pinned;
    if (pinned) { engaged = true; action(async () => { await expand(true); if (!bridge.native) focusSummary(); }); }
    else { engaged = false; exposure.clear(); action(() => expand(false, true)); }
  });
  if (surface === "widget") document.addEventListener("pointerdown", event => {
    if (isExpanded() && !notch?.contains(event.target) && !card?.contains(event.target)) {
      pinned = false; engaged = false; exposure.clear(); action(() => expand(false,true));
    }
  });
  // Engaging an automatically revealed card converts it to a manual one.
  card?.addEventListener("pointerdown", () => { interacted = true; engaged = true; if (!isExpanded() || automatic) action(() => expand(true)); });
  card?.addEventListener("focusin", () => { if (!automatic || interacted) { engaged = true; if (!isExpanded() || automatic) action(() => expand(true)); } });
  if (card) {
    window.addEventListener("focus", () => { if (!automatic || interacted) engaged = true; });
    window.addEventListener("blur", () => { engaged = false; pinned = false; exposure.clear(); action(() => expand(false,true)); });
  }
  window.addEventListener("resize", () => { exposure.clear(); regionReady = !bridge.native; region = ""; cardRegion = ""; renderNotch(); layoutCard(); });
  document.addEventListener("visibilitychange", () => { if (document.hidden) { engaged = false; exposure.clear(); } });
  root.addEventListener("keydown", event => {
    interacted = true; engaged = true;
    if (event.key === "Escape") { event.preventDefault(); acknowledgeVisible(true); pinned = false; engaged = false; exposure.clear(); action(() => expand(false,true,true)); }
    else if (event.key === "Tab" && card && isExpanded() && card.contains(document.activeElement)) {
      const controls = [...card.querySelectorAll("button:not([disabled]),select:not([disabled]),input:not([disabled]),[tabindex='0']")].filter(node => node.getClientRects().length);
      const current = controls.indexOf(document.activeElement);
      if (event.shiftKey && current <= 0 || !event.shiftKey && current === controls.length-1) {
        event.preventDefault(); controls[event.shiftKey ? controls.length-1 : 0]?.focus();
      }
    }
    else if (!isExpanded() || automatic) action(() => expand(true));
  });
  card?.addEventListener("change", event => {
    if (event.target.id === "widget-source") action(async () => { source = event.target.value; await refresh(); });
  });
  card?.addEventListener("click", event => {
    if (event.target.closest("[data-close-summary]")) {
      acknowledgeVisible(true); pinned = false; engaged = false; exposure.clear();
      action(() => expand(false,true,true));
      return;
    }
    const period = event.target.closest("[data-widget-period]");
    if (period) action(async () => { widgetPeriod = period.dataset.widgetPeriod; await refresh(); });
    if (event.target.closest("[data-toggle-models]")) { modelsExpanded = !modelsExpanded; render(); }
    const page = event.target.closest("[data-open-page]");
    if (page) action(() => bridge.openSettings(page.dataset.openPage));
    const link = event.target.closest("[data-link]");
    if (link) action(() => bridge.link(link.dataset.link));
    if (event.target.closest("#open-settings")) action(() => bridge.openSettings());
  });
} else {
  const pages = [["usage", "Usage"], ["history", "History"], ["sessions", "Sessions"], null,
    ["connections", "Connections"], ["notifications", "Notifications"], ["general", "General"], null,
    ["privacy", "Privacy"], ["about", "About"]];
  const navIcons = {
    usage: '<circle cx="10" cy="10" r="5.5"/><path d="M10 10l2.6-2.6"/>',
    history: '<path d="M6 14V9M10 14V6M14 14v-3"/>',
    sessions: '<rect x="5" y="5.5" width="10" height="9" rx="1.5"/><path d="M7.5 8.5h5M7.5 11.5h5"/>',
    connections: '<circle cx="6.5" cy="7" r="1.6"/><circle cx="13.5" cy="7" r="1.6"/><circle cx="10" cy="13.5" r="1.6"/><path d="M7.6 8.3l1.4 3.8M12.4 8.3 11 12.1"/>',
    notifications: '<path d="M6.5 13V9.5a3.5 3.5 0 0 1 7 0V13l1 1H5.5ZM9 15.5h2"/>',
    general: '<circle cx="10" cy="10" r="2"/><path d="M10 4.5v1.6M10 13.9v1.6M4.5 10h1.6M13.9 10h1.6M6.1 6.1l1.1 1.1M12.8 12.8l1.1 1.1M6.1 13.9l1.1-1.1M12.8 7.2l1.1-1.1"/>',
    privacy: '<path d="M7.5 10.5V6.5a1 1 0 0 1 2 0v3m0-4a1 1 0 0 1 2 0v4m0-3a1 1 0 0 1 2 0v5.5a3.5 3.5 0 0 1-6.6 1.6L5.6 11a.9.9 0 0 1 1.6-.9l.3.4"/>',
    about: '<circle cx="10" cy="10" r="5.5"/><path d="M10 9.2v3.6M10 7h.01"/>',
  };
  const navIcon = page => `<span class="nav-icon nav-${page}" aria-hidden="true"><svg viewBox="0 0 20 20" focusable="false">${navIcons[page]}</svg></span>`;
  const sourceSelect = (id, label) => `<label class="pill-select"><span class="visually-hidden">${label}</span><select id="${id}" aria-label="${label}">${sources}</select></label>`;
  app.innerHTML = `<div class="app-shell"><aside class="sidebar">
    <div class="brand"><img data-brand alt="" width="34" height="34"><strong>Tokenotch</strong></div>
    <nav aria-label="Settings sections">${pages.map(page => page ? `<button type="button" data-page="${page[0]}">${navIcon(page[0])}<span>${page[1]}</span></button>` : '<span class="nav-gap" aria-hidden="true"></span>').join("")}</nav>
    <div class="sidebar-note"><span class="build-label">${product.channel === "release" ? "Windows" : "Windows development"}</span><p>Version ${product.version}</p></div></aside>
    <main><p id="error" class="error" role="alert" hidden></p><p id="warning" class="error" role="status" hidden></p>
    <section id="detail-view" hidden><button id="detail-back" class="back-button">Back to previous view</button><div id="detail-content" class="group detail-group"></div></section>
    <section data-view="usage" hidden><header><h1>Usage</h1><p>Official account quota and estimated local tokens are separate.</p></header>
      <h2 class="section-title">Copilot plan</h2>
      <div class="group padded" id="usage-account"><p id="usage-account-identity" role="status"></p>
        <div class="buttons"><button data-account="signIn">Sign in with GitHub</button><button data-account="refresh">Refresh quota</button><button data-account="signOut">Sign out</button></div>
        <p class="secondary" id="usage-account-status"></p>
        <details class="account-advanced"><summary>Account options</summary>
          ${toggle("accountEnabled", "Copilot plan quota", "Uses your Copilot CLI sign-in, or a separate GitHub sign-in in your browser. Tokenotch never receives your token.")}
          <div class="row-note"><p class="secondary" id="account-cli"></p>
          <div class="date-controls"><label for="cli-executable">Copilot CLI executable (optional override)<input id="cli-executable" type="text" placeholder="Detected automatically" autocomplete="off"></label><button id="choose-cli">Choose copilot.exe...</button></div></div>
        </details></div>
      <div class="group" id="quota"></div>
      <div class="group-caption"><p id="quota-caption">Account quota comes from GitHub, not from local token counts.</p><button type="button" class="link-button" data-link="usage">View on GitHub</button></div>
      <div class="section-header"><h2 class="section-title">Today</h2>${sourceSelect("source", "Usage source")}</div>
      <div class="group" id="usage-summary"></div>
      <p class="group-caption" id="usage-provenance"></p>
      <div class="group chart-group"><h3 class="group-title" id="usage-chart-title">Today</h3><div id="usage-chart"></div></div>
      <div id="usage-attention"></div>
      <h2 class="section-title">Models today</h2>
      <div class="group" id="models"></div>
      <p class="group-caption">Recorded coverage measures collection opportunity, not proof that a client delivered every call. Cache 0 means every call reported zero; Not reported means omitted; Unknown means legacy coverage. * marks incomplete category detail. Input excludes known cache reads and writes once. Totals are not costs.</p>
      <h2 class="section-title">Sessions</h2><div class="group" id="usage-sessions"></div></section>
    <section data-view="sessions" hidden><header><h1>Sessions</h1><p>Observed activity and last-reported attention, never inferred success.</p></header>
      <h2 class="section-title">Needs attention</h2><div id="notices"></div>
      <h2 class="section-title">Live sessions</h2><div class="group" id="sessions"></div>
      <h2 class="section-title">Saved timelines</h2>
      <div class="group">
        ${toggle("rememberNotices", "Remember notices after quitting", "Separate opt-in; no live working counts or token readings are saved in notices.")}
        ${toggle("timelines", "Record session timelines", "New allowlisted observations only; no prompts, responses, commands or paths.")}
        <div class="control-row"><label for="retentionDays">Keep timelines for</label><select id="retentionDays" data-preference="retentionDays"><option value="1">1 day</option><option value="7">7 days</option><option value="30">30 days</option></select></div>
      </div>
      <div class="buttons"><button id="browse-timelines">Browse saved timelines</button><button data-clear="timelines">Delete timelines</button><button data-clear="notices">Clear notices</button></div>
      <div id="timeline-results"></div><p class="group-caption">Timelines can be partial after pauses, restarts and retention/capacity cleanup. At most 1,000 sessions, 2,000 events/session and 100,000 events total.</p></section>
    <section data-view="history" hidden><header><h1>History</h1><p>Daily token and model totals saved on this PC.</p></header>
      <div class="toolbar group history-filters">
        <label class="pill-select"><span class="visually-hidden">Period</span><select id="history-period" aria-label="Period">${HISTORY_RANGES.map(([value, label]) =>
          `<option value="${value}"${value === DEFAULT_RANGE ? " selected" : ""}>${label}</option>`).join("")}</select></label>
        ${sourceSelect("history-source", "History source")}
        <label class="pill-select"><span class="visually-hidden">History model</span><select id="history-model" aria-label="History model"><option value="all">All models</option></select></label>
        <span class="toolbar-spacer"></span>
        <span class="status-pill neutral" id="recording-badge">Off</span>
      </div>
      <div class="toolbar-secondary" id="history-dates" hidden>
        <div class="date-controls"><label><span id="history-selected-label">Day</span><input id="history-selected" type="date"></label><label>Compare with<input id="history-comparison" type="date"></label></div>
      </div>
      <div id="history-results"></div>
      <h2 class="section-title">Import previously recorded usage</h2>
      <div class="group padded"><p>Choose an OTLP JSON, supported completed-span JSONL or schema-1 SQLite export with producer provenance. WAL-mode databases need matching -wal and -shm companions. Imports only affect daily/hourly history, never live sessions or notifications.</p><button id="import-usage">Preview recorded usage...</button><p id="import-result"></p></div>
      <p class="group-caption" id="history-footer"></p></section>
    <section data-view="connections"><header><h1>Connections</h1><p>Connect GitHub Copilot in the CLI and in VS Code. Tokenotch keeps token counts and models, never content.</p></header>
      <div class="notice" id="onboarding"><div><h2>Welcome to Tokenotch</h2><p>Connect the Copilot CLI, VS Code, or both. Connecting a client also starts local usage history.</p><button id="finish-setup">Finish setup</button></div></div>
      <h2 class="section-title" id="collection-state">Not collecting usage</h2>
      <div class="group connection-card">
        <div class="connection-row"><div><h3>Copilot CLI</h3><p id="cli-status"></p><p id="cli-usage-status"></p></div><div class="buttons"><button data-connect="cli">Connect CLI</button><button data-disconnect="cli">Disconnect</button></div></div>
        <details class="row-note"><summary>CLI tips</summary><p id="cli-extension-help">Model/token usage and live activity/context require the Tokenotch CLI extension. In CLI versions that gate extensions behind Experimental features, opt in with <code>copilot --experimental</code> for that launch, or <code>/settings experimental on</code> for future sessions. This enables other experimental features too; Tokenotch does not change that setting. Restart each CLI session after connecting and check <code>/env</code> for <code>tokenotch-token-usage</code>. Earlier usage is not backfilled.</p></details>
      </div>
      <div class="group connection-card">
        <div class="connection-row"><div><h3>VS Code (GitHub Copilot)</h3><p id="vscode-status"></p><p id="vscode-result"></p></div><div class="buttons"><button data-connect="vscode">Connect VS Code</button><button data-disconnect="vscode">Disconnect</button></div></div>
        <div class="row-note"><label class="check-label"><input id="include-metrics" type="checkbox"> Capture Copilot model &amp; token telemetry</label>
        <div class="buttons"><button id="vscode-approve" data-link="vscodeSetup" hidden>Continue setup in VS Code</button></div></div>
        <details class="row-note"><summary>Advanced</summary>
          <div class="buttons"><button id="vscode-insiders-approve" data-link="vscodeInsidersSetup">Continue in VS Code Insiders</button><button id="companion">Show bundled VS Code extension</button><button id="disable-metrics">Stop VS Code telemetry</button></div>
          <p id="companion-location" class="path"></p>
          <p class="secondary">Connect installs the Tokenotch companion into VS Code and opens it so you can approve the local setup. Approve in the profile you use, then reload VS Code. Requests expire after ten minutes. If VS Code isn't detected, install the bundled VSIX through Extensions &gt; Install from VSIX and run <strong>Tokenotch: Configure local integration</strong>. Your existing collectors, managed settings and edits are kept.</p>
        </details>
      </div>
      <p class="group-caption">No prompts, code or responses are retained. Token/model observations stay local. Missing data is unavailable, not zero.</p></section>
    <section data-view="general" hidden><header><h1>General</h1><p>Saved placement, display selection and fullscreen hiding.</p></header>
      <div class="display-preview" aria-hidden="true"><div class="preview-taskbar"></div><div id="preview-widget" data-edge="right"><svg viewBox="0 0 100 100" width="22" height="22" focusable="false"><path fill-rule="evenodd" fill="#fff" d="${glyphPath}"/></svg></div></div>
      <h2 class="section-title">Notch</h2>
      <div class="group">
        <div class="control-row"><label for="edge">Screen edge</label><select id="edge" data-preference="edge"><option value="right">Right</option><option value="left">Left</option><option value="top">Top</option><option value="bottom">Bottom</option></select></div>
        <div class="control-row"><label for="display">Display</label><select id="display" data-preference="display"><option value="">Primary display (automatic recovery)</option></select></div>
        <div class="control-row"><label for="position">Position along edge</label><input id="position" data-preference="position" type="range" min="0" max="1" step="0.01"></div>
        <p class="row-note">Positioning uses these keyboard-accessible controls, not modifier-drag. Use arrow keys on the slider, or Home/End for its limits.</p>
        <div class="buttons"><button id="show-summary" type="button">Open summary with keyboard focus</button></div>
        <div class="control-row"><label for="scale">Notch scale</label><select id="scale" data-preference="scale"><option value="0.75">75%</option><option value="1">100%</option><option value="1.25">125%</option><option value="1.5">150%</option></select></div>
      </div>
      <h2 class="section-title">Behavior</h2>
      <div class="group">
        <div class="control-row"><label for="textScale">Text size (in addition to Windows text scaling)</label><select id="textScale" data-preference="textScale"><option value="1">100%</option><option value="1.25">125%</option><option value="1.5">150%</option><option value="2">200%</option></select></div>
        ${toggle("reduceMotion","Reduce motion","Stops transitions and working indicators. Tokenotch animates even when Windows animation effects are off.")}
        ${toggle("reduceTransparency","Use opaque surfaces","Also follows Windows transparency. Empty space outside the notch/card remains click-through.")}
        <p id="visual-preferences" class="row-note" role="status"></p>
      </div>
      <div class="group">
        ${toggle("widgetVisible", "Show activity widget", "Settings remain available from the tray.")}
        ${toggle("allDisplays", "Show on all displays", "Each screen keeps its own hover state. Disconnected displays recover automatically.")}
        ${toggle("autoHideNotch", "Fold the notch into a slim gauge when idle", "Hover or the tray menu brings the full notch and its card back.")}
        ${toggle("collapseIdle", "Close the summary card when idle", "Hover or keyboard focus opens the card; click the notch to keep it open.")}
        ${toggle("hideFullscreen", "Hide widget for fullscreen apps", "Does not hide over ordinary maximized, titled windows.")}
        <div class="control-row"><label for="timeFormat">Time format</label><select id="timeFormat" data-preference="timeFormat"><option value="24">24-hour</option><option value="12">12-hour</option></select></div>
      </div></section>
    <section data-view="notifications" hidden><header><h1>Notifications</h1><p>Independent opt-ins; never approve or answer a Copilot request.</p></header>
      <h2 class="section-title">Delivery</h2>
      <div class="group">${toggle("notifications", "Enable notifications")}${toggle("desktopBanner", "Desktop banners")}${toggle("sound", "Play sound")}${toggle("expandCard", "Open the session card")}
      ${toggle("muteNotifications", "Mute every notification channel", "Keeps collection and in-app notices on; muted alerts are consumed and will not replay.")}</div>
      <h2 class="section-title">Categories</h2>
      <div class="group">${toggle("notifyStopped", "Execution stopped")}${toggle("notifyErrors", "CLI errors")}${toggle("notifyRequests", "Input or approval requested (CLI only)")}
      ${toggle("notifyContext", "High CLI context crossings", "Fresh crossing at 80%; rearms below 70%, with a ten-minute cooldown. The first reading is a baseline, not an alert.")}
      ${toggle("notifyIncidents", "Copilot service incidents", "Requires public service checks below. Only newly observed incident records trigger an alert.")}
      ${toggle("notifyRecovery", "Copilot incident recovery", "Requires public service checks and explicit resolution of a previously observed incident. Failed checks and feed omissions are not recovery.")}</div>
      <h2 class="section-title">GitHub service health</h2>
      <div class="group">${toggle("serviceHealth", "Check public GitHub service health", "Optional requests to githubstatus.com every five minutes.")}
      <div class="row-note"><button id="check-health">Refresh service status</button><p id="health" tabindex="-1"></p></div></div>
      <p class="group-caption">Quota ring thresholds are visual only. There are no quota, AI-credit or billing alerts inferred from local token counts.</p>
      <p class="group-caption">Automatic cards last at least three seconds on eligible displays without focusing or opening Settings. During automatic display, click or use the keyboard to engage before notice exposure can be acknowledged.</p>
      <h2 class="section-title">Quiet hours</h2>
      <div class="group">${toggle("quietHours", "Quiet hours")}<div class="row-note"><div class="date-controls"><label>Quiet start<input id="quietStart" data-preference="quietStart" type="time"></label><label>Quiet end<input id="quietEnd" data-preference="quietEnd" type="time"></label></div>
      <div class="buttons"><button id="snooze">Snooze for one hour</button><button id="unsnooze">End snooze</button></div><p id="snoozed"></p></div></div>
      <h2 class="section-title">Check delivery</h2>
      <div class="group padded"><div class="buttons"><button id="test-notification">Test current notification settings</button><button id="notification-status">Check Windows notification permission</button><button data-link="notifications">Open Windows notification settings</button></div>
      <p id="notification-test-result"></p><p id="notification-permission"></p><p id="notification-delivery" role="status"></p><p id="notification-error" class="error" role="alert" hidden></p></div>
      <p class="group-caption">Tests use the stopped category. Banners, sound and cards are independent; Windows banner permission does not enable or silence the other channels. Suppression receipts survive restarts and clearing notices, independently of remembered notice content.</p></section>
    <section data-view="privacy" hidden><header><h1>Privacy</h1><p>No backend, analytics, transcript scanning or content capture.</p></header>
      <h2 class="section-title">Usage history</h2>
      <div class="group">${toggle("history", "Save usage history", "Daily token and model totals from connected clients, plus hourly detail for the latest seven days. No prompts, code or project names.")}
        <div class="control-row"><label>Delete usage history<span>Removes all saved daily and hourly totals.</span></label><button data-clear="history">Delete\u2026</button></div></div>
      <h2 class="section-title">Stored data</h2>
      <div class="group padded"><p>Live observations are bounded to 24 hours, 4,096 calls and 100 sessions. Optional history, timelines, notices and account credentials are separate. All files use a user-only Windows ACL under your .tokenotch directory.</p>
      <div class="buttons"><button data-clear="live">Clear live observations</button><button data-clear="timelines">Delete saved timelines</button><button data-clear="notices">Clear session notices</button></div></div>
      <p class="group-caption">Deletion is logical, not forensic erasure. Removing a connection stops collection without deleting saved history. Delete each archive separately.</p>
      <h2 class="section-title">Diagnostics</h2>
      <div class="group padded"><button id="diagnostics">Preview redacted diagnostics</button><pre id="diagnostic-output" hidden></pre></div></section>
    <section data-view="about" hidden><header class="about-header"><img data-brand alt="" width="72" height="72"><div><h1>Tokenotch for Windows</h1><p>Visibility into your AI coding usage and patterns.</p></div></header>
      <div class="group"><dl class="about-list"><dt>Product version</dt><dd>${product.version}</dd><dt>Distribution</dt><dd>${product.channel === "release" ? "Unsigned local production build" : "Unsigned development build"}</dd><dt>Targets</dt><dd>Windows 11 x64 and native ARM64</dd></dl></div>
      <div class="notice"><div><h2>${product.channel === "release" ? "Unsigned local build" : "Not a supported Windows release"}</h2><p>${product.channel === "release" ? "This production build is not code-signed or publicly certified. Windows may warn before installation. Native ARM64, installer lifecycle, accessibility and real-client acceptance are separate from compilation." : "Development features require real-client and desktop acceptance. Native ARM64, installer lifecycle and accessibility acceptance remain separate."}</p></div></div>
      <div class="buttons"><button data-link="releases">Check for updates</button><button data-link="support">Support and documentation</button></div>
      <p class="group-caption">Independent of GitHub and Microsoft. MIT-licensed; original notices are bundled.</p></section>
    <footer><p id="runtime" role="status">Checking application status...</p><button id="refresh">Refresh status</button></footer></main></div>
    <dialog id="confirm"><form method="dialog"><h2>Confirm Tokenotch change</h2><p></p><div class="buttons"><button value="cancel" autofocus>Cancel</button><button value="continue">Continue</button></div></form></dialog>`;
  const requested = new URLSearchParams(window.location.search).get("page");
  if (pages.some(page => page?.[0] === requested)) currentPage = requested;
  showPage(currentPage);
  for (const button of document.querySelectorAll("[data-page]")) button.addEventListener("click", () => showPage(button.dataset.page));
  for (const control of document.querySelectorAll("[data-preference]")) control.addEventListener("change", () => action(async () => {
    const key = control.dataset.preference;
    let value = control.type === "checkbox" ? control.checked : control.value;
    if (["retentionDays", "scale", "textScale", "position"].includes(key)) value = Number(value);
    if (key === "display" && !value) value = null;
    if (["quietStart", "quietEnd"].includes(key)) { const [h, m] = value.split(":").map(Number); value = h * 60 + m; }
    const consent = ["history", "timelines", "rememberNotices", "notifications", "accountEnabled", "serviceHealth"].includes(key) && value ||
      key === "rememberNotices" && !value || key === "retentionDays" && value < snapshot.preferences.retentionDays;
    if (consent && !await confirmAction(key === "rememberNotices" && !value ?
      "Delete saved notices and keep current notices only in memory?" : key === "retentionDays" ?
        "Shorten retention and permanently delete older timeline events?" : key === "history" ? HISTORY_CONSENT :
        `Enable ${control.labels[0].textContent.trim()}? This starts now, without backfilling earlier activity. You can turn it off independently.`)) { await refresh(); return; }
    await bridge.preferences({ ...snapshot.preferences, [key]: value }); await refresh();
    if (key === "history" && value && currentPage === "history") await loadHistory();
    if (key === "accountEnabled" && value) await verifyAccount();
  }));
  document.querySelector("#cli-executable").addEventListener("change", event => action(async () => {
    await bridge.preferences({ ...snapshot.preferences, cliExecutable: event.target.value || null }); await refresh();
    await verifyAccount();
  }));
  document.querySelector("#choose-cli").addEventListener("click", () => action(async () => {
    const path = await bridge.chooseFile("cli");
    if (!path) return;
    await bridge.preferences({ ...snapshot.preferences, cliExecutable: path }); await refresh();
    await verifyAccount();
  }));
  document.querySelector("#import-usage").addEventListener("click", () => action(async () => {
    const path = await bridge.chooseFile("import");
    if (!path) return;
    const preview = await bridge.previewImport(path);
    document.querySelector("#import-result").textContent = `${count(preview.calls)} supported calls; ${count(preview.filtered)} filtered spans; ${count(preview.rejected)} rejected spans. ${count(total(preview.usage))} observed tokens.`;
    if (!preview.calls || !await confirmAction(`Save ${count(preview.calls)} supported calls to usage history? ${count(preview.rejected)} spans were rejected. Coverage stays partial; already saved calls will not be counted again. History must be enabled first.`)) return;
    const added = await bridge.commitImport(preview.fingerprint);
    document.querySelector("#import-result").textContent = `${count(added)} new calls saved. Existing calls were skipped.`;
    await refresh(); await loadHistory();
  }));
  for (const button of document.querySelectorAll("[data-connect]")) button.addEventListener("click", () => action(async () => {
    const vscode = button.dataset.connect === "vscode";
    if (!await confirmAction(vscode ?
      "Connect VS Code? Tokenotch installs its setup companion in VS Code and opens it so you can approve local Copilot telemetry (token counts and models only). Usage history recording starts. Your other settings are preserved." :
      "Connect the Copilot CLI? Tokenotch installs its own hooks and usage extension and starts recording local usage history. No prompts, code or responses are kept. Other integration files are preserved.")) return;
    await bridge.connection(button.dataset.connect, "install", vscode && document.querySelector("#include-metrics").checked);
    await refresh();
    if (!vscode) return;
    let link;
    try { link = await bridge.installCompanion(); }
    catch (error) {
      document.querySelector("#companion-location").textContent = `${error?.message ?? error} Bundled extension: ${await bridge.companion()}`;
      document.querySelector("#companion-location").closest("details").open = true;
      await bridge.link("vscodeCompanion");
      return;
    }
    await bridge.link(link);
  }));
  for (const button of document.querySelectorAll("[data-disconnect]")) button.addEventListener("click", () => action(async () => {
    if (!await confirmAction("Disconnect this client and remove only unchanged Tokenotch-owned files? Saved history is kept. For VS Code, approve the removal in the editor.")) return;
    await bridge.connection(button.dataset.disconnect, "remove"); await refresh();
    if (button.dataset.disconnect === "vscode") await bridge.link("vscodeSetup");
  }));
  document.querySelector("#disable-metrics").addEventListener("click", () => action(async () => {
    await bridge.connection("vscode", "disableMetrics"); await refresh();
    await bridge.link("vscodeSetup");
  }));
  document.querySelector("#include-metrics").addEventListener("change", event => {
    editorMetricsChoice = event.target.checked;
  });
  for (const button of document.querySelectorAll("[data-account]")) button.addEventListener("click", () => action(async () => {
    if (button.dataset.account === "signOut" && !await confirmAction(snapshot.accountShared ?
      "Stop showing Copilot plan quota? Your normal Copilot sign-in is untouched." :
      "Remove only Tokenotch's separate Copilot account credentials? Your normal Copilot sign-in is untouched.")) return;
    if (button.dataset.account === "signIn" && !snapshot.preferences.accountEnabled) {
      if (!await confirmAction("Enable account quota? Tokenotch uses your existing Copilot CLI sign-in when available; otherwise GitHub sign-in opens in your browser. Quota refreshes every minute and Tokenotch never receives your token.")) return;
      await bridge.preferences({ ...snapshot.preferences, accountEnabled: true });
      await refresh();
    }
    snapshot = { ...snapshot, accountBusy: true };
    render();
    try { await bridge.account(button.dataset.account); }
    finally { await refresh(); }
  }));
  document.querySelector("#companion").addEventListener("click", () => action(async () => {
    document.querySelector("#companion-location").textContent = await bridge.companion();
    await bridge.link("vscodeCompanion");
  }));
  document.querySelector("#finish-setup").addEventListener("click", () => action(async () => {
    await bridge.preferences({ ...snapshot.preferences, onboardingComplete: true }); await refresh();
  }));
  for (const button of document.querySelectorAll("[data-clear]")) button.addEventListener("click", () => action(async () => {
    if (!await confirmAction(button.dataset.clear === "history" ?
      "Delete all saved usage history? This can't be undone. If recording is on, it continues with empty history. Session timelines, live data and your GitHub sign-in aren't affected." :
      `Delete ${button.dataset.clear} data? This cannot be undone. Other archives and connections are not removed.`)) return;
    await bridge.clear(button.dataset.clear);
    await refresh();
  }));
  for (const button of document.querySelectorAll("[data-link]")) button.addEventListener("click", () => action(() => bridge.link(button.dataset.link)));
  document.querySelector("#check-health").addEventListener("click", () => action(async () => { await bridge.health(); await refresh(); }));
  document.querySelector("#notification-status").addEventListener("click", () => action(async () => {
    document.querySelector("#notification-permission").textContent = await bridge.notificationStatus();
  }));
  document.querySelector("#test-notification").addEventListener("click", () => action(async () => {
    const queued = await bridge.testNotification();
    document.querySelector("#notification-test-result").textContent = queued ? "Test queued. Review the last delivery results below." :
      "Test consumed without delivery. Master, category, channel, mute, snooze and quiet-hour settings apply.";
    await refresh();
  }));
  document.querySelector("#snooze").addEventListener("click", () => action(async () => { await bridge.preferences({ ...snapshot.preferences, snoozedUntil: Date.now() + 3600000 }); await refresh(); }));
  document.querySelector("#unsnooze").addEventListener("click", () => action(async () => { await bridge.preferences({ ...snapshot.preferences, snoozedUntil: 0 }); await refresh(); }));
  document.querySelector("#source").addEventListener("change", event => { source = event.target.value; render(); });
  document.querySelector("#show-summary").addEventListener("click", () => action(() => bridge.showSummary()));
  document.querySelector("#history-source").addEventListener("change", renderHistory);
  document.querySelector("#history-model").addEventListener("change", () => action(loadHistory));
  document.querySelector("#history-period").addEventListener("change", () => action(loadHistory));
  for (const id of ["history-selected", "history-comparison"]) document.getElementById(id).addEventListener("change", () => action(loadHistory));
  document.querySelector("#detail-back").addEventListener("click", () => {
    const frame = returnFrame;
    showPage(frame?.page ?? "usage");
    if (frame?.focus) document.querySelector(`[data-view="${frame.page}"]`)?.querySelector(`[data-focus-key="${window.CSS.escape(frame.focus)}"],[id="${window.CSS.escape(frame.focus)}"]`)?.focus({ preventScroll: true });
    if (frame) window.scrollTo(frame.x,frame.y);
  });
  document.querySelector("#browse-timelines").addEventListener("click", () => action(async () => {
    timelineList = await bridge.timelineSessions(); timelinePage = 0; renderTimelineList();
  }));
  document.querySelector("#diagnostics").addEventListener("click", () => {
    const output = document.querySelector("#diagnostic-output"); output.hidden = false;
    output.textContent = JSON.stringify({ version: product.version, native: bridge.native,
      configured: { cli: snapshot.connections.cli, vscode: snapshot.connections.vscode },
      receiverRunning: snapshot.receiverRunning, sourcesObserved: Object.keys(snapshot.delivery),
      historyEnabled: snapshot.preferences.history, timelinesEnabled: snapshot.preferences.timelines,
      retainedCalls: snapshot.samples.length, retainedSessions: snapshot.sessions.length,
      hasCollectionWarning: Boolean(snapshot.warning), hasAccountError: Boolean(snapshot.accountError) }, null, 2);
  });
  document.querySelector("#refresh").addEventListener("click", () => action(refresh));
}
document.addEventListener("click", event => {
  if (event.target.closest("[data-enable-history]")) action(async () => {
    if (!await confirmAction(HISTORY_CONSENT)) return;
    await bridge.preferences({ ...snapshot.preferences, history: true }); await refresh(); await loadHistory();
  });
  const modelFilter = event.target.closest("[data-history-model]");
  if (modelFilter) action(async () => {
    const value = `name:${modelFilter.dataset.historyModel}`;
    const select = document.querySelector("#history-model");
    select.value = select.value === value ? "all" : value;
    await loadHistory();
  });
  const page = event.target.closest("[data-open-page]");
  if (page && !widget) showPage(page.dataset.openPage);
  const button = event.target.closest("[data-notice]");
  if (button) action(async () => { await bridge.acknowledge(button.dataset.notice, button.dataset.dismiss === "true"); await refresh(); });
  const notification = event.target.closest("[data-notification]");
  if (notification) action(() => bridge.openNotification(JSON.parse(notification.dataset.notification)));
  const selected = event.target.closest("[data-detail]");
  if (selected) {
    const capture = detailTargets.get(selected.dataset.detail);
    if (capture) {
      const request = capture();
      action(() => openDetail(request));
    } else action(() => { throw new Error("This selected evidence is no longer available. Reload the original view."); });
  }
  const session = event.target.closest("[data-session]");
  if (session) {
    const id = session.dataset.session;
    const source = session.dataset.sessionSource ?? null;
    action(async () => openDetail(captureTimeline(await bridge.timelineDetail(id,source))));
  }
  const listPage = event.target.closest("[data-timeline-page]");
  if (listPage) { timelinePage = Number(listPage.dataset.timelinePage); renderTimelineList(); }
  const viewNotice = event.target.closest("[data-view-notice]");
  if (viewNotice) {
    showPage("sessions");
    const target = document.getElementById(`notice-${viewNotice.dataset.viewNotice}`);
    target?.focus(); target?.scrollIntoView({ block: "center" });
  }
  const nextPage = event.target.closest("[data-detail-page]");
  if (nextPage) { detailPage = Number(nextPage.dataset.detailPage); renderDetail(); }
});
document.addEventListener("keydown", event => {
  if (event.key === "Escape" && activeDetail && !document.querySelector("dialog[open]")) document.querySelector("#detail-back").click();
});
for (const image of document.querySelectorAll("[data-brand]")) image.src = mark;

// History mirrors the macOS UsageHistoryView: filters, summary, daily chart, models,
// comparison with the previous period, weekly insights, context and a daily breakdown.
const HISTORY_CONSENT = "Save usage history on this PC? Tokenotch saves daily token and model totals from connected clients until you delete them, plus hourly detail for the latest seven days. No prompts, code or project names are saved. The reporting time zone is fixed when you first turn this on.";
let historyView;
let historyError;
let historyLoadedKey;
const historyToday = () => dayKey(snapshot.now, snapshot.today?.timeZone);
const historyReloadKey = () => [snapshot.archives?.history, snapshot.archives?.historyRevision, historyToday(),
  snapshot.preferences.history, snapshot.today?.startedAt].join("|");
const bySource = (rows, selected) => rows.filter(row => selected === "all" || row.source === selected);
function periodUsage(archive, selected, allModels = false) {
  if (!archive) return emptyUsage();
  const rows = typeof archive.modelFilter === "string" && !allModels ? archive.days : archive.totals ?? archive.days;
  return merge(bySource(rows, selected).map(row => row.usage));
}
function historyEmptyState() {
  return snapshot.preferences.history ?
    `<div class="group padded empty-state"><h3>No history yet</h3><p>Usage from connected clients appears here after your next Copilot request.</p></div>` :
    `<div class="group padded empty-state"><h3>Track usage over time</h3><p>Save daily token and model totals on this PC to see trends, compare periods and spot changes.</p>
      <div class="buttons"><button type="button" class="primary" data-enable-history>Turn On History\u2026</button></div></div>`;
}
function historyModelsTable(rows, denominator, selectedModel) {
  const groups = modelGroups(rows).filter(group => group.usage.calls > 0);
  if (!groups.length) return "";
  const sum = Math.max(total(denominator), 1);
  return `<h2 class="section-title">Models</h2><div class="group"><div class="table-scroll" data-scroll-key="history-models"><table class="models-table"><thead><tr><th>Model</th><th class="share-column">Share</th><th>Tokens</th><th>Calls</th><th title="Mean time to first token">First token</th><th title="Mean call duration">Duration</th></tr></thead><tbody>${groups.map(({ model, usage: value }) => {
    const share = total(value) / sum;
    const title = modelTitle(model);
    const active = selectedModel === model;
    const key = `history-model:${encodeURIComponent(model)}`;
    return `<tr><th><button type="button" class="model-link" data-history-model="${e(encodeURIComponent(model))}" data-focus-key="${e(key)}" aria-pressed="${active}" title="${e(active ? "Show all models" : `Show only ${title}`)}">${e(title)}</button></th>
      <td class="share-column"><span class="share"><svg class="share-bar" width="100%" height="5" aria-hidden="true" focusable="false"><rect class="share-track" width="100%" height="100%" rx="2.5"/><rect class="share-fill" width="${Math.max(share * 100, 1).toFixed(2)}%" height="100%" rx="2.5"/></svg><span>${Math.round(share * 100)}%</span></span></td>
      <td title="${e(breakdownLabel(value))}"><strong>${e(compactNumber(total(value)))}</strong></td><td>${e(compactNumber(value.calls))}</td><td>${e(latency(meanFirstToken(value)))}</td><td>${e(latency(meanDuration(value)))}</td></tr>`;
  }).join("")}</tbody></table></div></div>
  <p class="group-caption">${selectedModel === null ? "Select a model to filter this page." : "Select the model again to show all models."}</p>`;
}
function historyComparison(view, selected) {
  const [current, previous] = view.ranges;
  const a = periodUsage(view.current, selected), b = periodUsage(view.previous, selected);
  const incomplete = current.end > view.today || previous.end > view.today;
  const comparable = !incomplete && a.calls > 0 && b.calls > 0;
  const change = (left, right) => comparable && left !== null && right !== null ? formatChange(percentage(left, right)) : "\u2014";
  const currentDays = Math.max(dayCount(current), 1), previousDays = Math.max(dayCount(previous), 1);
  const metrics = [
    ["Tokens", compactNumber(total(a)), compactNumber(total(b)), change(total(a), total(b))],
    ["Tokens per day", compactNumber(Math.floor(total(a) / currentDays)), compactNumber(Math.floor(total(b) / previousDays)),
      change(total(a) / currentDays, total(b) / previousDays)],
    ["Model calls", count(a.calls), count(b.calls), change(a.calls, b.calls)],
    ["First token", latency(meanFirstToken(a)), latency(meanFirstToken(b)), change(meanFirstToken(a), meanFirstToken(b))],
    ["Call duration", latency(meanDuration(a)), latency(meanDuration(b)), change(meanDuration(a), meanDuration(b))],
  ];
  const body = !a.calls || !b.calls ? '<p class="empty padded">Both periods need recorded usage to compare.</p>' :
    `<div class="table-scroll" data-scroll-key="history-comparison"><table class="comparison-table"><thead><tr><th><span class="visually-hidden">Metric</span></th><th>${e(shortPeriod(current))}</th><th>${e(shortPeriod(previous))}</th><th>Change</th></tr></thead><tbody>${metrics.map(([title, left, right, delta]) =>
      `<tr><th>${e(title)}</th><td>${e(left)}</td><td class="secondary">${e(right)}</td><td><strong>${e(delta)}</strong></td></tr>`).join("")}</tbody></table></div>`;
  return `<h2 class="section-title">Compared with previous period</h2><div class="group">${body}</div>
    <p class="group-caption">${incomplete ? "The current period isn't finished, so changes aren't shown yet." : "Compares completed days only. Missing days aren't counted as zero."}</p>`;
}
function historyInsights(view, selected) {
  if (!view.weekly) return "";
  const report = insights(view.weekly, view.today, selected);
  insightGeneration = view.weekly.generation;
  for (const key of detailTargets.keys()) if (key.startsWith("insight:")) detailTargets.delete(key);
  const items = orderedInsights(report.items);
  return `<h2 class="section-title">Weekly insights</h2><div class="group insight-list">${items.map(item => {
    const key = `insight:${item.label}`;
    detailTargets.set(key, () => captureInsight(view.weekly, report, item));
    return `<button type="button" class="insight-row${item.available ? "" : " secondary"}" data-detail="${e(key)}" data-focus-key="${e(key)}" aria-label="${e(`${insightHeadline(item)}. Open ${item.label} evidence`)}">
      <svg class="icon insight-icon" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path d="${item.available ? "M2 12l4-4 3 3 5-6" : "M2 9h12"}" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg><span>${e(insightHeadline(item))}</span><span class="more" aria-hidden="true">\u203A</span></button>`;
  }).join("")}</div>${items.every(item => !item.available) ? '<p class="group-caption">Insights need two complete weeks of history.</p>' : ""}`;
}
function historyContext(archive) {
  const peaks = (archive.contextPeaks ?? []).map(([, high]) => high).filter(Number.isFinite);
  const peak = peaks.length ? Math.max(...peaks) : null;
  const compactions = (archive.compactions ?? []).reduce((sum, [, success, failed]) => sum + success + failed, 0);
  const failed = (archive.compactions ?? []).reduce((sum, [, , value]) => sum + value, 0);
  if (peak === null && !compactions) return "";
  const rows = [];
  if (peak !== null) rows.push(`<div class="control-row"><span>Peak context</span><span class="context-peak"><svg class="context-bar" width="90" height="5" aria-hidden="true" focusable="false"><rect class="capsule-track" width="100%" height="100%" rx="2.5"/><rect class="capsule-fill settings-${usageLevel(peak)}" width="${(Math.min(peak, 1) * 100).toFixed(2)}%" height="100%" rx="2.5"/></svg><span>${Math.round(peak * 100)}%</span></span></div>`);
  if (compactions) {
    rows.push(`<div class="control-row"><span>Compactions</span><span>${e(count(compactions))}</span></div>`);
    if (failed) rows.push(`<div class="control-row"><span>Failed compactions</span><span>${e(count(failed))}</span></div>`);
  }
  return `<h2 class="section-title">Context window</h2><div class="group">${rows.join("")}</div><p class="group-caption">Covers all models. Copilot CLI only.</p>`;
}
function historyBreakdown(buckets, today) {
  const rows = [...buckets].filter(bucket => bucket.day <= today).reverse();
  return `<div class="group"><details class="daily-breakdown" data-key="daily-breakdown"><summary data-focus-key="daily-breakdown">Daily breakdown</summary>
    <div class="table-scroll" data-scroll-key="daily"><table><thead><tr><th>Day</th><th>Tokens</th><th>Calls</th><th title="How long Tokenotch was able to record that day">Recorded</th></tr></thead><tbody>${rows.map(bucket =>
      `<tr><th>${e(dayLabel(bucket.day))}${bucket.day === today ? ' <span class="tertiary">Today</span>' : ""}</th><td>${bucket.calls ? e(count(bucket.tokens)) : "\u2014"}</td>
        <td class="secondary">${bucket.calls ? e(count(bucket.calls)) : "\u2014"}</td><td class="secondary">${bucket.gap ?
        `<span class="level-text-watch" title="Recording was interrupted. Some usage may be missing." aria-label="Recording was interrupted. Some usage may be missing.">\u26A0</span> ` : ""}${bucket.recordingSeconds > 0 ? e(recordedDuration(bucket.recordingSeconds)) : "Not recorded"}</td></tr>`).join("")}</tbody></table></div></details></div>`;
}
function renderHistory() {
  if (widget || !snapshot) return;
  const footer = document.querySelector("#history-footer");
  if (historyError) {
    html("history-results", `<div class="group padded"><p class="error" role="alert">${e(historyError)}</p></div>`);
    footer.textContent = "";
    return;
  }
  if (!historyView) {
    html("history-results", historyEmptyState());
    footer.textContent = "";
    return;
  }
  const view = historyView;
  const archive = view.archive;
  const selected = document.querySelector("#history-source").value;
  const usage = periodUsage(archive, selected);
  const denominator = periodUsage(archive, selected, true);
  const multi = dayCount(view.interval) > 1;
  const days = elapsedDays(view.interval, view.today);
  const active = new Set(bySource(typeof archive.modelFilter === "string" ? archive.days : archive.totals ?? archive.days, selected)
    .filter(row => row.usage.calls > 0).map(row => row.day)).size;
  const paused = snapshot.preferences.history ? "" :
    `<div class="group"><div class="control-row"><label>History is off<span>Saved usage is shown below. New usage isn't being saved.</span></label><button type="button" data-enable-history>Turn On\u2026</button></div></div>`;
  const summary = usage.calls ? usageGroup(usage, [
    tile("tokens", "Tokens", compactNumber(total(usage))),
    tile("calls", "Model calls", compactNumber(usage.calls)),
    multi ? tile("average", "Daily average", compactNumber(Math.floor(total(usage) / days)), `${active} of ${days} days active`) :
      tile("average", "Per call", compactNumber(Math.floor(total(usage) / Math.max(usage.calls, 1)))),
    tile("response", "Response time", latency(meanDuration(usage)), meanFirstToken(usage) === null ? "" : `First token ${latency(meanFirstToken(usage))}`),
  ]) : '<p class="empty padded">No usage was recorded in this period.</p>';
  const elapsed = historyTimeline(archive, snapshot.now, selected);
  const future = archive.calendar.filter(day => day.start > snapshot.now).map(day => ({ ...day, usage: emptyUsage(), tokens: 0, calls: 0,
    recordingSeconds: 0, gap: false, coverage: "future", current: false }));
  const buckets = [...elapsed, ...future];
  const links = usageLinks("history-chart", archive, selected);
  const chart = !multi ? "" : `<h2 class="section-title">Daily tokens</h2><div class="group chart-group">${buckets.some(bucket => bucket.calls > 0) ?
    chartMarkup(buckets, archive.timeZone, snapshot.preferences.timeFormat, false, bucket => bucket.coverage === "future" ? null : links(bucket), "settings", { emptyMarks: false }) :
    '<p class="empty padded">Nothing to chart for this period.</p>'}</div>
    <p class="group-caption">Days without a bar had no recorded usage. Hover a day for details; select it to open captured evidence.${archive.truncated ? " The result exceeds 20,000 model/day rows; narrow the date range." : ""}</p>`;
  html("history-results", `${paused}<h2 class="section-title">${e(periodTitle(view.interval))}</h2><div class="group">${summary}</div>
    ${chart}${historyModelsTable(bySource(archive.days, selected), denominator, archive.modelFilter ?? null)}
    ${historyComparison(view, selected)}${historyInsights(view, selected)}${historyContext(archive)}${multi ? historyBreakdown(elapsed, view.today) : ""}`);
  const began = typeof archive.startedAt === "number" ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeZone: archive.timeZone }).format(archive.startedAt) : null;
  footer.textContent = `Times use ${archive.timeZone}.${began ? ` Recorded since ${began}.` : ""} Estimates from this PC, not billing data.`;
}
async function loadHistory() {
  if (widget || !snapshot) return;
  const range = document.querySelector("#history-period").value;
  const today = historyToday();
  const custom = range === "day" || range === "chosenMonth";
  const selectedInput = document.querySelector("#history-selected");
  const comparisonInput = document.querySelector("#history-comparison");
  document.querySelector("#history-dates").hidden = !custom;
  document.querySelector("#history-selected-label").textContent = range === "day" ? "Day" : "Month";
  selectedInput.max = today; comparisonInput.max = today;
  if (!selectedInput.value || selectedInput.value > today) selectedInput.value = today;
  if (!comparisonInput.value || comparisonInput.value > today) comparisonInput.value = addDays(today, -30);
  historyLoadedKey = historyReloadKey();
  historyError = undefined;
  if (!snapshot.archives?.history || typeof snapshot.today?.startedAt !== "number") {
    historyView = undefined;
    renderHistory(); render();
    return;
  }
  const selectedModel = document.querySelector("#history-model").value;
  const model = selectedModel === "all" ? null : decodeURIComponent(selectedModel.slice(5));
  const interval = periodInterval(range, selectedInput.value, today);
  const ranges = completedComparison(interval, priorInterval(range, interval, comparisonInput.value, today), today, isMonthly(range));
  const query = (period, filter = model) => dayCount(period) ? bridge.history(period.start, addDays(period.end, -1), filter) : null;
  let archive, current, previous, weekly;
  try {
    [archive, current, previous, weekly] = await Promise.all([query(interval), query(ranges[0]), query(ranges[1]),
      query({ start: addDays(today, -14), end: today }, null)]);
  } catch (error) {
    historyView = undefined;
    historyError = error instanceof Error ? error.message : String(error);
    renderHistory(); render();
    return;
  }
  historyView = { archive, current, previous, weekly, interval, ranges, today, range };
  if (model === null) historyModels = new Set();
  for (const row of [...archive.days, ...(previous?.days ?? [])]) historyModels.add(row.model ?? "");
  if (model !== null) historyModels.add(model);
  html("history-model", `<option value="all">All models</option>${[...historyModels].sort((a, b) => modelTitle(a).localeCompare(modelTitle(b))).map(name =>
    `<option value="name:${e(encodeURIComponent(name))}">${e(modelTitle(name))}</option>`).join("")}`);
  document.querySelector("#history-model").value = model === null ? "all" : `name:${encodeURIComponent(model)}`;
  renderHistory(); render();
}
function render() {
  const visuals = visualPreferences(snapshot);
  document.documentElement.style.setProperty("--text-scale",String(visuals.textScale));
  document.documentElement.toggleAttribute("data-large-text",visuals.textScale > 1);
  document.documentElement.toggleAttribute("data-reduced-motion",visuals.reduceMotion);
  document.documentElement.toggleAttribute("data-reduced-status-motion",visuals.reduceStatusMotion);
  document.documentElement.toggleAttribute("data-reduced-transparency",visuals.reduceTransparency);
  const rows = todayRows(snapshot, source);
  const usage = merge(rows.map(row => row.usage));
  const saved = typeof snapshot.today?.startedAt === "number";
  const coverage = saved ? `Usage data saved locally${snapshot.preferences.history ? "" : " - recording paused"}. Reporting zone: ${snapshot.today.timeZone}.` :
    "Live-only observations today. Restart, missed calls and retention limits make coverage partial.";
  if (widget) {
    const state = {expanded:snapshot.widgetExpanded ?? expanded,automatic:Boolean(snapshot.widgetAutomatic),visible:snapshot.widgetVisible,
      pinned:snapshot.widgetPinned,dismissed:snapshot.widgetDismissed,alert:snapshot.widgetAlert,until:snapshot.widgetAlertUntil,geometry:snapshot.cardGeometry,
      revision:snapshot.widgetRevision,snapshot:true};
    document.documentElement.style.setProperty("--s", String(clampScale(snapshot.preferences.scale)));
    if (!showCard) { syncWidgetExpansion(state); return; }
    const matches = row => source === "all" || row.source === source;
    const week = widgetPeriod === "7";
    const history = week ? widgetHistory : saved ? snapshot.today : null;
    const periodRows = week ? (widgetHistory?.days ?? []).filter(matches) : rows;
    const totalRows = history ? (history.totals ?? history.days).filter(matches) : rows;
    const totals = merge(totalRows.map(row => row.usage));
    const available = !week || Boolean(widgetHistory);
    html("widget-chart-header", chartHeaderMarkup({ usage: available ? totals : null, period: widgetPeriod, source, sources }));
    if (!available) {
      html("widget-chart", `<p class="card-note">Seven-day usage needs local history. Enable usage history for seven-day observations. Earlier data cannot be reconstructed.</p>
        <button type="button" class="card-link" data-open-page="history">Enable local history\u2026</button>`);
      html("widget-breakdown", "");
    } else {
      const timeline = todayTimeline(snapshot, source);
      html("widget-chart", week ?
        chartMarkup(historyTimeline(widgetHistory, snapshot.now, source), widgetHistory.timeZone, snapshot.preferences.timeFormat, false, usageLinks("widget-chart", widgetHistory, source), "card") :
        chartMarkup(timeline.buckets, timeline.timeZone, snapshot.preferences.timeFormat, true, usageLinks("widget-chart", saved ? snapshot.today : null, source, true), "card"));
      html("widget-breakdown", totals.calls ? `<div title="${e(breakdownLabel(totals))}" aria-label="${e(breakdownLabel(totals))}">${breakdownMarkup(totals)}</div>` : "");
    }
    html("widget-quota", allowanceMarkup(snapshot));
    const sessionList = sessionRows(snapshot);
    html("widget-sessions", sessionsMarkup(snapshot, sessionList, activityTitle(snapshot, sessionList), sessionSignal(snapshot, sessionList)));
    html("widget-attention", attentionMarkup(snapshot, healthIncident(snapshot)));
    const groups = modelGroups(periodRows);
    html("widget-models", !available ? '<p class="card-note">Model details unavailable for this period.</p>' : totals.calls ?
      modelsMarkup(modelRows(groups, modelsExpanded), usageLinks("widget-model", history, source, false, true), canExpandModels(groups), modelsExpanded, breakdownIncomplete(totals)) :
      `<p class="card-note">No samples observed.</p>${!saved && !snapshot.connections.cli ? '<button type="button" class="card-link" data-open-page="connections">Connect CLI</button>' : ""}`);
    const line = provenance({ saved: Boolean(history), recording: snapshot.preferences.history, partial: snapshot.partial });
    const coverageNote = `${coverage} Recording coverage is collection opportunity, not proof of delivery. Not account-wide usage or billing.`;
    html("widget-coverage", `<span class="${!history && snapshot.partial ? "level-text-watch" : ""}" title="${e(coverageNote)}" aria-label="${e(`${line}. ${coverageNote}`)}">${e(line)}</span>`);
    syncWidgetExpansion(state);
    return;
  }
  html("quota", quota());
  html("quota-caption", snapshot.account ? `Reported by GitHub ${relative(snapshot.account.observedAt, snapshot.now)}. Refreshes every minute while account quota is enabled. Account quota, not local tokens.` :
    "Account quota comes from GitHub, not from local token counts.");
  const timeline = todayTimeline(snapshot, source);
  html("usage-chart-title", `Today${timeline.liveOnly ? " - live-only observations" : " - saved history"}`);
  html("usage-chart", chartMarkup(timeline.buckets, timeline.timeZone, snapshot.preferences.timeFormat, true,usageLinks("usage-chart",saved ? snapshot.today : null,source,true)));
  const todayTotals = saved ? merge((snapshot.today.totals ?? snapshot.today.days).filter(row => source === "all" || row.source === source).map(row => row.usage)) : usage;
  html("usage-summary", usageGroup(todayTotals, [
    tile("tokens", "Tokens", todayTotals.calls ? compactNumber(total(todayTotals)) : "\u2014", todayTotals.calls ? `${count(total(todayTotals))} tokens today` : "No tokens observed today"),
    tile("calls", "Model calls", todayTotals.calls ? count(todayTotals.calls) : "\u2014"),
    tile("per-call", "Per call", todayTotals.calls ? compactNumber(total(todayTotals) / todayTotals.calls) : "\u2014"),
    tile("response", "Response time", seconds(todayTotals.durationMs, todayTotals.durationSamples),
      `First token ${seconds(todayTotals.firstTokenMs, todayTotals.firstTokenSamples)} (${count(todayTotals.durationSamples)} / ${count(todayTotals.firstTokenSamples)} samples)`),
  ]));
  html("usage-provenance", `${e(coverage)}${snapshot.partial ? " Live sample capacity was reached." : ""} ${e(source === "all" || source === "cli" ? cliReportingGap(snapshot) : "")} ${e(tokenAccountingNote)} Estimated local usage. For official usage and billing, check GitHub or your enterprise dashboard.`);
  const attention = notices(true, "attention");
  html("usage-attention", snapshot.notices.some(n => !n.dismissed && !n.resolved && !(n.kind === "stopped" && n.viewed)) ?
    `<h2 class="section-title">Needs attention</h2>${attention}` : "");
  html("models", models(rows,false,usageLinks("usage-model",saved ? snapshot.today : null,source,false,true))); html("sessions", sessions()); html("usage-sessions", sessions());
  html("notices", notices());
  const badge = document.querySelector("#recording-badge");
  const recording = snapshot.connections?.cli || snapshot.connections?.vscode;
  const [badgeText, badgeTone] = historyError ? ["Unavailable", "warn"] : !snapshot.preferences.history ? ["Off", "neutral"] :
    recording ? ["Recording", "ok"] : ["Waiting for a client", "neutral"];
  badge.textContent = badgeText;
  badge.className = `status-pill ${badgeTone}`;
  badge.title = historyError ?? (!snapshot.preferences.history ? "Usage history is off. Saved history is kept." :
    recording ? "Saving usage from connected clients." : "History is on. Connect the Copilot CLI or VS Code to start saving usage.");
  for (const control of document.querySelectorAll("[data-preference]")) {
    if (document.activeElement === control) continue;
    const key = control.dataset.preference;
    const value = snapshot.preferences[key];
    if (control.type === "checkbox") control.checked = value;
    else if (control.type === "time") control.value = `${String(Math.floor(value / 60)).padStart(2, "0")}:${String(value % 60).padStart(2, "0")}`;
    else control.value = value ?? "";
  }
  const executable = document.querySelector("#cli-executable");
  if (document.activeElement !== executable) executable.value = snapshot.preferences.cliExecutable ?? "";
  document.querySelector("#account-cli").textContent = snapshot.accountCli ? `Copilot CLI: ${snapshot.accountCli}` :
    "The official Copilot CLI is detected automatically when you sign in.";
  document.querySelector("#preview-widget").dataset.edge = snapshot.preferences.edge;
  document.querySelector("#preview-widget").hidden = !snapshot.preferences.widgetVisible;
  document.querySelector("#onboarding").hidden = snapshot.preferences.onboardingComplete;
  document.querySelector("#collection-state").textContent = snapshot.connections.cli || snapshot.connections.vscode ? "Collecting usage" : "Not collecting usage";
  for (const client of ["cli", "vscode"]) {
    const at = snapshot.delivery[client];
    const connected = Boolean(snapshot.connections[client]);
    const state = document.createElement("span");
    state.className = connected ? "connection-state connected" : "connection-state";
    state.textContent = connected ? "Connected" : "Not connected";
    document.querySelector(`#${client}-status`).replaceChildren(state,
      ` - ${at ? `Events received ${time(at)}` : "No events received"}. ${snapshot.connections[`${client}Error`] ?? ""}`);
    document.querySelector(`[data-connect="${client}"]`).textContent = `${connected ? "Repair" : "Connect"} ${client === "cli" ? "CLI" : "VS Code"}`;
  }
  const cliSamples = snapshot.samples.filter(sample => sample.source === "cli");
  const cliUsageAt = cliSamples.reduce((latest, sample) => Math.max(latest, sample.date), 0);
  document.querySelector("#cli-usage-status").textContent = `Model/token usage: ${cliSamples.length ?
    `${count(cliSamples.length)} retained ${cliSamples.length === 1 ? "call" : "calls"}; last received ${time(cliUsageAt)}.` :
    "No samples received. Lifecycle hooks alone do not report tokens or models."} ${cliReportingGap(snapshot)}`;
  document.querySelector("#vscode-result").textContent = `${vscodeSetupStatus(snapshot)} Copilot telemetry: ${
    snapshot.preferences.vscodeMetrics ? snapshot.delivery.vscodeLocal || snapshot.delivery.vscodeCopilot ? "Observations received" : "Waiting for data" : "Off"}.`;
  const pendingEditor = snapshot.connections.vscodeSetup?.canOpen === true;
  document.querySelector("#vscode-approve").hidden = !pendingEditor;
  document.querySelector("#vscode-insiders-approve").disabled = !pendingEditor;
  document.querySelector("#vscode-approve").textContent = snapshot.connections.vscodeSetup?.operation === "remove" ? "Continue removal in VS Code" : "Continue setup in VS Code";
  document.querySelector("#include-metrics").checked = editorMetricsChoice ?? (snapshot.connections.vscode ? snapshot.preferences.vscodeMetrics : true);
  document.querySelector("#usage-account-identity").textContent = accountIdentity(snapshot);
  document.querySelector("#usage-account-status").textContent = accountStatus(snapshot);
  for (const button of document.querySelectorAll("[data-account]")) {
    button.disabled = Boolean(snapshot.accountBusy) || button.dataset.account === "refresh" && !snapshot.preferences.accountEnabled;
  }
  document.querySelector('[data-account="signIn"]').hidden = snapshot.accountAuth?.status === "signedIn";
  document.querySelector('[data-account="signOut"]').textContent = snapshot.accountShared ? "Disconnect" : "Sign out";
  document.querySelector("#accountEnabled").disabled = Boolean(snapshot.accountBusy);
  document.querySelector("#cli-executable").disabled = Boolean(snapshot.accountBusy);
  document.querySelector("#choose-cli").disabled = Boolean(snapshot.accountBusy);
  document.querySelector("#health").textContent = snapshot.healthError ?? (snapshot.health ? `Copilot: ${snapshot.health.status}, observed ${time(snapshot.health.observedAt)}` : snapshot.healthBusy ? "Checking public incident records..." : "Not checked.");
  const delivery = snapshot.notificationDelivery;
  document.querySelector("#position").setAttribute("aria-valuetext",`${Math.round(snapshot.preferences.position*100)}% along the ${snapshot.preferences.edge} edge`);
  document.querySelector("#visual-preferences").textContent = snapshot.accessibilityError ?
    `${snapshot.accessibilityError} Use these controls to adjust text and effects.` :
    `Effective text size: ${Math.round(visuals.textScale*100)}%.${snapshot.accessibility ? " Includes the Windows text setting." : " Browser preview uses these controls."}`;
  document.querySelector("#visual-preferences").textContent += snapshot.preferences.reduceMotion ?
    " Animations, including working indicators, are disabled by Tokenotch's Reduce motion setting." :
    snapshot.accessibility?.animationsEnabled === false || window.matchMedia("(prefers-reduced-motion: reduce)").matches ?
      " Windows animation effects are off; Tokenotch still animates. Turn on Reduce motion to stop transitions and working indicators." :
      " Working animations are enabled.";
  document.querySelector("#notification-delivery").textContent = delivery?.observedAt ?
    `Last delivery attempt ${time(delivery.observedAt)}. Banner: ${delivery.desktop ?? "Not requested"}. Sound: ${delivery.sound ?? "Not requested"}. Card: ${delivery.card ?? "Not requested"}.` : "No notification delivery attempted.";
  document.querySelector("#notification-error").hidden = !snapshot.notificationError;
  document.querySelector("#notification-error").textContent = snapshot.notificationError ?? "";
  document.querySelector("#snoozed").textContent = snapshot.preferences.snoozedUntil > snapshot.now ? `Snoozed until ${time(snapshot.preferences.snoozedUntil)}` : "Not snoozed.";
  document.querySelector("#warning").hidden = !snapshot.warning;
  document.querySelector("#warning").textContent = snapshot.warning ?? "";
}
// Checks the sign-in now; failures surface through the account status line.
async function verifyAccount() {
  if (!bridge.native || !snapshot.preferences.accountEnabled || snapshot.accountBusy) return;
  snapshot = { ...snapshot, accountBusy: true };
  render();
  try { await bridge.account("refresh"); } catch { /* reported as accountError */ }
  finally { await refresh(); }
}
async function refresh() {
  snapshot = await bridge.snapshot();
  if (!widget && snapshot.archives) {
    if (insightGeneration && insightGeneration !== snapshot.archives.history) {
      insightGeneration = undefined;
      for (const key of detailTargets.keys()) if (key.startsWith("insight:")) detailTargets.delete(key);
    }
    if (timelineList && timelineList.status.generation !== snapshot.archives.timelines) {
      timelineList = undefined;
      html("timeline-results", '<p class="empty">Saved timelines were cleared. Browse again to see new observations.</p>');
    }
    if (activeDetail) {
      const generation = snapshot.archives[activeDetail.kind === "timeline" ? "timelines" : activeDetail.kind === "live" ? "live" : "history"];
      const expired = activeDetail.kind === "timeline" && activeDetail.data.events?.[0]?.timestamp < snapshot.archives.timelineCutoff;
      if (activeDetail.archiveId !== generation || expired) {
        activeDetail.data = {};
        html("detail-content", '<h1 tabindex="-1" id="detail-heading">Selected evidence unavailable</h1><p>This target was cleared or expired. Return to the original view and reload it.</p>');
      }
    }
  }
  widgetHistory = undefined;
  if (widget && widgetPeriod === "7" && typeof snapshot.today?.startedAt === "number") {
    const today = dayKey(snapshot.now, snapshot.today.timeZone);
    widgetHistory = await bridge.history(addDays(today, -6), today);
  }
  render();
  // New saved usage, deletion, a new reporting day or a recording change reloads the open period in place.
  if (!widget && currentPage === "history" && !activeDetail && !document.hidden &&
    historyLoadedKey !== undefined && historyLoadedKey !== historyReloadKey()) await loadHistory();
  if (!widget) document.querySelector("#runtime").textContent = runtimeDescription(await bridge.status());
}
action(async () => {
  await bridge.onStateChanged(() => { if (!document.querySelector("dialog[open]")) action(refresh, false); });
  if (widget) {
    await bridge.onFocusSummary(() => action(async () => { await refresh(); focusSummary(); }));
    await bridge.onDisplayChanged(() => { window.dispatchEvent(new window.Event("resize")); });
    await bridge.onWidgetExpansion(state => {
      if (!syncWidgetExpansion(state) || !snapshot) return;
      snapshot.widgetExpanded = state.expanded; snapshot.widgetAutomatic = state.automatic;
      snapshot.widgetVisible = state.visible; snapshot.widgetAlert = state.alert; snapshot.widgetAlertUntil = state.until; snapshot.widgetDismissed = state.dismissed;
      snapshot.widgetPinned = state.pinned; snapshot.widgetRevision = state.revision;
    });
  }
  if (!widget) {
    await bridge.onPage(page => { if (document.querySelector(`[data-page="${window.CSS.escape(String(page))}"]`)) showPage(page); });
    await bridge.onNotification(() => action(openNotificationTarget));
    await bridge.onDetail(() => action(async () => {
      const request = await bridge.takeDetail();
      if (request) await openDetail(request);
    }));
    await bridge.onNotice(id => action(async () => {
      showPage("sessions"); await refresh();
      const target = document.getElementById(`notice-${id}`);
      if (!target) throw new Error("This notification's session details are no longer available.");
      target.focus(); target.scrollIntoView({ block: "center" });
      await acknowledgeOpened(id);
    }));
    const displays = await bridge.displays();
    for (const display of displays) {
      const option = document.createElement("option");
      option.value = display.name; option.textContent = `${display.name} (${display.width} x ${display.height})`;
      document.querySelector("#display").append(option);
    }
  }
  await refresh();
  if (!widget) {
    if (currentPage === "history" && !historyView) await loadHistory();
    const request = await bridge.takeDetail();
    if (request) await openDetail(request);
    await openNotificationTarget();
  }
});
async function openNotificationTarget() {
  const target = await bridge.takeNotification();
  if (!target) return;
  showPage(target.kind === "notice" ? "sessions" : target.kind === "service" ? "notifications" : "usage");
  await refresh();
  const element = target.kind === "notice" ? document.getElementById(`notice-${target.id}`) :
    target.kind === "service" ? document.getElementById("health") : document.querySelector('[data-view="usage"] h1');
  if (!element) throw new Error("This notification target is no longer available.");
  element.tabIndex = -1; element.focus(); element.scrollIntoView({block:"center"});
  if (target.kind === "notice") await acknowledgeOpened(target.id);
}
// Opening a notice from its notification is a deliberate view: it clears the notch
// attention marker the same way closing a viewed summary card does.
async function acknowledgeOpened(id) {
  const notice = snapshot?.notices.find(notice => notice.id === id);
  if (!notice || notice.dismissed || notice.resolved) return;
  await bridge.acknowledge(id, notice.kind !== "stopped");
  await refresh();
}
window.setInterval(() => {
  if (!document.hidden && !document.querySelector("dialog[open]")) action(refresh, false);
}, 3000);
// The settings window is hidden rather than closed; catch up as soon as it is shown again.
if (!widget) document.addEventListener("visibilitychange", () => {
  if (!document.hidden && snapshot && !document.querySelector("dialog[open]")) action(refresh, false);
});
