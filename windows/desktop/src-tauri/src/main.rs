#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tauri::{
    image::Image,
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, State, WebviewWindow, WindowEvent,
};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;
use tokenotch_core::{
    hook::{Source, UsageSource},
    placement::{card_frame, notch_size, place_at, recover_window, ring_center, Edge, Rect},
    product,
};
use tokenotch_platform::{
    desktop::{self, CardState, Channel},
    display::{physical_region, region_contains, DisplayRegistry},
    navigation::{DetailInbox, DetailRequest},
    notifications::{Alert, Delivery, Target},
    preferences::Preferences,
    runtime::{self, Runtime, Shared},
    storage::{home, Result, Store},
    transport::now_ms,
};

/// Native placement for one display's notch and its summary card.
#[derive(Clone, Default)]
struct CardLayout {
    /// Natural card height in CSS pixels, as measured by the card itself.
    height: f64,
    open: bool,
    notch: Option<Rect>,
    card: Option<Rect>,
    bridge: Option<Rect>,
    geometry: Value,
    /// The card's last requested hit region, applied whenever it opens.
    polygons: Vec<Vec<(i32, i32)>>,
    region_size: Option<PhysicalSize<u32>>,
    region_scale: f64,
    notch_polygons: Vec<Vec<(i32, i32)>>,
    polling: bool,
}
impl CardLayout {
    fn contains(&self, x: f64, y: f64) -> bool {
        self.notch
            .is_some_and(|rect| region_contains(&self.notch_polygons, x - rect.x, y - rect.y))
            || self.open
                && (self
                    .card
                    .is_some_and(|rect| region_contains(&self.polygons, x - rect.x, y - rect.y))
                    || self.bridge.is_some_and(|rect| rect.contains(x, y)))
    }
    /// Pointer over the drawn notch or open card, as macOS NotchFleet counts engagement;
    /// the hover bridge between them is excluded.
    fn engaged(&self, x: f64, y: f64) -> bool {
        self.notch
            .is_some_and(|rect| region_contains(&self.notch_polygons, x - rect.x, y - rect.y))
            || self.open
                && self
                    .card
                    .is_some_and(|rect| region_contains(&self.polygons, x - rect.x, y - rect.y))
    }
}

struct AppState {
    runtime: Shared,
    expanded: Mutex<BTreeMap<String, CardState>>,
    /// Orders card-state presentations so a snapshot started before a fold
    /// cannot overwrite the newer folded state when it arrives later.
    revision: AtomicU64,
    layouts: Mutex<BTreeMap<String, CardLayout>>,
    detail: Mutex<DetailInbox>,
    notification_target: Mutex<Option<(f64, Target)>>,
    displays: Mutex<DisplayRegistry>,
    work_areas: Mutex<Vec<Rect>>,
    focus_return: Mutex<BTreeMap<String, isize>>,
}

const SETTINGS_PAGES: [&str; 8] = [
    "usage",
    "history",
    "sessions",
    "connections",
    "notifications",
    "general",
    "privacy",
    "about",
];

/// Each display has a notch window (`widget`, `widget-1`, ...) and a summary
/// card window (`card`, `card-1`, ...). Card state is keyed by the notch label.
fn is_notch(label: &str) -> bool {
    label == "widget" || label.starts_with("widget-")
}
fn is_card(label: &str) -> bool {
    label == "card" || label.starts_with("card-")
}
fn display_label(label: &str) -> String {
    if is_card(label) {
        format!("widget{}", &label["card".len()..])
    } else {
        label.to_owned()
    }
}
fn card_label(label: &str) -> String {
    format!("card{}", &label["widget".len()..])
}

fn window(app: &AppHandle, label: &str) -> Result<WebviewWindow> {
    app.get_webview_window(label)
        .ok_or("The requested Tokenotch window is unavailable.".into())
}

#[cfg(windows)]
fn apply_region(window: &WebviewWindow, polygons: &[Vec<(i32, i32)>]) -> Result<()> {
    let hwnd = window
        .hwnd()
        .map_err(|_| "The widget window handle is unavailable.")?;
    desktop::set_window_region(hwnd.0 as isize, polygons)
}
#[cfg(not(windows))]
fn apply_region(_: &WebviewWindow, _: &[Vec<(i32, i32)>]) -> Result<()> {
    Ok(())
}
fn show_passive(window: &WebviewWindow) -> Result<()> {
    // Keep Tauri's visibility state synchronized so later keyboard focus works.
    window
        .show()
        .map_err(|_| "Widget could not be shown.".into())
}

fn monitor_id(monitor: &tauri::Monitor) -> String {
    monitor.name().cloned().unwrap_or_else(|| {
        format!(
            "display:{}:{}:{}:{}",
            monitor.position().x,
            monitor.position().y,
            monitor.size().width,
            monitor.size().height
        )
    })
}
fn monitor_work(monitor: &tauri::Monitor) -> Rect {
    let work = monitor.work_area();
    Rect {
        x: f64::from(work.position.x),
        y: f64::from(work.position.y),
        width: f64::from(work.size.width),
        height: f64::from(work.size.height),
    }
}
fn recover_settings(app: &AppHandle, force: bool) -> Result<()> {
    let state = app.state::<AppState>();
    let mut monitors = app
        .available_monitors()
        .map_err(|_| "Display information is unavailable.")?;
    let primary = app
        .primary_monitor()
        .map_err(|_| "The primary display is unavailable.")?
        .map(|monitor| monitor_id(&monitor));
    monitors.sort_by_key(|monitor| (Some(monitor_id(monitor)) != primary, monitor_id(monitor)));
    let works: Vec<_> = monitors.iter().map(monitor_work).collect();
    if !force
        && *state
            .work_areas
            .lock()
            .map_err(|_| "Display state is unavailable.")?
            == works
    {
        return Ok(());
    }
    let settings = window(app, "settings")?;
    let position = settings
        .outer_position()
        .map_err(|_| "Settings position is unavailable.")?;
    let size = settings
        .outer_size()
        .map_err(|_| "Settings size is unavailable.")?;
    let frame = Rect {
        x: f64::from(position.x),
        y: f64::from(position.y),
        width: f64::from(size.width),
        height: f64::from(size.height),
    };
    let recovered =
        recover_window(frame, &works).ok_or("No usable display is available for Settings.")?;
    let inner = settings
        .inner_size()
        .map_err(|_| "Settings size is unavailable.")?;
    let factor = settings
        .scale_factor()
        .map_err(|_| "Settings display scale is unavailable.")?;
    let width = (recovered.width - f64::from(size.width.saturating_sub(inner.width)))
        .max(1.0)
        .floor() as u32;
    let height = (recovered.height - f64::from(size.height.saturating_sub(inner.height)))
        .max(1.0)
        .floor() as u32;
    settings
        .set_min_size(Some(PhysicalSize::new(
            width.min((640.0 * factor) as u32),
            height.min((480.0 * factor) as u32),
        )))
        .map_err(|_| "Settings minimum size could not be updated.")?;
    if recovered.width != frame.width || recovered.height != frame.height {
        settings
            .set_size(PhysicalSize::new(width, height))
            .map_err(|_| "Settings could not be resized into its work area.")?;
    }
    if recovered.x != frame.x || recovered.y != frame.y {
        settings
            .set_position(PhysicalPosition::new(
                recovered.x.ceil() as i32,
                recovered.y.ceil() as i32,
            ))
            .map_err(|_| "Settings could not be recovered onto a display.")?;
    }
    *state
        .work_areas
        .lock()
        .map_err(|_| "Display state is unavailable.")? = works;
    Ok(())
}

