#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use std::sync::Mutex;
use tauri::{
    image::Image,
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager, PhysicalPosition, PhysicalSize, State, WebviewWindow, WindowEvent,
};
use tokenotch_core::{
    placement::{place, Edge, Rect},
    product,
};

struct WidgetState {
    edge: Edge,
    expanded: bool,
    visible: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    version: &'static str,
    channel: &'static str,
    runtime: tokenotch_platform::Runtime,
    minimum_windows_build: u32,
    connections_enabled: bool,
    edge: Edge,
    widget_visible: bool,
}

fn window(app: &AppHandle, label: &str) -> Result<WebviewWindow, String> {
    app.get_webview_window(label)
        .ok_or_else(|| "The requested Tokenotch window is unavailable.".to_owned())
}

#[tauri::command]
fn runtime_status(state: State<Mutex<WidgetState>>) -> Result<Status, String> {
    let state = state.lock().map_err(|_| "Window state is unavailable.")?;
    Ok(Status {
        version: product::VERSION,
        channel: product::CHANNEL,
        runtime: tokenotch_platform::runtime().map_err(str::to_owned)?,
        minimum_windows_build: product::MINIMUM_WINDOWS_BUILD,
        connections_enabled: false,
        edge: state.edge,
        widget_visible: state.visible,
    })
}

#[tauri::command]
fn open_settings(app: AppHandle) -> Result<(), String> {
    let settings = window(&app, "settings")?;
    settings
        .show()
        .map_err(|_| "Settings could not be shown.")?;
    settings
        .set_focus()
        .map_err(|_| "Settings could not receive keyboard focus.".into())
}

fn position_widget(app: &AppHandle, edge: Edge, expanded: bool) -> Result<(), String> {
    let widget = window(app, "widget")?;
    let monitor = widget
        .current_monitor()
        .map_err(|_| "Display information is unavailable.")?
        .or(app
            .primary_monitor()
            .map_err(|_| "The primary display is unavailable.")?)
        .ok_or("No display is available.")?;
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let width = if expanded { 320.0 } else { 64.0 } * scale;
    let height = if expanded { 224.0 } else { 112.0 } * scale;
    let frame = place(
        Rect {
            x: area.position.x as f64,
            y: area.position.y as f64,
            width: area.size.width as f64,
            height: area.size.height as f64,
        },
        width,
        height,
        edge,
    )
    .ok_or("Display geometry is invalid.")?;
    widget
        .set_size(PhysicalSize::new(
            frame.width.round() as u32,
            frame.height.round() as u32,
        ))
        .map_err(|_| "The activity widget could not be resized.")?;
    widget
        .set_position(PhysicalPosition::new(
            frame.x.round() as i32,
            frame.y.round() as i32,
        ))
        .map_err(|_| "The activity widget could not be positioned.")?;
    Ok(())
}

#[tauri::command]
fn set_edge(app: AppHandle, state: State<Mutex<WidgetState>>, edge: Edge) -> Result<(), String> {
    let mut state = state.lock().map_err(|_| "Window state is unavailable.")?;
    position_widget(&app, edge, state.expanded)?;
    state.edge = edge;
    Ok(())
}

#[tauri::command]
fn set_expanded(
    app: AppHandle,
    state: State<Mutex<WidgetState>>,
    expanded: bool,
) -> Result<(), String> {
    let mut state = state.lock().map_err(|_| "Window state is unavailable.")?;
    position_widget(&app, state.edge, expanded)?;
    state.expanded = expanded;
    Ok(())
}

#[tauri::command]
fn set_widget_visible(
    app: AppHandle,
    state: State<Mutex<WidgetState>>,
    visible: bool,
) -> Result<(), String> {
    let mut state = state.lock().map_err(|_| "Window state is unavailable.")?;
    let widget = window(&app, "widget")?;
    if visible {
        position_widget(&app, state.edge, state.expanded)?;
        widget
            .show()
            .map_err(|_| "The activity widget could not be shown.")?;
    } else {
        widget
            .hide()
            .map_err(|_| "The activity widget could not be hidden.")?;
    }
    state.visible = visible;
    Ok(())
}

fn main() {
    let result = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Err(message) = open_settings(app.clone()) {
                eprintln!("{message}");
            }
        }))
        .manage(Mutex::new(WidgetState {
            edge: Edge::Right,
            expanded: false,
            visible: true,
        }))
        .invoke_handler(tauri::generate_handler![
            runtime_status,
            open_settings,
            set_edge,
            set_expanded,
            set_widget_visible
        ])
        .setup(|app| {
            let runtime = tokenotch_platform::runtime().map_err(std::io::Error::other)?;
            if runtime
                .windows_build
                .is_some_and(|build| build < product::MINIMUM_WINDOWS_BUILD)
            {
                return Err(std::io::Error::other(
                    "This development build requires Windows 11 24H2 or later.",
                )
                .into());
            }
            let settings =
                MenuItem::with_id(app, "settings", "Open Tokenotch", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Tokenotch", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;
            TrayIconBuilder::new()
                .icon(Image::from_bytes(include_bytes!(
                    "../../../../sources/Resources/Brand/TokenotchMenuBar.png"
                ))?)
                .tooltip("Tokenotch development build")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "settings" => {
                        if let Err(message) = open_settings(app.clone()) {
                            eprintln!("{message}");
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            position_widget(app.handle(), Edge::Right, false).map_err(std::io::Error::other)?;
            window(app.handle(), "widget")
                .map_err(std::io::Error::other)?
                .show()?;
            open_settings(app.handle().clone()).map_err(std::io::Error::other)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "settings" {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    match window.hide() {
                        Ok(()) => api.prevent_close(),
                        Err(_) => eprintln!("Settings could not be hidden."),
                    }
                }
            }
        })
        .run(tauri::generate_context!());
    if let Err(error) = result {
        eprintln!("Tokenotch could not start: {error}");
        std::process::exit(1);
    }
}
