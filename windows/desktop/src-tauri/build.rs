fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "runtime_status",
            "open_settings",
            "set_edge",
            "set_expanded",
            "set_widget_visible",
        ]),
    ))
    .expect("Tokenotch desktop resources or command permissions are invalid");
}
