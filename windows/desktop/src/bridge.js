import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { product } from "./product.js";
import { validateEdge, validateStatus } from "./state.js";

const native = isTauri();
let previewEdge = "right";
let previewVisible = true;
let previewPreferences = {
  edge: "right", widgetVisible: true, collapseIdle: true, autoHideNotch: false, hideFullscreen: true,
  display: null, allDisplays: false, position: 0.5, scale: 1, timeFormat: "24", history: false, timelines: false,
  textScale: 1, reduceMotion: false, reduceTransparency: false,
  retentionDays: 7, rememberNotices: false, notifications: false, muteNotifications: false, desktopBanner: true,
  sound: false, expandCard: false, notifyStopped: true, notifyErrors: true,
  notifyRequests: false, notifyContext: false, notifyIncidents: false, notifyRecovery: false,
  quietHours: false, quietStart: 1320, quietEnd: 480,
  snoozedUntil: 0, serviceHealth: false, vscodeMetrics: false, accountEnabled: false,
  cliExecutable: null, onboardingComplete: false,
};

function requireNative() {
  if (!native) throw new Error("This is a browser preview. Use the Windows application for connections and saved data.");
}

export const bridge = {
  native,
  async status() {
    return validateStatus(native ? await invoke("runtime_status") : {
      version: product.version,
      channel: product.channel,
      runtime: { platform: "browser", executableArchitecture: "not-applicable", windowsBuild: null },
      minimumWindowsBuild: product.minimumWindowsBuild,
      connectionsEnabled: false,
      edge: previewEdge,
      widgetVisible: previewVisible,
    });
  },
  async setEdge(edge) {
    validateEdge(edge);
    if (native) await invoke("set_edge", { edge });
    else previewEdge = edge;
  },
  async setVisible(visible) {
    if (typeof visible !== "boolean") throw new Error("Widget visibility must be a Boolean.");
    if (native) await invoke("set_widget_visible", { visible });
    else previewVisible = visible;
  },
  async setExpanded(expanded, dismiss = false, pinned = false, restoreFocus = false) {
    if (native) await invoke("set_expanded", { expanded, dismiss, pinned, restoreFocus });
  },
  async showSummary() { requireNative(); await invoke("show_summary"); },
  async onFocusSummary(callback) { if (native) await listen("focus-summary",callback); },
  async onDisplayChanged(callback) { if (native) await listen("display-changed",callback); },
  // Clips the native window's hit region to the drawn shape so transparent
  // corners, flares and the space around the card tail pass clicks through.
  async setRegion(polygons, geometry = null, viewport = [window.innerWidth,window.innerHeight,window.devicePixelRatio]) {
    if (native) return invoke("set_region", { polygons: polygons.map(points => points.map(([x, y]) => [x, y])),
      viewport,geometry });
    return true;
  },
  async setCardHeight(height) {
    if (native) await invoke("set_card_height", { height });
  },
  async pointerLeft() {
    if (native) await invoke("pointer_left");
  },
  async pointerEngaged() { return native ? invoke("pointer_engaged") : false; },
  async openSettings(page = null) {
    if (native) await invoke("open_settings", { page });
    else window.location.search = page ? `?page=${encodeURIComponent(page)}` : "";
  },
  async onPage(callback) { if (native) await listen("page-selected", event => callback(event.payload)); },
  async snapshot() {
    if (native) return invoke("app_snapshot");
    return { preferences: previewPreferences, sessions: [], samples: [], partial: false,
      notices: [], connections: { cli: false, vscode: false }, delivery: {}, receiverRunning: false,
      account: null, accountError: null, warning: null, today: null, now: Date.now() };
  },
  async preferences(preferences) {
    if (native) await invoke("set_preferences", { preferences });
    else {
      if (preferences.onboardingComplete) throw new Error("Configure a client in the Windows application before finishing setup.");
      previewPreferences = preferences;
      previewEdge = preferences.edge;
      previewVisible = preferences.widgetVisible;
    }
  },
  async displays() { return native ? invoke("displays") : []; },
  async connection(source, operation, metrics = false) {
    requireNative();
    await invoke("connection", { source, operation, metrics });
  },
  async account(operation) { requireNative(); await invoke("account_action", { operation }); },
  async history(start, end, model = null) { requireNative(); return invoke("history", { start, end, model }); },
  async timelines(session = null) { requireNative(); return invoke("timelines", { session }); },
  async timelineSessions() { requireNative(); return invoke("timeline_sessions"); },
  async timelineDetail(session, source = null) { requireNative(); return invoke("timeline_detail", { session, source }); },
  async openDetail(request) {
    if (native) return invoke("open_detail", { request });
    window.sessionStorage.setItem("tokenotch-preview-detail", JSON.stringify(request));
    window.location.search = "";
  },
  async takeDetail() {
    if (native) return invoke("take_detail");
    const value = window.sessionStorage.getItem("tokenotch-preview-detail");
    window.sessionStorage.removeItem("tokenotch-preview-detail");
    return value ? JSON.parse(value) : null;
  },
  async onDetail(callback) { if (native) await listen("detail-selected", callback); },
  async clear(kind) { requireNative(); await invoke("clear_data", { kind }); },
  async acknowledge(id, dismiss) { requireNative(); await invoke("acknowledge", { id, dismiss }); },
  async health() { requireNative(); await invoke("check_health"); },
  async notificationStatus() { requireNative(); return invoke("notification_status"); },
  async testNotification() { requireNative(); return invoke("test_notification"); },
  async openNotification(target) { requireNative(); return invoke("open_notification", {target}); },
  async takeNotification() { return native ? invoke("take_notification") : null; },
  async onNotification(callback) { if (native) await listen("notification-selected",callback); },
  async onWidgetExpansion(callback) { if (native) await listen("widget-expansion",event => callback(event.payload)); },
  async link(target) { requireNative(); await invoke("open_link", { target }); },
  async companion() { requireNative(); return invoke("companion_path"); },
  async installCompanion() { requireNative(); return invoke("install_companion"); },
  async chooseFile(kind) { requireNative(); return invoke("choose_file", { kind }); },
  async previewImport(path) { requireNative(); return invoke("preview_import", { path }); },
  async commitImport(fingerprint) { requireNative(); return invoke("commit_import", { fingerprint }); },
  async onNotice(callback) { if (native) await listen("notice-selected", event => callback(event.payload)); },
  async onStateChanged(callback) { if (native) await listen("state-changed", callback); },
};