fn focus_card(app: &AppHandle, label: &str) -> Result<()> {
    if !window(app, label)?
        .is_visible()
        .map_err(|_| "Widget visibility unavailable.")?
    {
        return Err("The summary is unavailable while its widget is hidden.".into());
    }
    let card = window(app, &card_label(label))?;
    if !card
        .is_focused()
        .map_err(|_| "Card focus is unavailable.")?
    {
        if let Some(previous) = desktop::foreground_window() {
            app.state::<AppState>()
                .focus_return
                .lock()
                .map_err(|_| "Focus state is unavailable.")?
                .insert(label.into(), previous);
        }
    }
    card.set_focusable(true)
        .map_err(|_| "The summary card could not receive keyboard focus.")?;
    card.set_focus()
        .map_err(|_| "The summary card could not receive keyboard focus.")?;
    app.emit_to(card.label(), "focus-summary", ())
        .map_err(|_| "The summary keyboard target could not be selected.".into())
}
#[tauri::command]
fn show_summary(app: AppHandle) -> Result<()> {
    apply_visibility(&app)?;
    let state = app.state::<AppState>();
    let prefs = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .preferences
        .clone();
    let selected = prefs.display.clone().or(app
        .primary_monitor()
        .map_err(|_| "The primary display is unavailable.")?
        .map(|m| monitor_id(&m)));
    let label = {
        let registry = state
            .displays
            .lock()
            .map_err(|_| "Display state is unavailable.")?;
        selected
            .as_deref()
            .and_then(|id| registry.label(id).map(str::to_owned))
            .or_else(|| {
                app.webview_windows()
                    .keys()
                    .filter(|label| is_notch(label))
                    .min()
                    .cloned()
            })
    };
    let Some(label) = label else {
        return open_settings(app, Some("general".into()));
    };
    if !window(&app, &label)?
        .is_visible()
        .map_err(|_| "Widget visibility unavailable.")?
    {
        return open_settings(app, Some("general".into()));
    }
    let card = {
        let mut cards = state
            .expanded
            .lock()
            .map_err(|_| "Window state unavailable.")?;
        let card = cards.entry(label.clone()).or_default();
        card.set_manual(true, false);
        card.pinned = true;
        card.clone()
    };
    position_widgets(&app, &prefs)?;
    emit_widget_state(&app, &label, &card)?;
    focus_card(&app, &label)
}

#[tauri::command]
fn runtime_status(app: AppHandle, state: State<AppState>) -> Result<Value> {
    let state = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?;
    Ok(
        json!({"version":product::VERSION,"channel":product::CHANNEL,
        "runtime":tokenotch_platform::runtime()?,"minimumWindowsBuild":product::MINIMUM_WINDOWS_BUILD,
        "applicationId":app.config().identifier,
        "connectionsEnabled":true,"edge":state.preferences.edge,"widgetVisible":state.preferences.widget_visible}),
    )
}
#[tauri::command]
fn app_snapshot(app: AppHandle, window: WebviewWindow, state: State<AppState>) -> Result<Value> {
    let mut snapshot = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .snapshot()?;
    let label = display_label(window.label());
    // Read the state and its revision together; see emit_widget_state.
    let (card, revision) = {
        let cards = state
            .expanded
            .lock()
            .map_err(|_| "Window state unavailable.")?;
        (
            cards.get(&label).cloned().unwrap_or_default(),
            state.revision.load(Ordering::SeqCst),
        )
    };
    let now = now_ms();
    snapshot["widgetRevision"] = json!(revision);
    snapshot["widgetExpanded"] = json!(card.expanded(now));
    snapshot["widgetAutomatic"] = json!(card.automatic(now));
    snapshot["widgetPinned"] = json!(card.pinned);
    snapshot["widgetDismissed"] = json!(card.dismissed);
    snapshot["widgetAlert"] = json!(card.alert(now));
    snapshot["widgetAlertUntil"] = json!(card.alert_until);
    // A card is only as visible as the notch it belongs to.
    let surface = app
        .get_webview_window(&label)
        .unwrap_or_else(|| window.clone());
    snapshot["widgetVisible"] = json!(surface
        .is_visible()
        .map_err(|_| "Widget visibility unavailable.")?);
    snapshot["cardGeometry"] = state
        .layouts
        .lock()
        .map_err(|_| "Window state unavailable.")?
        .get(&label)
        .map(|layout| layout.geometry.clone())
        .unwrap_or(Value::Null);
    snapshot["windowFocused"] = json!(window
        .is_focused()
        .map_err(|_| "Window focus unavailable.")?);
    match desktop::accessibility() {
        Ok(accessibility) => snapshot["accessibility"] = json!(accessibility),
        Err(message) => snapshot["accessibilityError"] = json!(message),
    }
    Ok(snapshot)
}
#[tauri::command]
fn open_settings(app: AppHandle, page: Option<String>) -> Result<()> {
    if let Some(page) = &page {
        if !SETTINGS_PAGES.contains(&page.as_str()) {
            return Err("Unsupported settings page.".into());
        }
        recover_settings(&app, true)?;
    }
    let settings = window(&app, "settings")?;
    settings
        .show()
        .map_err(|_| "Settings could not be shown.")?;
    settings
        .set_focus()
        .map_err(|_| "Settings could not receive keyboard focus.")?;
    if let Some(page) = page {
        app.emit_to("settings", "page-selected", page)
            .map_err(|_| "The settings page could not be opened.")?;
    }
    Ok(())
}

#[tauri::command]
fn open_detail(app: AppHandle, state: State<AppState>, request: DetailRequest) -> Result<()> {
    let generation = state
        .runtime
        .lock()
        .map_err(|_| "Navigation state is unavailable.")?
        .detail_generation(request.kind);
    request.validate(generation.as_deref())?;
    state
        .detail
        .lock()
        .map_err(|_| "Navigation state is unavailable.")?
        .put(request, now_ms());
    open_settings(app.clone(), None)?;
    app.emit_to("settings", "detail-selected", ())
        .map_err(|_| "The selected detail could not be opened.".into())
}

#[tauri::command]
fn take_detail(state: State<AppState>) -> Result<Option<DetailRequest>> {
    let request = state
        .detail
        .lock()
        .map_err(|_| "Navigation state is unavailable.")?
        .take(now_ms())?;
    if let Some(request) = &request {
        let generation = state
            .runtime
            .lock()
            .map_err(|_| "Navigation state is unavailable.")?
            .detail_generation(request.kind);
        request.validate(generation.as_deref())?;
    }
    Ok(request)
}

