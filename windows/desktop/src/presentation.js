// Card presentation rules ported from sources/Notch/NotchPresentation.swift.
import { total, compact } from "./usage.js";

export { compact };
export const WATCH_THRESHOLD = 0.75;
export const EXHAUSTED_THRESHOLD = 0.9;
export const palette = Object.freeze({
  primary: "#ffffff", secondary: "#a6a6a6", ringTrack: "#303030", barTrack: "#2d2d2d",
  ample: "#00ff88", watch: "#f2ff00", exhausted: "#ff3f00",
  working: "#58a6ff", stopped: "#bc8cff", warning: "#e3b341", error: "#ff7b72",
  input: "#79b8ff", output: "#56d4dd", cacheRead: "#bea0ff", cacheWrite: "#ffa680",
});

export function usageLevel(fraction) {
  return fraction >= EXHAUSTED_THRESHOLD ? "exhausted" : fraction >= WATCH_THRESHOLD ? "watch" : "ample";
}
export const usageColor = fraction => palette[usageLevel(fraction)];
// The arc changes texture as well as colour so the reading survives a display
// that renders the three states as near-identical greys.
export function usageDash(fraction) {
  if (fraction >= EXHAUSTED_THRESHOLD) return [2.5, 2.5];
  if (fraction >= WATCH_THRESHOLD) return [6, 3];
  return [];
}

export function calls(value) {
  return `${new Intl.NumberFormat().format(value)} ${value === 1 ? "call" : "calls"}`;
}
export function relative(at, now) {
  const delta = (at - now) / 1000;
  const seconds = Math.abs(delta);
  if (seconds < 1) return "just now";
  const [amount, unit] = seconds < 60 ? [Math.floor(seconds), "s"] : seconds < 3600 ? [Math.floor(seconds / 60), "m"] :
    seconds < 86400 ? [Math.floor(seconds / 3600), "h"] : [Math.floor(seconds / 86400), "d"];
  return delta < 0 ? `${amount}${unit} ago` : `in ${amount}${unit}`;
}
export const percent = fraction => `${Math.round(fraction * 100)}%`;

export const signals = Object.freeze({
  error: { priority: 0, color: palette.error, label: "Error" },
  input: { priority: 1, color: palette.warning, label: "Input requested" },
  approval: { priority: 1, color: palette.warning, label: "Approval requested" },
  warning: { priority: 2, color: palette.warning, label: "Warning" },
  stopped: { priority: 3, color: palette.stopped, label: "Stopped" },
  working: { priority: 4, color: palette.working, label: "Working" },
  unknown: { priority: 5, color: palette.secondary, label: "Unknown" },
  idle: { priority: 6, color: palette.secondary, label: "Idle" },
});
const noticeSignal = { error: "error", inputRequested: "input", approvalRequested: "approval",
  compactionFailed: "warning", highContext: "warning", stopped: "stopped" };
export const noticeTitles = { error: "Session reported an error", inputRequested: "Input requested",
  approvalRequested: "Approval requested", compactionFailed: "Compaction failed", highContext: "High context reported",
  stopped: "Execution stopped" };
const noticeOrder = { error: 0, inputRequested: 1, approvalRequested: 1, compactionFailed: 2, highContext: 2, stopped: 3 };
export const isRequest = kind => kind === "inputRequested" || kind === "approvalRequested";
export const noticeNeedsHighlight = notice => !notice.dismissed && !notice.resolved && !(notice.kind === "stopped" && notice.viewed);
export const clientLabel = (source, id) => `${source === "cli" ? "CLI" : "VS Code"} ${String(id).slice(0, 6)}`;

const lifecycleKinds = new Set(["started", "working", "active", "idle"]);
// Matches the Rust Session::is_fresh limits that produce "No recent activity updates".
export function hasMissingActivity(session, now) {
  const limit = session.kind === "active" || session.kind === "idle" ? 90000 : 300000;
  return lifecycleKinds.has(session.kind) && now - session.observedAt > limit;
}

