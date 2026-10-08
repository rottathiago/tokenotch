#[cfg(not(windows))]
fn main() {
    panic!("The fullscreen fixture requires Windows.");
}

#[cfg(windows)]
fn main() {
    fixture::run();
}

#[cfg(windows)]
mod fixture {
    use serde::Deserialize;
    use serde_json::{json, Value};
    use std::io::{BufRead, Write};
    use windows::{
        core::w,
        Win32::{
            Foundation::{HWND, LPARAM, POINT, RECT},
            Graphics::{
                Dwm::DwmFlush,
                Gdi::{CreateRectRgn, DeleteObject, GetWindowRgn},
            },
            UI::WindowsAndMessaging::{
                CreateWindowExW, DestroyWindow, DispatchMessageW, EnumWindows, GetCursorPos,
                GetForegroundWindow, GetWindowLongW, GetWindowRect, GetWindowTextW,
                GetWindowThreadProcessId, IsWindowVisible, IsZoomed, PeekMessageW, SetCursorPos,
                SetWindowLongW, SetWindowPos, ShowWindow, TranslateMessage, GWL_STYLE, MSG,
                PM_REMOVE, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOZORDER, SW_HIDE, SW_SHOWNA,
                WS_BORDER, WS_CAPTION, WS_EX_TOOLWINDOW, WS_MAXIMIZE, WS_OVERLAPPEDWINDOW,
                WS_POPUP, WS_VISIBLE,
            },
        },
    };

    #[derive(Deserialize)]
    #[serde(tag = "command", rename_all = "camelCase")]
    enum Request {
        Place {
            mode: Mode,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        Hide,
        Cursor {
            x: Option<i32>,
            y: Option<i32>,
        },
        Inspect {
            pid: u32,
        },
        Exit,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    enum Mode {
        Fullscreen,
        Border,
        MaximizedFullscreen,
        Maximized,
        Windowed,
    }

    unsafe fn describe(window: HWND) -> Value {
        let mut frame = RECT::default();
        GetWindowRect(window, &mut frame).unwrap();
        let mut title = [0; 256];
        let length = GetWindowTextW(window, &mut title) as usize;
        let region = CreateRectRgn(0, 0, 0, 0);
        assert!(!region.is_invalid());
        let region_kind = GetWindowRgn(window, region).0;
        let _ = DeleteObject(region.into());
        let style = GetWindowLongW(window, GWL_STYLE) as u32;
        json!({
            "title": String::from_utf16_lossy(&title[..length]),
            "visible": IsWindowVisible(window).as_bool(),
            "focused": GetForegroundWindow() == window,
            "maximized": IsZoomed(window).as_bool(),
            "captionBits": style & WS_CAPTION.0,
            "emptyRegion": region_kind == 1,
            "frame": {"x": frame.left, "y": frame.top,
                "width": frame.right - frame.left, "height": frame.bottom - frame.top},
        })
    }

    struct Inspection {
        pid: u32,
        windows: Vec<Value>,
    }
    unsafe extern "system" fn inspect(window: HWND, data: LPARAM) -> windows::core::BOOL {
        let inspection = &mut *(data.0 as *mut Inspection);
        let mut pid = 0;
        GetWindowThreadProcessId(window, Some(&mut pid));
        if pid == inspection.pid {
            inspection.windows.push(describe(window));
        }
        true.into()
    }

    pub fn run() {
        use windows::Win32::UI::HiDpi::{
            SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        };
        unsafe {
            SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).unwrap();
        }
        let args: Vec<_> = std::env::args().skip(1).collect();
        if args.first().is_some_and(|arg| arg == "--detect") {
            assert_eq!(args.len(), 5);
            let detected = tokenotch_platform::desktop::fullscreen_on(
                args[1].parse().unwrap(),
                args[2].parse().unwrap(),
                args[3].parse().unwrap(),
                args[4].parse().unwrap(),
            )
            .unwrap();
            println!("{detected}");
            return;
        }
        let (send, receive) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                send.send(serde_json::from_str::<Request>(&line.unwrap()).unwrap())
                    .unwrap();
            }
            let _ = send.send(Request::Exit);
        });
        unsafe {
            let window = CreateWindowExW(
                WS_EX_TOOLWINDOW,
                w!("STATIC"),
                w!("Tokenotch isolated fullscreen fixture"),
                WS_POPUP,
                0,
                0,
                100,
                100,
                None,
                None,
                None,
                None,
            )
            .unwrap();
            loop {
                let mut message = MSG::default();
                while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                    let _ = TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
                let request = match receive.try_recv() {
                    Ok(request) => request,
                    Err(std::sync::mpsc::TryRecvError::Empty) => {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                        continue;
                    }
                    Err(error) => panic!("Fixture input failed: {error}"),
                };
                let result = match request {
                    Request::Place {
                        mode,
                        x,
                        y,
                        width,
                        height,
                    } => {
                        assert!(width > 0 && height > 0);
                        let style = match mode {
                            Mode::Fullscreen => WS_POPUP,
                            Mode::Border => WS_POPUP | WS_BORDER,
                            Mode::MaximizedFullscreen => WS_POPUP | WS_MAXIMIZE,
                            Mode::Maximized => WS_OVERLAPPEDWINDOW | WS_MAXIMIZE,
                            Mode::Windowed => WS_OVERLAPPEDWINDOW,
                        };
                        SetWindowLongW(window, GWL_STYLE, (style | WS_VISIBLE).0 as i32);
                        SetWindowPos(
                            window,
                            None,
                            x,
                            y,
                            width,
                            height,
                            SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOZORDER,
                        )
                        .unwrap();
                        let _ = ShowWindow(window, SW_SHOWNA);
                        DwmFlush().unwrap();
                        describe(window)
                    }
                    Request::Hide => {
                        let _ = ShowWindow(window, SW_HIDE);
                        describe(window)
                    }
                    Request::Cursor { x, y } => {
                        if let (Some(x), Some(y)) = (x, y) {
                            SetCursorPos(x, y).unwrap();
                        }
                        let mut point = POINT::default();
                        GetCursorPos(&mut point).unwrap();
                        json!({"x": point.x, "y": point.y})
                    }
                    Request::Inspect { pid } => {
                        let mut inspection = Inspection {
                            pid,
                            windows: Vec::new(),
                        };
                        EnumWindows(
                            Some(inspect),
                            LPARAM((&mut inspection as *mut Inspection) as isize),
                        )
                        .unwrap();
                        json!(inspection.windows)
                    }
                    Request::Exit => break,
                };
                println!("{result}");
                std::io::stdout().flush().unwrap();
            }
            DestroyWindow(window).unwrap();
        }
    }
}