fn route_notification(app: &AppHandle, target: Target) -> Result<()> {
    let state = app.state::<AppState>();
    *state
        .notification_target
        .lock()
        .map_err(|_| "Notification navigation is unavailable.")? = Some((now_ms(), target));
    open_settings(app.clone(), None)?;
    app.emit_to("settings", "notification-selected", ())
        .map_err(|_| "Notification details could not be opened.".into())
}
#[tauri::command]
fn open_notification(app: AppHandle, target: Target) -> Result<()> {
    route_notification(&app, target)
}
#[tauri::command]
fn take_notification(state: State<AppState>) -> Result<Option<Target>> {
    let pending = state
        .notification_target
        .lock()
        .map_err(|_| "Notification navigation is unavailable.")?
        .take();
    if let Some((at, target)) = pending {
        if now_ms() - at >= 600_000.0 {
            return Err("This notification navigation expired. Open the original view to review current observations.".into());
        }
        state
            .runtime
            .lock()
            .map_err(|_| "Notification state is unavailable.")?
            .validate_notification_target(&target)?;
        Ok(Some(target))
    } else {
        Ok(None)
    }
}
#[tauri::command]
fn notification_status(app: AppHandle) -> Result<String> {
    desktop::notification_permission(&app.config().identifier)
}
#[tauri::command]
fn test_notification(state: State<AppState>) -> Result<bool> {
    state
        .runtime
        .lock()
        .map_err(|_| "Notification state is unavailable.")?
        .test_notification(now_ms())
}