export function sessionRows(snapshot) {
  const now = snapshot.now;
  const rows = [];
  for (const notice of (snapshot.notices ?? []).filter(noticeNeedsHighlight)) {
    const stale = notice.restored || now - notice.timestamp > 300000;
    rows.push({ key: `notice:${notice.id}`, signal: noticeSignal[notice.kind] ?? "warning", notice,
      label: clientLabel(notice.source, notice.session), title: noticeTitles[notice.kind] ?? "Session notice",
      detail: `Last reported ${relative(notice.timestamp, now)}${stale ? "; stale" : ""}${isRequest(notice.kind) ? "; response unknown" : ""}`,
      date: notice.timestamp, unseen: !notice.viewed, order: noticeOrder[notice.kind] ?? 4 });
  }
  for (const session of snapshot.sessions ?? []) {
    let signal, title, detail;
    if (session.working) {
      const seconds = Math.max(0, Math.floor((now - (session.workStartedAt ?? session.observedAt)) / 1000));
      signal = "working"; title = "Working";
      detail = seconds < 60 ? `Observed for ${seconds}s` : `Observed for ${Math.floor(seconds / 60)}m`;
    } else if (hasMissingActivity(session, now)) {
      signal = "unknown"; title = "Activity updates missing"; detail = `Last reported ${relative(session.observedAt, now)}`;
    } else if (session.kind === "idle" || session.kind === "started") {
      signal = session.kind === "idle" ? "idle" : "unknown";
      title = session.kind === "idle" ? "Idle" : "Awaiting activity report";
      detail = `Last reported ${relative(session.observedAt, now)}`;
    } else continue;
    rows.push({ key: `session:${session.source}:${session.id}`, signal, session, label: clientLabel(session.source, session.id),
      title, detail, date: session.observedAt, unseen: false, order: 9 });
  }
  return rows.sort((a, b) => signals[a.signal].priority - signals[b.signal].priority ||
    Number(b.unseen) - Number(a.unseen) || a.order - b.order || b.date - a.date || a.key.localeCompare(b.key));
}

export function staleSessionCount(snapshot) {
  return (snapshot.sessions ?? []).filter(session => hasMissingActivity(session, snapshot.now)).length;
}

export function activityTitle(snapshot, rows = sessionRows(snapshot)) {
  const count = signal => rows.filter(row => signal.includes(row.signal)).length;
  const working = (snapshot.sessions ?? []).filter(session => session.working).length;
  const errors = count(["error"]);
  if (errors) return `${errors} ${errors === 1 ? "session reported an error" : "sessions reported errors"}`;
  const requests = count(["input", "approval"]);
  if (requests) return `${requests} ${requests === 1 ? "session requested attention" : "sessions requested attention"}`;
  const warnings = count(["warning"]);
  if (warnings) return `${warnings} ${warnings === 1 ? "session has a warning" : "sessions have warnings"}`;
  const stopped = count(["stopped"]);
  if (stopped) return `${stopped} ${stopped === 1 ? "session stopped" : "sessions stopped"}${working ? `; ${working} working` : ""}`;
  if (working) return `${working} working`;
  if (!(snapshot.sessions ?? []).length) return "No recent activity observed";
  if (staleSessionCount(snapshot)) return "Activity updates missing";
  if (snapshot.sessions.some(session => session.kind === "started")) return "Awaiting activity report";
  return "No work currently reported";
}

export function sessionSignal(snapshot, rows = sessionRows(snapshot)) {
  return rows[0]?.signal ?? (staleSessionCount(snapshot) ? "unknown" : "idle");
}

