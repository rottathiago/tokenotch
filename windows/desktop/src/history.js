// Period math and labels for the History page, mirroring macOS HistoryCalendar /
// UsageHistoryView. Intervals are half-open [start, end) reporting-day keys
// (YYYY-MM-DD) in the archive's fixed reporting time zone.

export const HISTORY_RANGES = [
  ["today", "Today"], ["week", "Last 7 days"], ["days30", "Last 30 days"], ["month", "This month"],
  ["previousMonth", "Previous month"], ["day", "Choose day"], ["chosenMonth", "Choose month"],
];
export const DEFAULT_RANGE = "days30";
const MONTHLY = new Set(["month", "previousMonth", "chosenMonth"]);

const utc = key => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(key ?? "")) throw new Error("Choose a valid history day.");
  const value = new Date(`${key}T12:00:00Z`);
  if (Number.isNaN(value.getTime()) || value.toISOString().slice(0, 10) !== key) throw new Error("Choose a valid history day.");
  return value;
};
export function addDays(key, days) {
  const value = utc(key);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}
const monthStart = key => `${key.slice(0, 7)}-01`;
function addMonths(key, months) {
  const value = utc(monthStart(key));
  value.setUTCMonth(value.getUTCMonth() + months);
  return value.toISOString().slice(0, 10);
}
const monthOf = key => ({ start: monthStart(key), end: addMonths(key, 1) });

export function dayCount(interval) {
  return Math.max(0, Math.round((utc(interval.end) - utc(interval.start)) / 86400000));
}
export function dayKeys(interval) {
  return Array.from({ length: dayCount(interval) }, (_, index) => addDays(interval.start, index));
}
export const isMonthly = range => MONTHLY.has(range);

export function periodInterval(range, selected, today) {
  switch (range) {
    case "today": return { start: today, end: addDays(today, 1) };
    case "week": return { start: addDays(today, -6), end: addDays(today, 1) };
    case "days30": return { start: addDays(today, -29), end: addDays(today, 1) };
    case "month": return monthOf(today);
    case "previousMonth": return monthOf(addMonths(today, -1));
    case "day": return { start: selected, end: addDays(selected, 1) };
    case "chosenMonth": return monthOf(selected);
    default: throw new Error("Unsupported history period.");
  }
}
export function priorInterval(range, interval, comparison, today) {
  if (range === "day" || range === "chosenMonth") return periodInterval(range, comparison, today);
  if (isMonthly(range)) return monthOf(addMonths(interval.start, -1));
  return { start: addDays(interval.start, -dayCount(interval)), end: interval.start };
}
// Compares completed days only: an unfinished current period is trimmed, and the
// prior period is trimmed to the same number of days.
export function completedComparison(left, right, today, monthly = false) {
  if (monthly && left.start === today && left.end > today) {
    return [{ start: today, end: today }, { start: right.start, end: right.start }];
  }
  if (!(left.end > today && left.start < today)) return [left, right];
  const count = Math.min(dayCount({ start: left.start, end: today }), dayCount(right));
  const previous = monthly ? { start: right.start, end: addDays(right.start, count) } :
    { start: addDays(right.end, -count), end: right.end };
  return [{ start: left.start, end: addDays(left.start, count) }, previous];
}
// The page's day count stops at today, so partially elapsed periods average over elapsed days.
export function elapsedDays(interval, today) {
  const end = interval.end < addDays(today, 1) ? interval.end : addDays(today, 1);
  return Math.max(dayCount({ start: interval.start, end }), 1);
}

const format = (key, options) => new Intl.DateTimeFormat(undefined, { ...options, timeZone: "UTC" }).format(utc(key));
export function periodTitle(interval) {
  if (dayCount(interval) <= 1) return format(interval.start, { weekday: "long", month: "long", day: "numeric" });
  return `${format(interval.start, { month: "short", day: "numeric" })} \u2013 ${format(addDays(interval.end, -1), { month: "short", day: "numeric", year: "numeric" })}`;
}
export function shortPeriod(interval) {
  const days = dayCount(interval);
  if (!days) return "\u2014";
  const short = key => format(key, { month: "short", day: "numeric" });
  return days === 1 ? short(interval.start) : `${short(interval.start)}\u2013${short(addDays(interval.end, -1))}`;
}
export const dayLabel = key => format(key, { weekday: "short", month: "short", day: "numeric" });

export function percentage(current, baseline) {
  return baseline > 0 ? (current - baseline) / baseline * 100 : null;
}
export function formatChange(value) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "\u2014";
  return `${value >= 0 ? "+" : "-"}${Math.abs(value).toFixed(1)}%`;
}
export function latency(milliseconds) {
  if (milliseconds === null || milliseconds === undefined || !Number.isFinite(milliseconds)) return "\u2014";
  if (milliseconds >= 1000) return `${(milliseconds / 1000).toFixed(milliseconds >= 10000 ? 0 : 1)} s`;
  return `${Math.round(milliseconds)} ms`;
}
export const meanFirstToken = usage => usage.firstTokenSamples ? usage.firstTokenMs / usage.firstTokenSamples : null;
export const meanDuration = usage => usage.durationSamples ? usage.durationMs / usage.durationSamples : null;
export function recordedDuration(seconds) {
  const minutes = Math.floor(seconds / 60);
  return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}
export function modelTitle(model) {
  if (!model) return "Model unavailable";
  return model === "Other models (capacity limit)" ? "Other models (detail limit)" : model;
}

// Weekly insight headlines, in macOS order.
const INSIGHT_ORDER = ["Model mix", "First-token latency", "Call duration", "Compaction frequency"];
export function insightHeadline(item) {
  if (!item.available) return `${item.label}: comparison unavailable`;
  if (item.label === "Model mix") {
    const changes = (item.changes ?? []).filter(change => change.previous !== null && change.current !== null);
    const top = changes.sort((a, b) => Math.abs(b.current - b.previous) - Math.abs(a.current - a.previous))[0];
    if (!top) return `${item.label}: comparison unavailable`;
    const difference = top.current - top.previous;
    return `Observed ${modelTitle(top.model)} call share ${difference > 0 ? "increased" : difference < 0 ? "decreased" : "unchanged"}`;
  }
  if (item.previous === null || item.current === null) return `${item.label}: comparison unavailable`;
  const difference = item.current - item.previous;
  return `Observed ${item.label.toLowerCase()} ${difference > 0 ? "increased" : difference < 0 ? "decreased" : "unchanged"}`;
}
export const orderedInsights = items => [...items].sort((a, b) => INSIGHT_ORDER.indexOf(a.label) - INSIGHT_ORDER.indexOf(b.label));