/// Presents one display's card state to both its notch and its card window.
/// Release state locks first: window getters may wait for the main thread.
fn emit_widget_state(app: &AppHandle, label: &str, card: &CardState) -> Result<()> {
    let now = now_ms();
    // Present the current state, read under the same lock that advances the
    // revision, so revisions and states are ordered alike. Snapshots read the
    // revision under that lock too; a snapshot tagged with the same revision is
    // at least as new as this event.
    let state = app.state::<AppState>();
    let (card, revision) = {
        let cards = state
            .expanded
            .lock()
            .map_err(|_| "Window state unavailable.")?;
        (
            cards.get(label).cloned().unwrap_or_else(|| card.clone()),
            state.revision.fetch_add(1, Ordering::SeqCst) + 1,
        )
    };
    let visible = match app.get_webview_window(label) {
        Some(notch) => notch
            .is_visible()
            .map_err(|_| "Widget visibility unavailable.")?,
        None => false,
    };
    let geometry = state
        .layouts
        .lock()
        .map_err(|_| "Window state unavailable.")?
        .get(label)
        .map(|layout| layout.geometry.clone())
        .unwrap_or(Value::Null);
    let payload = json!({"expanded":card.expanded(now),"automatic":card.automatic(now),"pinned":card.pinned,"dismissed":card.dismissed,
        "alert":card.alert(now),"until":card.alert_until,"visible":visible,"geometry":geometry,"revision":revision});
    for target in [label.to_owned(), card_label(label)] {
        if let Some(window) = app.get_webview_window(&target) {
            app.emit_to(window.label(), "widget-expansion", payload.clone())
                .map_err(|_| "Widget expansion state could not be presented.")?;
        }
    }
    Ok(())
}
fn create_card(app: &AppHandle, label: &str) -> Result<WebviewWindow> {
    tauri::WebviewWindowBuilder::new(
        app,
        label,
        tauri::WebviewUrl::App("index.html?surface=card".into()),
    )
    .title("Tokenotch summary")
    .inner_size(348.0, 420.0)
    .transparent(true)
    .decorations(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .resizable(false)
    .shadow(false)
    .visible(false)
    .focused(false)
    .focusable(false)
    .build()
    .map_err(|_| "The summary card could not be created.".into())
}
/// Places the card beside its notch (NotchCardPlacement). The card window is
/// shown once and then opened or folded by its hit region, because showing a
/// window again on Windows would activate it and steal focus.
fn sync_card(
    app: &AppHandle,
    label: &str,
    notch: &WebviewWindow,
    frame: Rect,
    work: Rect,
    monitor_scale: f64,
    preferences: &Preferences,
) -> Result<()> {
    let state = app.state::<AppState>();
    let card_state = state
        .expanded
        .lock()
        .map_err(|_| "Window state unavailable.")?
        .get(label)
        .cloned()
        .unwrap_or_default();
    let open = notch
        .is_visible()
        .map_err(|_| "Widget visibility unavailable.")?
        && card_state.open(now_ms(), preferences.collapse_idle);
    let name = card_label(label);
    let (card, created) = match app.get_webview_window(&name) {
        Some(card) => (card, false),
        None => (create_card(app, &name)?, true),
    };
    let scale = monitor_scale * preferences.scale;
    let height = state
        .layouts
        .lock()
        .map_err(|_| "Window state unavailable.")?
        .get(label)
        .map(|layout| layout.height)
        .filter(|height| *height > 0.0)
        .unwrap_or(420.0 * preferences.scale);
    let ring = ring_center(preferences.edge, frame, scale);
    let placed = card_frame(
        frame,
        ring,
        preferences.edge,
        work,
        height * monitor_scale,
        scale,
    )
    .ok_or("The summary card could not be placed on this display.")?;
    let size = PhysicalSize::new(
        placed.frame.width.round() as u32,
        placed.frame.height.round() as u32,
    );
    if card.inner_size().map_err(|_| "Card size unavailable.")? != size {
        card.set_size(size)
            .map_err(|_| "The summary card could not be resized.")?;
    }
    let position =
        PhysicalPosition::new(placed.frame.x.round() as i32, placed.frame.y.round() as i32);
    if card
        .outer_position()
        .map_err(|_| "Card position unavailable.")?
        != position
    {
        card.set_position(position)
            .map_err(|_| "The summary card could not be positioned.")?;
    }
    let geometry = json!({"direction":preferences.edge.tooltip_direction(),
        "tailOffset":placed.tail_offset / monitor_scale,"scale":preferences.scale,"scaleFactor":monitor_scale});
    let (changed, was_open, polygons, valid_region) = {
        let mut layouts = state
            .layouts
            .lock()
            .map_err(|_| "Window state unavailable.")?;
        let layout = layouts.entry(label.to_owned()).or_default();
        let changed = layout.geometry != geometry;
        let was_open = layout.open;
        layout.geometry = geometry;
        layout.notch = Some(Rect {
            x: frame.x.round(),
            y: frame.y.round(),
            width: frame.width.round(),
            height: frame.height.round(),
        });
        layout.card = Some(Rect {
            x: placed.frame.x.round(),
            y: placed.frame.y.round(),
            width: f64::from(size.width),
            height: f64::from(size.height),
        });
        layout.bridge = Some(placed.bridge);
        layout.open = open;
        let valid_region = !changed
            && layout.region_size == Some(size)
            && (layout.region_scale - monitor_scale).abs() < 0.001;
        if !valid_region {
            layout.polygons.clear();
        }
        (changed, was_open, layout.polygons.clone(), valid_region)
    };
    if open && (!was_open || created || !valid_region) {
        apply_region(&card, if valid_region { &polygons } else { &[] })?;
    } else if !open && (was_open || created) {
        apply_region(&card, &[])?;
    }
    if created {
        show_passive(&card)?;
    }
    if changed {
        emit_widget_state(app, label, &card_state)?;
    }
    Ok(())
}
fn position_widgets(app: &AppHandle, preferences: &Preferences) -> Result<()> {
    let mut monitors = app
        .available_monitors()
        .map_err(|_| "Display information is unavailable.")?;
    let selected = preferences
        .display
        .as_ref()
        .and_then(|name| monitors.iter().find(|m| m.name() == Some(name)).cloned())
        .or(app
            .primary_monitor()
            .map_err(|_| "The primary display is unavailable.")?)
        .ok_or("No display is available.")?;
    if !preferences.all_displays {
        monitors = vec![selected];
    }
    let state = app.state::<AppState>();
    let assignments = state
        .displays
        .lock()
        .map_err(|_| "Display state is unavailable.")?
        .reconcile(&monitors.iter().map(monitor_id).collect::<Vec<_>>())?;
    for label in &assignments.removed {
        for name in [label.clone(), card_label(label)] {
            if let Some(window) = app.get_webview_window(&name) {
                window
                    .close()
                    .map_err(|_| "A disconnected display window could not be closed.")?;
            }
        }
        state
            .expanded
            .lock()
            .map_err(|_| "Window state unavailable.")?
            .remove(label);
        state
            .layouts
            .lock()
            .map_err(|_| "Window state unavailable.")?
            .remove(label);
        state
            .focus_return
            .lock()
            .map_err(|_| "Focus state unavailable.")?
            .remove(label);
    }
    let labels = assignments.labels;
    for (monitor, label) in monitors.iter().zip(&labels) {
        let label = label.clone();
        let widget = if let Some(window) = app.get_webview_window(&label) {
            window
        } else {
            tauri::WebviewWindowBuilder::new(
                app,
                &label,
                tauri::WebviewUrl::App("index.html?surface=notch".into()),
            )
            .title("Tokenotch activity")
            .inner_size(70.0, 194.0)
            .transparent(true)
            .decorations(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .resizable(false)
            .shadow(false)
            .visible(false)
            .focused(false)
            .focusable(false)
            .build()
            .map_err(|_| "An activity widget could not be created.")?
        };
        let monitor_scale = monitor.scale_factor();
        let scale = monitor_scale * preferences.scale;
        let area = monitor.work_area();
        let work = Rect {
            x: area.position.x as f64,
            y: area.position.y as f64,
            width: area.size.width as f64,
            height: area.size.height as f64,
        };
        let (width, height) = notch_size(preferences.edge, scale);
        let frame = place_at(work, width, height, preferences.edge, preferences.position)
            .ok_or("Display geometry is invalid.")?;
        let size = PhysicalSize::new(frame.width.round() as u32, frame.height.round() as u32);
        if widget
            .inner_size()
            .map_err(|_| "Widget size unavailable.")?
            != size
        {
            apply_region(&widget, &[])?;
            if let Some(layout) = state
                .layouts
                .lock()
                .map_err(|_| "Window state unavailable.")?
                .get_mut(&label)
            {
                layout.notch_polygons.clear();
            }
            widget
                .set_size(size)
                .map_err(|_| "The activity widget could not be resized.")?;
        }
        let position = PhysicalPosition::new(frame.x.round() as i32, frame.y.round() as i32);
        if widget
            .outer_position()
            .map_err(|_| "Widget position unavailable.")?
            != position
        {
            widget
                .set_position(position)
                .map_err(|_| "The activity widget could not be positioned.")?;
        }
        sync_card(
            app,
            &label,
            &widget,
            frame,
            work,
            monitor_scale,
            preferences,
        )?;
    }
    for (label, window) in app.webview_windows() {
        if (is_notch(&label) || is_card(&label)) && !labels.contains(&display_label(&label)) {
            window
                .close()
                .map_err(|_| "A disconnected display widget could not be closed.")?;
        }
    }
    state
        .expanded
        .lock()
        .map_err(|_| "Window state unavailable.")?
        .retain(|label, _| labels.contains(label));
    recover_settings(app, false)?;
    state
        .layouts
        .lock()
        .map_err(|_| "Window state unavailable.")?
        .retain(|label, _| labels.contains(label));
    Ok(())
}
#[tauri::command]
fn displays(app: AppHandle) -> Result<Value> {
    Ok(json!(app
        .available_monitors()
        .map_err(|_| "Display information is unavailable.")?
        .iter()
        .filter_map(|m| m.name().map(
            |name| json!({"name":name,"width":m.size().width,"height":m.size().height,
                "x":m.position().x,"y":m.position().y,"scaleFactor":m.scale_factor(),
                "workArea":{"x":m.work_area().position.x,"y":m.work_area().position.y,
                    "width":m.work_area().size.width,"height":m.work_area().size.height}})
        ))
        .collect::<Vec<_>>()))
}
#[tauri::command]
async fn set_preferences(
    app: AppHandle,
    state: State<'_, AppState>,
    preferences: Preferences,
) -> Result<()> {
    preferences.validate()?;
    position_widgets(&app, &preferences)?;
    let health_was_enabled = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .preferences
        .service_health;
    let health_enabled = preferences.service_health;
    state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .preferences(preferences)?;
    apply_visibility(&app)?;
    if health_enabled && !health_was_enabled {
        let shared = state.runtime.clone();
        tauri::async_runtime::spawn(async move {
            let _ = runtime::refresh_health(shared).await;
        });
    }
    Ok(())
}
#[tauri::command]
async fn set_edge(app: AppHandle, state: State<'_, AppState>, edge: Edge) -> Result<()> {
    let mut prefs = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .preferences
        .clone();
    prefs.edge = edge;
    set_preferences(app, state, prefs).await
}
#[tauri::command]
async fn set_widget_visible(
    app: AppHandle,
    state: State<'_, AppState>,
    visible: bool,
) -> Result<()> {
    let mut prefs = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .preferences
        .clone();
    prefs.widget_visible = visible;
    set_preferences(app, state, prefs).await
}
#[tauri::command]
async fn set_expanded(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, AppState>,
    expanded: bool,
    dismiss: Option<bool>,
    pinned: Option<bool>,
    restore_focus: Option<bool>,
) -> Result<()> {
    let label = display_label(window.label());
    if !is_notch(&label) {
        return Err("Unsupported widget window.".into());
    }
    if expanded {
        apply_visibility(&app)?;
        if !app
            .get_webview_window(&label)
            .ok_or("The activity widget is unavailable.")?
            .is_visible()
            .map_err(|_| "Widget visibility unavailable.")?
        {
            return Err("The summary is unavailable while its widget is hidden.".into());
        }
    }
    let prefs = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .preferences
        .clone();
    let card = {
        let mut cards = state
            .expanded
            .lock()
            .map_err(|_| "Window state is unavailable.")?;
        let card = cards.entry(label.clone()).or_default();
        card.set_manual(expanded, dismiss.unwrap_or(false));
        if let Some(pinned) = pinned {
            card.pinned = expanded && pinned;
        }
        card.clone()
    };
    let return_to = if !expanded && restore_focus == Some(true) {
        let focused = app
            .get_webview_window(&card_label(&label))
            .map(|window| {
                window
                    .is_focused()
                    .map_err(|_| "Card focus is unavailable.")
            })
            .transpose()?
            .unwrap_or(false);
        let origin = state
            .focus_return
            .lock()
            .map_err(|_| "Focus state unavailable.")?
            .remove(&label);
        origin.filter(|_| focused)
    } else {
        None
    };
    // Place (and open or fold) the card before telling the page, so a region
    // requested in response is never applied to a card that is still folded.
    position_widgets(&app, &prefs)?;
    if let Some(surface) = app.get_webview_window(&card_label(&label)) {
        if !expanded {
            surface
                .set_focusable(false)
                .map_err(|_| "Widget focus behavior could not be updated.")?;
        }
    }
    emit_widget_state(&app, &label, &card)?;
    if card.pinned && pinned == Some(true) {
        focus_card(&app, &label)?;
    }
    if let Some(origin) = return_to {
        if let Err(message) = desktop::restore_foreground(origin) {
            runtime::warn(&state.runtime, &message);
            return Err(message);
        }
    }
    Ok(())
}

#[tauri::command]
fn set_card_height(
    window: WebviewWindow,
    app: AppHandle,
    state: State<AppState>,
    height: f64,
) -> Result<()> {
    if !height.is_finite() || !(1.0..=20_000.0).contains(&height) {
        return Err("Unsupported summary card height.".into());
    }
    let label = display_label(window.label());
    if !is_card(window.label()) {
        return Err("Only the summary card reports its height.".into());
    }
    state
        .layouts
        .lock()
        .map_err(|_| "Window state unavailable.")?
        .entry(label)
        .or_default()
        .height = height;
    let prefs = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .preferences
        .clone();
    position_widgets(&app, &prefs)
}

#[tauri::command]
fn set_region(
    window: WebviewWindow,
    state: State<AppState>,
    polygons: Vec<Vec<[f64; 2]>>,
    viewport: [f64; 3],
    geometry: Option<Value>,
) -> Result<bool> {
    let factor = window
        .scale_factor()
        .map_err(|_| "Display scale unavailable.")?;
    let physical = physical_region(&polygons, factor)?;
    if viewport
        .iter()
        .any(|value| !value.is_finite() || *value <= 0.0)
    {
        return Err("Unsupported widget viewport.".into());
    }
    let size = window
        .inner_size()
        .map_err(|_| "Widget size unavailable.")?;
    if (viewport[2] - factor).abs() > 0.001
        || (viewport[0] * factor - f64::from(size.width)).abs() > 2.0
        || (viewport[1] * factor - f64::from(size.height)).abs() > 2.0
    {
        return Ok(false);
    }
    if is_card(window.label()) {
        let mut layouts = state
            .layouts
            .lock()
            .map_err(|_| "Window state unavailable.")?;
        let layout = layouts.entry(display_label(window.label())).or_default();
        let Some(geometry) = geometry else {
            return Ok(false);
        };
        if geometry["direction"] != layout.geometry["direction"]
            || ["tailOffset", "scale", "scaleFactor"].iter().any(|key| {
                !geometry[key]
                    .as_f64()
                    .zip(layout.geometry[key].as_f64())
                    .is_some_and(|(a, b)| (a - b).abs() < 0.001)
            })
        {
            return Ok(false);
        }
        layout.polygons = physical.clone();
        layout.region_size = Some(size);
        layout.region_scale = factor;
        if !layout.open {
            return Ok(true);
        }
    } else if !is_notch(window.label()) {
        return Err("Unsupported widget window.".into());
    } else {
        state
            .layouts
            .lock()
            .map_err(|_| "Window state unavailable.")?
            .entry(window.label().into())
            .or_default()
            .notch_polygons = physical.clone();
    }
    if let Err(message) = apply_region(&window, &physical) {
        runtime::warn(&state.runtime, &message);
        return Err(message);
    }
    Ok(true)
}

/// Whether the pointer rests on this card's notch or on the open card. The two
/// are separate windows, so a card cannot observe hovering over its notch
/// itself; macOS counts both when marking visible notices viewed.
#[tauri::command]
fn pointer_engaged(window: WebviewWindow, app: AppHandle, state: State<AppState>) -> Result<bool> {
    if !is_card(window.label()) {
        return Err("Only the summary card reads pointer engagement.".into());
    }
    let label = display_label(window.label());
    if !app
        .get_webview_window(&label)
        .map(|notch| notch.is_visible())
        .transpose()
        .map_err(|_| "Widget visibility unavailable.")?
        .unwrap_or(false)
    {
        return Ok(false);
    }
    let cursor = app
        .cursor_position()
        .map_err(|_| "The pointer position is unavailable.")?;
    Ok(state
        .layouts
        .lock()
        .map_err(|_| "Window state unavailable.")?
        .get(&label)
        .is_some_and(|layout| layout.engaged(cursor.x, cursor.y)))
}

/// The pointer left the notch or the card. Fold the card once the pointer has
/// stayed outside the notch, the card and the bridge between them, as the
/// macOS hover bridge does, unless the card is pinned.
#[tauri::command]
fn pointer_left(window: WebviewWindow, app: AppHandle, state: State<AppState>) -> Result<()> {
    let label = display_label(window.label());
    if !is_notch(&label) {
        return Err("Unsupported widget window.".into());
    }
    {
        let mut layouts = state
            .layouts
            .lock()
            .map_err(|_| "Window state unavailable.")?;
        let layout = layouts.entry(label.clone()).or_default();
        if layout.polling {
            return Ok(());
        }
        layout.polling = true;
    }
    tauri::async_runtime::spawn(async move {
        if let Err(message) = watch_pointer(&app, &label).await {
            runtime::warn(&app.state::<AppState>().runtime, &message);
        }
        if let Ok(mut layouts) = app.state::<AppState>().layouts.lock() {
            if let Some(layout) = layouts.get_mut(&label) {
                layout.polling = false;
            }
        }
    });
    Ok(())
}
async fn watch_pointer(app: &AppHandle, label: &str) -> Result<()> {
    let mut outside = 0;
    loop {
        tokio::time::sleep(Duration::from_millis(60)).await;
        let state = app.state::<AppState>();
        let card = state
            .expanded
            .lock()
            .map_err(|_| "Window state unavailable.")?
            .get(label)
            .cloned()
            .unwrap_or_default();
        if !card.manual || card.pinned {
            return Ok(());
        }
        let cursor = app
            .cursor_position()
            .map_err(|_| "The pointer position is unavailable.")?;
        let inside = state
            .layouts
            .lock()
            .map_err(|_| "Window state unavailable.")?
            .get(label)
            .is_some_and(|layout| layout.contains(cursor.x, cursor.y));
        if inside {
            return Ok(());
        }
        outside += 1;
        if outside < 3 {
            continue;
        }
        let prefs = state
            .runtime
            .lock()
            .map_err(|_| "Application state unavailable.")?
            .preferences
            .clone();
        let card = {
            let mut cards = state
                .expanded
                .lock()
                .map_err(|_| "Window state unavailable.")?;
            let card = cards.entry(label.to_owned()).or_default();
            if card.pinned || !card.manual {
                return Ok(());
            }
            card.set_manual(false, false);
            card.clone()
        };
        position_widgets(app, &prefs)?;
        if let Some(surface) = app.get_webview_window(&card_label(label)) {
            surface
                .set_focusable(false)
                .map_err(|_| "Widget focus behavior could not be updated.")?;
        }
        return emit_widget_state(app, label, &card);
    }
}

fn expand_widgets(app: &AppHandle, alert: Option<&Alert>) -> Result<()> {
    if alert.is_some() {
        apply_visibility(app)?;
    }
    let state = app.state::<AppState>();
    let mut revealed = Vec::new();
    for (label, window) in app.webview_windows() {
        if is_notch(&label)
            && window
                .is_visible()
                .map_err(|_| "Widget visibility unavailable.")?
        {
            let card = {
                let mut cards = state
                    .expanded
                    .lock()
                    .map_err(|_| "Window state unavailable.")?;
                let card = cards.entry(label.clone()).or_default();
                if let Some(alert) = alert {
                    card.reveal(alert.clone(), now_ms());
                } else {
                    card.set_manual(true, false);
                }
                card.clone()
            };
            revealed.push((label, card));
        }
    }
    let prefs = state
        .runtime
        .lock()
        .map_err(|_| "Application state unavailable.")?
        .preferences
        .clone();
    position_widgets(app, &prefs)?;
    for (label, card) in revealed {
        emit_widget_state(app, &label, &card)?;
    }
    Ok(())
}
#[tauri::command]
async fn connection(
    state: State<'_, AppState>,
    source: Source,
    operation: String,
    metrics: bool,
) -> Result<()> {
    let shared = state.runtime.clone();
    if !["install", "remove", "disableMetrics"].contains(&operation.as_str()) {
        return Err("Unsupported connection action.".into());
    }
    {
        let mut runtime = shared
            .lock()
            .map_err(|_| "Application state is unavailable.")?;
        runtime.checkpoint(now_ms(), false)?;
        if operation == "install" {
            let helper = std::env::current_exe()
                .map_err(|_| "The application location is unavailable.")?
                .parent()
                .ok_or("The application directory is unavailable.")?
                .join("TokenotchHook.exe");
            runtime.connections.install(source, &helper)?;
            runtime.enable_history_for_connection()?;
        } else if operation == "remove" {
            runtime.activity.remove(source);
            if source == Source::Cli {
                runtime.tokens.remove(UsageSource::Cli);
                runtime.notifier.reset_context();
            }
        }
        if source == Source::Vscode {
            let mut prefs = runtime.preferences.clone();
            prefs.vscode_metrics = operation == "install" && metrics;
            runtime.preferences(prefs)?;
        }
        if operation == "remove" {
            runtime.connections.remove(source)?;
        }
        runtime.checkpoint(now_ms(), false)?;
    }
    if source == Source::Vscode {
        let port = if operation == "install" && metrics {
            tokenotch_platform::receiver::start(shared.clone()).await?
        } else {
            shared
                .lock()
                .map_err(|_| "Application state is unavailable.")?
                .receiver
                .port
                .max(1)
        };
        let runtime = shared
            .lock()
            .map_err(|_| "Application state is unavailable.")?;
        runtime.connections.request_vscode(
            operation != "install",
            operation != "disableMetrics",
            if operation == "install" {
                metrics
            } else {
                true
            },
            port,
            &runtime.receiver.token,
        )?;
    }
    Ok(())
}
#[tauri::command]
async fn account_action(state: State<'_, AppState>, operation: String) -> Result<()> {
    if operation == "signIn" || operation == "refresh" {
        return runtime::refresh_account(state.runtime.clone(), operation == "signIn").await;
    }
    if operation != "signOut" {
        return Err("Unsupported account action.".into());
    }
    let mut runtime = state
        .runtime
        .lock()
        .map_err(|_| "Account state is unavailable.")?;
    if runtime.account_busy {
        return Err("Wait for the current account operation before signing out.".into());
    }
    let mut prefs = runtime.preferences.clone();
    prefs.account_enabled = false;
    runtime.preferences(prefs)?;
    let path = runtime.store.root().join("account");
    tokenotch_platform::storage::no_links(&path)?;
    if path.exists() {
        std::fs::remove_dir_all(&path).map_err(|_| {
            "Account collection is off, but private credentials could not be removed."
        })?;
    }
    runtime.account = None;
    runtime.account_auth = tokenotch_platform::account::Authentication::SignedOut;
    runtime.account_error = None;
    runtime.account_shared = false;
    Ok(())
}
#[tauri::command]
fn history(
    state: State<AppState>,
    start: String,
    end: String,
    model: Option<String>,
) -> Result<Value> {
    serde_json::to_value(
        state
            .runtime
            .lock()
            .map_err(|_| "Archive state is unavailable.")?
            .history_filtered(&start, &end, model.as_deref())?,
    )
    .map_err(|_| "History could not be presented.".into())
}
#[tauri::command]
fn timeline_sessions(state: State<AppState>) -> Result<Value> {
    let runtime = state
        .runtime
        .lock()
        .map_err(|_| "Archive state is unavailable.")?;
    let archive = runtime
        .archive
        .as_ref()
        .ok_or("No timeline archive has been created.")?;
    serde_json::to_value(archive.timeline_sessions(runtime.preferences.retention_days, now_ms())?)
        .map_err(|_| "Saved sessions could not be presented.".into())
}
#[tauri::command]
fn timeline_detail(
    state: State<AppState>,
    session: String,
    source: Option<Source>,
) -> Result<Value> {
    if session.len() != 64 || !session.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("The selected session identifier is invalid.".into());
    }
    let runtime = state
        .runtime
        .lock()
        .map_err(|_| "Archive state is unavailable.")?;
    let archive = runtime
        .archive
        .as_ref()
        .ok_or("No timeline archive has been created.")?;
    let id = source
        .map(|source| archive.timeline_session(source, &session))
        .unwrap_or(session);
    serde_json::to_value(archive.timeline_detail(
        &id,
        runtime.preferences.retention_days,
        now_ms(),
    )?)
    .map_err(|_| "This timeline could not be presented.".into())
}
#[tauri::command]
fn timelines(state: State<AppState>, session: Option<String>) -> Result<Value> {
    let runtime = state
        .runtime
        .lock()
        .map_err(|_| "Archive state is unavailable.")?;
    let archive = runtime
        .archive
        .as_ref()
        .ok_or("No timeline archive has been created.")?;
    archive.prune(runtime.preferences.retention_days, now_ms())?;
    serde_json::to_value(archive.timeline(session.as_deref())?)
        .map_err(|_| "Timeline could not be presented.".into())
}
#[tauri::command]
fn clear_data(state: State<AppState>, kind: String) -> Result<()> {
    state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .clear(&kind)
}
#[tauri::command]
fn acknowledge(state: State<AppState>, id: String, dismiss: bool) -> Result<()> {
    let mut runtime = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?;
    let store = runtime.store.clone();
    let remember = runtime.preferences.remember_notices;
    runtime
        .attention
        .acknowledge(&id, dismiss, &store, remember)
}
#[tauri::command]
async fn check_health(state: State<'_, AppState>) -> Result<()> {
    runtime::refresh_health(state.runtime.clone()).await
}
#[tauri::command]
fn open_link(app: AppHandle, target: String) -> Result<()> {
    if target == "vscodeSetup" || target == "vscodeInsidersSetup" {
        let scheme = if target == "vscodeSetup" {
            "vscode"
        } else {
            "vscode-insiders"
        };
        let url = app
            .state::<AppState>()
            .runtime
            .lock()
            .map_err(|_| "Application state is unavailable.")?
            .connections
            .vscode_setup_url(scheme, now_ms())?;
        return app.opener().open_url(url, None::<&str>)
            .map_err(|_| "VS Code could not be opened. Install the companion and run its Configure local integration command.".into());
    }
    if target == "vscodeCompanion" {
        return app
            .opener()
            .reveal_item_in_dir(companion_path(app.clone())?)
            .map_err(|_| "The bundled VS Code extension could not be revealed.".into());
    }
    let url = match target.as_str() {
        "usage" => "https://github.com/settings/billing/usage",
        "releases" => "https://github.com/rottathiago/tokenotch/releases",
        "support" => "https://github.com/rottathiago/tokenotch/blob/main/windows/README.md",
        "status" => "https://www.githubstatus.com/",
        "notifications" => "ms-settings:notifications",
        "pricing" => {
            "https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing"
        }
        _ => return Err("Unsupported link.".into()),
    };
    app.opener()
        .open_url(url, None::<&str>)
        .map_err(|_| "The link could not be opened.".into())
}
#[tauri::command]
fn companion_path(app: AppHandle) -> Result<String> {
    let path = app
        .path()
        .resource_dir()
        .map_err(|_| "Application resources are unavailable.")?
        .join("TokenotchVSCode.vsix");
    if !path.is_file() {
        return Err(
            "The bundled VS Code companion is missing. Rebuild or reinstall Tokenotch.".into(),
        );
    }
    path.to_str()
        .map(str::to_owned)
        .ok_or("Companion path cannot be displayed.".into())
}
/// Installs the bundled companion and returns the setup link for that VS Code edition.
#[tauri::command]
async fn install_companion(app: AppHandle) -> Result<String> {
    let path = std::path::PathBuf::from(companion_path(app)?);
    tokenotch_platform::vscode::install_companion(&path)
        .await
        .map(|edition| edition.link().to_owned())
}

#[tauri::command]
async fn choose_file(app: AppHandle, kind: String) -> Result<Option<String>> {
    tauri::async_runtime::spawn_blocking(move || {
        let dialog = app.dialog().file();
        let dialog = match kind.as_str() {
            "cli" => dialog.add_filter("Copilot executable", &["exe"]),
            "import" => dialog.add_filter("Recorded telemetry", &["json", "jsonl", "sqlite", "db"]),
            _ => return Err("Unsupported file selection.".into()),
        };
        dialog
            .blocking_pick_file()
            .map(|file| {
                file.into_path()
                    .map_err(|_| "The selected file is not local.".to_owned())
                    .and_then(|path| {
                        path.to_str()
                            .map(str::to_owned)
                            .ok_or("The file path cannot be encoded.".into())
                    })
            })
            .transpose()
    })
    .await
    .map_err(|_| "The file picker could not be opened.")?
}

#[tauri::command]
async fn preview_import(state: State<'_, AppState>, path: String) -> Result<Value> {
    let preview = tauri::async_runtime::spawn_blocking(move || {
        tokenotch_platform::import::preview(path.into())
    })
    .await
    .map_err(|_| "Export preview could not finish.")??;
    let summary = serde_json::to_value(preview.summary())
        .map_err(|_| "Export preview could not be presented.")?;
    state
        .runtime
        .lock()
        .map_err(|_| "Archive state is unavailable.")?
        .pending_import = Some(preview);
    Ok(summary)
}

#[tauri::command]
async fn commit_import(state: State<'_, AppState>, fingerprint: String) -> Result<usize> {
    runtime::commit_import(state.runtime.clone(), fingerprint).await
}
fn apply_visibility(app: &AppHandle) -> Result<()> {
    let state = app.state::<AppState>();
    let prefs = state
        .runtime
        .lock()
        .map_err(|_| "Application state is unavailable.")?
        .preferences
        .clone();
    let expired = {
        let mut cards = state
            .expanded
            .lock()
            .map_err(|_| "Window state unavailable.")?;
        let mut expired = Vec::new();
        for (label, card) in cards.iter_mut() {
            if card.alert_until > 0.0 && now_ms() >= card.alert_until {
                card.clear_alert();
                expired.push((label.clone(), card.clone()));
            }
        }
        expired
    };
    for (label, card) in expired {
        emit_widget_state(app, &label, &card)?;
    }
    position_widgets(app, &prefs)?;
    let mut changed = Vec::new();
    for (label, widget) in app.webview_windows() {
        if !is_notch(&label) {
            continue;
        }
        let fullscreen = if prefs.hide_fullscreen {
            let result = match widget
                .current_monitor()
                .map_err(|_| "Display state is unavailable.")?
            {
                Some(m) => desktop::fullscreen_on(
                    m.position().x,
                    m.position().y,
                    m.size().width,
                    m.size().height,
                ),
                None => Err("The widget display is unavailable; its card was hidden.".into()),
            };
            match result {
                Ok(fullscreen) => fullscreen,
                Err(message) => {
                    runtime::warn(&state.runtime, &message);
                    true
                }
            }
        } else {
            false
        };
        let was_visible = widget
            .is_visible()
            .map_err(|_| "Widget visibility unavailable.")?;
        if prefs.widget_visible && !fullscreen {
            if !was_visible {
                show_passive(&widget)?;
            }
            if !was_visible {
                let card = state
                    .expanded
                    .lock()
                    .map_err(|_| "Window state unavailable.")?
                    .get(&label)
                    .cloned()
                    .unwrap_or_default();
                changed.push((label.clone(), card));
            }
        } else {
            let card = {
                let mut cards = state
                    .expanded
                    .lock()
                    .map_err(|_| "Window state unavailable.")?;
                let card = cards.entry(label.clone()).or_default();
                let dismissed = card.dismiss_hidden();
                (dismissed || was_visible).then(|| card.clone())
            };
            state
                .focus_return
                .lock()
                .map_err(|_| "Focus state unavailable.")?
                .remove(&label);
            if let Some(surface) = app.get_webview_window(&card_label(&label)) {
                if let Some(layout) = state
                    .layouts
                    .lock()
                    .map_err(|_| "Window state unavailable.")?
                    .get_mut(&label)
                {
                    layout.open = false;
                }
                apply_region(&surface, &[])?;
                surface
                    .set_focusable(false)
                    .map_err(|_| "Widget focus behavior could not be updated.")?;
            }
            widget.hide().map_err(|_| "Widget could not be hidden.")?;
            if let Some(card) = card {
                changed.push((label.clone(), card));
            }
        }
    }
    // Fold or reopen cards whose notch visibility just changed.
    if !changed.is_empty() {
        position_widgets(app, &prefs)?;
        for (label, card) in changed {
            emit_widget_state(app, &label, &card)?;
        }
    }
    Ok(())
}

fn main() {
    let result=tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app,_,_|{if let Err(message)=open_settings(app.clone(),None){eprintln!("{message}");}}))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![runtime_status,app_snapshot,open_settings,set_edge,set_expanded,
            set_widget_visible,set_preferences,displays,connection,account_action,history,timelines,clear_data,
            set_region,set_card_height,pointer_left,pointer_engaged,show_summary,
            acknowledge,check_health,open_link,companion_path,install_companion,choose_file,preview_import,commit_import,
            open_detail,take_detail,timeline_sessions,timeline_detail,
            open_notification,take_notification,notification_status,test_notification])
        .setup(|app|{
            let actual=tokenotch_platform::runtime().map_err(std::io::Error::other)?;
            if actual.windows_build.is_some_and(|v|v<product::MINIMUM_WINDOWS_BUILD){
                return Err(std::io::Error::other("Tokenotch requires Windows 11 24H2 or later.").into());
            }
            let store=Store::open(home().map_err(std::io::Error::other)?.join(".tokenotch")).map_err(std::io::Error::other)?;
            let shared=Arc::new(Mutex::new(Runtime::open(store).map_err(std::io::Error::other)?));
            let prefs=shared.lock().map_err(|_|std::io::Error::other("Application state unavailable."))?.preferences.clone();
            app.manage(AppState{runtime:shared.clone(),expanded:Mutex::new(BTreeMap::new()),revision:AtomicU64::new(0),layouts:Mutex::new(BTreeMap::new()),detail:Mutex::new(DetailInbox::default()),notification_target:Mutex::new(None),displays:Mutex::new(DisplayRegistry::default()),work_areas:Mutex::new(Vec::new()),focus_return:Mutex::new(BTreeMap::new())});
            let settings=MenuItem::with_id(app,"settings","Open Tokenotch",true,None::<&str>)?;
            let summary=MenuItem::with_id(app,"summary","Show Copilot summary",true,None::<&str>)?;
            let quit=MenuItem::with_id(app,"quit","Quit Tokenotch",true,None::<&str>)?;
            let menu=Menu::with_items(app,&[&summary,&settings,&quit])?;
            TrayIconBuilder::new().icon(Image::from_bytes(include_bytes!("../../../../sources/Resources/Brand/TokenotchMenuBar.png"))?)
                .tooltip("Tokenotch").menu(&menu).on_menu_event(|app,event|{
                    let result=match event.id.as_ref(){
                        "settings"=>open_settings(app.clone(),None),
                        "summary"=>show_summary(app.clone()),
                        "quit"=>{
                            let state=app.state::<AppState>();
                            if let Ok(mut runtime)=state.runtime.lock(){
                                if let Err(message)=runtime.checkpoint(now_ms(),false){eprintln!("{message}");}
                            }
                            app.exit(0);Ok(())
                        },_=>Ok(()),
                    };
                    if let Err(message)=result{eprintln!("{message}");}
                }).build(app)?;
            position_widgets(app.handle(),&prefs).map_err(std::io::Error::other)?;
            apply_visibility(app.handle()).map_err(std::io::Error::other)?;
            open_settings(app.handle().clone(),None).map_err(std::io::Error::other)?;
            let handle=app.handle().clone();
            tauri::async_runtime::spawn(async move{
                if let Err(message)=runtime::start_pipe(shared.clone()){runtime::warn(&shared,&message);}
                if prefs.vscode_metrics{
                    if let Err(message)=tokenotch_platform::receiver::start(shared.clone()).await{runtime::warn(&shared,&message);}
                }
                let mut ticks=0u64;
                let mut signature=None;
                // Verify the saved sign-in right away instead of waiting a full refresh interval.
                if prefs.account_enabled{
                    let copy=shared.clone();tauri::async_runtime::spawn(async move{let _=runtime::refresh_account(copy,false).await;});
                }
                loop{
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    ticks+=1;
                    if let Err(message)=apply_visibility(&handle){runtime::warn(&shared,&message);}
                    let (prefs,notices,current)=match shared.lock(){
                        Ok(mut state)=>{
                            if ticks.is_multiple_of(120){
                                if let Err(message)=state.checkpoint(now_ms(),false){state.warning=Some(message);}
                            }
                            (state.preferences.clone(),std::mem::take(&mut state.notifications),state.change_signature())
                        }
                        Err(_)=>{eprintln!("Application state unavailable.");break;}
                    };
                    // Notices resolved/acknowledged anywhere, or newly saved usage, must reach
                    // every notch, card and settings window without waiting for their polling.
                    if signature.is_some_and(|previous|previous!=current){
                        if let Err(error)=handle.emit("state-changed",()){eprintln!("State change could not be broadcast: {error}");}
                    }
                    signature=Some(current);
                    for pending in notices{
                        let delivery=match shared.lock(){
                            Ok(state)=>state.notification_delivery(&pending,now_ms()),
                            Err(_)=>{eprintln!("Notification state unavailable.");break;}
                        };
                        if delivery==Delivery::default(){continue;}
                        let report=desktop::deliver_channels(delivery,now_ms(),|channel|{
                            let current=shared.lock().map_err(|_|"Notification state unavailable.")?.notification_delivery(&pending,now_ms());
                            let allowed=match channel{Channel::Desktop=>current.desktop,Channel::Sound=>current.sound,Channel::Card=>current.card};
                            if !allowed{return Err("Delivery suppressed by current settings or superseding observations.".into());}
                            match channel {
                                Channel::Desktop=>{
                                    let app=handle.clone();let target=pending.alert.target.clone();let shared=shared.clone();
                                    desktop::notify(&handle.config().identifier,&pending.alert.title,&pending.alert.body,move || {
                                        if let Err(message)=route_notification(&app,target.clone()){runtime::warn(&shared,&message);}
                                    })
                                }
                                Channel::Sound=>desktop::play_sound(),
                                Channel::Card=>expand_widgets(&handle,Some(&pending.alert)),
                            }
                        });
                        if let Ok(mut state)=shared.lock(){
                            state.notification_delivery.observed_at=report.observed_at;
                            if report.desktop.is_some(){state.notification_delivery.desktop=report.desktop;}
                            if report.sound.is_some(){state.notification_delivery.sound=report.sound;}
                            if report.card.is_some(){state.notification_delivery.card=report.card;}
                        }
                    }
                    if ticks.is_multiple_of(120) && prefs.account_enabled{
                        let copy=shared.clone();tauri::async_runtime::spawn(async move{let _=runtime::refresh_account(copy,false).await;});
                    }
                    if ticks.is_multiple_of(600) && prefs.service_health{
                        let copy=shared.clone();tauri::async_runtime::spawn(async move{let _=runtime::refresh_health(copy).await;});
                    }
                }
            });
            Ok(())
        })
        .on_window_event(|window,event|{
            if matches!(event,WindowEvent::ScaleFactorChanged{..}) {
                let app=window.app_handle();
                if let Some(state)=app.try_state::<AppState>() {
                    if window.label()=="settings" {
                        match state.work_areas.lock(){
                            Ok(mut areas)=>areas.clear(),
                            Err(_)=>runtime::warn(&state.runtime,"Display state is unavailable."),
                        }
                    } else if is_notch(window.label()) || is_card(window.label()) {
                        let result=(||->Result<()>{
                            if let Some(surface)=app.get_webview_window(window.label()){apply_region(&surface,&[])?;}
                            {
                                let mut layouts=state.layouts.lock().map_err(|_|"Window state unavailable.")?;
                                if let Some(layout)=layouts.get_mut(&display_label(window.label())){
                                    if is_card(window.label()){layout.polygons.clear();layout.region_size=None;}
                                    else {layout.notch_polygons.clear();}
                                }
                            }
                            app.emit_to(window.label(),"display-changed",()).map_err(|_|"Display changes could not be presented.".into())
                        })();
                        if let Err(message)=result{runtime::warn(&state.runtime,&message);}
                    }
                }
            }
            if window.label()=="settings"{
                if let WindowEvent::CloseRequested{api,..}=event{
                    match window.hide(){Ok(())=>api.prevent_close(),Err(_)=>eprintln!("Settings could not be hidden.")}
                }
            }
        }).run(tauri::generate_context!());
    if let Err(error) = result {
        eprintln!("Tokenotch could not start: {error}");
        std::process::exit(1);
    }
}