export function quotaTitle(quota) {
  return ({ premium_interactions: "Premium requests", chat: "Chat requests", completions: "Completions" })[quota.id] ??
    `Runtime quota (${quota.id})`;
}
export function primaryQuota(account) {
  const quotas = account?.quotas ?? [];
  return quotas.find(quota => quota.id === "premium_interactions") ?? quotas.find(quota => !quota.isUnlimitedEntitlement) ?? quotas[0] ?? null;
}
export function usedFraction(account) {
  const quota = primaryQuota(account);
  if (!quota || quota.isUnlimitedEntitlement) return null;
  return Math.min(Math.max(1 - quota.remainingPercentage / 100, 0), 1);
}
export function accountStale(snapshot) {
  return Boolean(snapshot.account) && (snapshot.now - snapshot.account.observedAt > 120000 || Boolean(snapshot.accountError));
}
/** A sign-in check is running and no account has been confirmed yet (e.g. right after launch). */
export function accountChecking(snapshot) {
  return Boolean(snapshot.accountBusy) && Boolean(snapshot.preferences?.accountEnabled) && !snapshot.account &&
    (snapshot.accountAuth?.status ?? "unknown") === "unknown";
}
export function accountStatus(snapshot) {
  if (snapshot.accountBusy) return "Account operation in progress...";
  if (snapshot.accountError) return snapshot.accountError;
  const via = snapshot.accountShared ? " Using your Copilot CLI sign-in." : "";
  if (snapshot.account) return snapshot.account.quotas.length ?
    `Account quota connected.${via}` : `Signed in, but GitHub reported no account quota.${via}`;
  if (!snapshot.preferences.accountEnabled) return "Account quota is off. Sign in with GitHub to show your Copilot plan quota.";
  return "Sign in with GitHub to show your Copilot plan quota. Your existing Copilot CLI sign-in is used when available.";
}
export function accountIdentity(snapshot) {
  const auth = snapshot.accountAuth;
  if (auth?.status === "signedIn") return `Signed in as @${auth.login}`;
  if (auth?.status === "signedOut") return "Signed out of GitHub";
  if (snapshot.account) return `${auth?.status === "unknown" ? "Last signed in" : "Signed in"} as @${snapshot.account.login}`;
  if (accountChecking(snapshot)) return "Checking GitHub sign-in...";
  return snapshot.preferences.accountEnabled ? "Sign-in status not yet verified" : "GitHub account not connected";
}
export function vscodeSetupStatus(snapshot) {
  const setup = snapshot.connections.vscodeSetup;
  if (setup?.status === "pending") return `Waiting for approval in VS Code. Approve the ${setup.operation === "remove" ? "removal" : "setup"} request in the profile you use.`;
  if (setup?.status === "expired") return "VS Code approval expired. Select Connect VS Code again, then approve in the editor.";
  if (setup?.status === "interrupted") return "VS Code approval was interrupted. Select Connect VS Code again.";
  return snapshot.connections.vscodeResult?.message ?? (snapshot.connections.vscode ?
    "VS Code profile settings are configured. Reload the editor and check event delivery." :
    "VS Code is not connected. Select Connect VS Code to install the companion and approve it in the editor.");
}
export function quotaWarning(snapshot) {
  if (!snapshot.account || accountStale(snapshot)) return null;
  const finite = snapshot.account.quotas.filter(quota => !quota.isUnlimitedEntitlement);
  const exhausted = finite.find(quota => quota.remainingPercentage === 0);
  if (exhausted) return `${quotaTitle(exhausted)}: reported allowance exhausted`;
  const low = finite.find(quota => quota.remainingPercentage <= (1 - WATCH_THRESHOLD) * 100);
  return low ? `${quotaTitle(low)}: near reported limit` : null;
}
export function reportedReset(quota, now) {
  if (!quota?.resetDate) return null;
  const at = Date.parse(quota.resetDate);
  return Number.isFinite(at) && at > now ? at : null;
}
export function headlineLevel(snapshot) {
  if (accountStale(snapshot)) return "stale";
  const used = usedFraction(snapshot.account);
  return used === null || used < WATCH_THRESHOLD ? "plain" : usageLevel(used);
}

export function needsAttention(snapshot) {
  return (snapshot.notices ?? []).some(notice => notice.kind !== "stopped" && noticeNeedsHighlight(notice)) ||
    healthIncident(snapshot) || quotaWarning(snapshot) !== null;
}
export function healthIncident(snapshot) {
  const health = snapshot.health;
  return Boolean(health) && health.activeIncidents > 0 &&
    typeof health.observedAt === "number" && snapshot.now - health.observedAt <= 300000;
}

// The ring's corner badge: errors first, then attention, then any non-idle signal.
export function ringIndicator(snapshot) {
  const signal = sessionSignal(snapshot);
  if (signal === "error") return "error";
  if (needsAttention(snapshot)) return "warning";
  if (signal !== "idle") return signal;
  return (snapshot.sessions ?? []).some(session => session.working) ? "working" : "idle";
}

export function ringReading(snapshot) {
  const quota = primaryQuota(snapshot.account);
  const fraction = usedFraction(snapshot.account);
  const stale = accountStale(snapshot);
  const working = (snapshot.sessions ?? []).some(session => session.working);
  const label = fraction !== null ? percent(fraction) : quota?.isUnlimitedEntitlement ? "\u221E" : "\u2014";
  const usage = fraction !== null ? `${Math.round(fraction * 100)} percent used` :
    quota?.isUnlimitedEntitlement ? "Unlimited entitlement" : "Quota unavailable";
  const indicator = ringIndicator(snapshot);
  return { fraction, stale, working, label, indicator,
    accessibilityValue: `${usage}${stale ? ", stale" : ""}${working ? ", working (last reported)" : ""}${needsAttention(snapshot) ? ", attention needed" : ""}` };
}

export function cacheState(usage, write = false) {
  const reported = usage[write ? "writeReportedCalls" : "cacheReportedCalls"] ?? 0;
  const unreported = usage[write ? "writeUnreportedCalls" : "cacheUnreportedCalls"] ?? 0;
  const tokens = usage[write ? "cacheWrite" : "cacheInput"] ?? 0;
  if (!usage.calls) return "noSamples";
  if (reported === usage.calls) return "reported";
  if (unreported === usage.calls) return "notReported";
  if (reported > 0 || tokens > 0) return "partial";
  return "unknown";
}
export function cacheDisplay(usage, write = false) {
  const state = cacheState(usage, write);
  if (state === "noSamples") return "-";
  if (state === "notReported") return "n/r";
  if (state === "unknown") return "?";
  return compact(usage[write ? "cacheWrite" : "cacheInput"]) + (state === "partial" ? "*" : "");
}
export function breakdownIncomplete(usage) {
  return usage.calls > 0 && ((usage.cacheReportedCalls ?? 0) < usage.calls || (usage.writeReportedCalls ?? 0) < usage.calls);
}
// The asterisk always sits on the number, as it does on partial cache counts.
export function inputDisplay(usage) {
  return compact(usage.input) + (breakdownIncomplete(usage) ? "*" : "");
}

const isNamed = group => group.model !== "" && group.model !== "*";
// Top three named models by tokens, then everything else folded into one row,
// unless the reader asked for all of them.
export function modelRows(groups, expanded = false) {
  const named = groups.filter(isNamed).sort((a, b) => total(b.usage) - total(a.usage) || a.model.localeCompare(b.model));
  const rows = (expanded ? named : named.slice(0, 3)).map(group => ({ ...group, title: group.model }));
  const shown = new Set(rows.map(row => row.model));
  const rest = groups.filter(group => !shown.has(group.model) || !isNamed(group));
  if (rest.length) {
    const usage = {};
    for (const group of rest) for (const [key, value] of Object.entries(group.usage)) usage[key] = (usage[key] ?? 0) + value;
    rows.push({ model: null, usage, title: rest.some(group => !isNamed(group)) ? "Other / unavailable models" : "Remaining models" });
  }
  return rows;
}
export const canExpandModels = groups => groups.filter(isNamed).length > 3;

export function provenance({ saved, recording, partial }) {
  if (saved) return recording ? "Usage data saved locally" : "Saved locally; recording paused";
  return partial ? "Live only; sample limit reached" : "Live usage only; not saved";
}

export function contextReading(session, now) {
  const context = session?.context?.context;
  if (!context || !context.tokenLimit) return null;
  const fraction = context.currentTokens / context.tokenLimit;
  return { fraction, stale: now - session.context.observedAtUnixMs > 300000,
    currentTokens: context.currentTokens, tokenLimit: context.tokenLimit, observedAt: session.context.observedAtUnixMs };
}
