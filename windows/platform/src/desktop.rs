#[cfg(windows)]
pub fn fullscreen_on(x: i32, y: i32, width: u32, height: u32) -> crate::storage::Result<bool> {
    use crate::display::{is_fullscreen, WindowState};
    use tokenotch_core::placement::Rect;
    use windows::Win32::{
        Foundation::{HWND, LPARAM, RECT},
        Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED},
        UI::WindowsAndMessaging::{
            EnumWindows, GetClassNameW, GetWindowLongW, GetWindowRect, GetWindowThreadProcessId,
            IsIconic, IsWindowVisible, IsZoomed, GWL_STYLE, WS_CAPTION,
        },
    };
    struct Search {
        screen: Rect,
        found: bool,
        failed: bool,
    }
    unsafe extern "system" fn visit(window: HWND, data: LPARAM) -> windows::core::BOOL {
        let search = &mut *(data.0 as *mut Search);
        if !IsWindowVisible(window).as_bool() || IsIconic(window).as_bool() {
            return true.into();
        }
        let mut process = 0;
        GetWindowThreadProcessId(window, Some(&mut process));
        if process == std::process::id() {
            return true.into();
        }
        let mut class = [0u16; 256];
        let length = GetClassNameW(window, &mut class);
        if length <= 0
            || [
                "Progman",
                "WorkerW",
                "Shell_TrayWnd",
                "Shell_SecondaryTrayWnd",
            ]
            .contains(&String::from_utf16_lossy(&class[..length as usize]).as_str())
        {
            return true.into();
        }
        // WS_CAPTION includes WS_BORDER: a border alone is not a title bar.
        if GetWindowLongW(window, GWL_STYLE) as u32 & WS_CAPTION.0 == WS_CAPTION.0 {
            return true.into();
        }
        let mut rect = RECT::default();
        if GetWindowRect(window, &mut rect).is_ok() {
            let mut candidate = WindowState {
                frame: Rect {
                    x: f64::from(rect.left),
                    y: f64::from(rect.top),
                    width: f64::from(rect.right) - f64::from(rect.left),
                    height: f64::from(rect.bottom) - f64::from(rect.top),
                },
                visible: true,
                minimized: false,
                maximized: IsZoomed(window).as_bool(),
                captioned: false,
                cloaked: false,
                own_process: false,
                shell: false,
            };
            if is_fullscreen(candidate, search.screen) {
                let mut cloaked = 0u32;
                if DwmGetWindowAttribute(
                    window,
                    DWMWA_CLOAKED,
                    (&mut cloaked as *mut u32).cast(),
                    std::mem::size_of::<u32>() as u32,
                )
                .is_err()
                {
                    search.failed = true;
                    return true.into();
                }
                candidate.cloaked = cloaked != 0;
                if is_fullscreen(candidate, search.screen) {
                    search.found = true;
                    return false.into();
                }
            }
        }
        true.into()
    }
    let mut search = Search {
        screen: Rect {
            x: f64::from(x),
            y: f64::from(y),
            width: f64::from(width),
            height: f64::from(height),
        },
        found: false,
        failed: false,
    };
    let result = unsafe { EnumWindows(Some(visit), LPARAM((&mut search as *mut Search) as isize)) };
    if !search.found && (result.is_err() || search.failed) {
        return Err(
            "Fullscreen visibility could not be determined. The affected widget was hidden.".into(),
        );
    }
    Ok(search.found)
}
#[cfg(not(windows))]
pub fn fullscreen_on(_: i32, _: i32, _: u32, _: u32) -> crate::storage::Result<bool> {
    Err("Native fullscreen detection requires Windows.".into())
}

/// Clips a top-level window's painting and hit testing to the union of
/// polygons given in physical client pixels, so the transparent parts of the
/// notch and card pass clicks through. An empty list clips the window away.
#[cfg(windows)]
pub fn set_window_region(hwnd: isize, polygons: &[Vec<(i32, i32)>]) -> crate::storage::Result<()> {
    use windows::Win32::{
        Foundation::{HWND, POINT},
        Graphics::Gdi::{
            CombineRgn, CreatePolygonRgn, CreateRectRgn, DeleteObject, SetWindowRgn, RGN_OR,
            WINDING,
        },
    };
    const FAILED: &str = "The widget's click-through region could not be applied.";
    unsafe {
        let region = CreateRectRgn(0, 0, 0, 0);
        if region.is_invalid() {
            return Err(FAILED.into());
        }
        for polygon in polygons {
            let points: Vec<POINT> = polygon.iter().map(|&(x, y)| POINT { x, y }).collect();
            let part = CreatePolygonRgn(&points, WINDING);
            if part.is_invalid() {
                let _ = DeleteObject(region.into());
                return Err(FAILED.into());
            }
            let combined = CombineRgn(Some(region), Some(region), Some(part), RGN_OR);
            let _ = DeleteObject(part.into());
            if combined.0 == 0 {
                let _ = DeleteObject(region.into());
                return Err(FAILED.into());
            }
        }
        // On success the system owns the region and frees it with the window.
        if SetWindowRgn(HWND(hwnd as _), Some(region), true) == 0 {
            let _ = DeleteObject(region.into());
            return Err(FAILED.into());
        }
    }
    Ok(())
}
#[cfg(not(windows))]
pub fn set_window_region(_: isize, _: &[Vec<(i32, i32)>]) -> crate::storage::Result<()> {
    Err("Window regions require Windows.".into())
}

#[cfg(windows)]
pub fn notify(
    app_id: &str,
    title: &str,
    body: &str,
    on_click: impl Fn() + Send + 'static,
) -> crate::storage::Result<()> {
    let permission = notification_permission(app_id)?;
    if permission != "Allowed" {
        return Err(permission);
    }
    tauri_winrt_notification::Toast::new(app_id).title(title).text1(body).sound(None)
        .on_activated(move |_|{on_click();Ok(())}).show()
        .map_err(|_|"Windows could not display the notification. Check Windows notification settings and the installed application identity.".into())
}
#[cfg(not(windows))]
pub fn notify(
    _: &str,
    _: &str,
    _: &str,
    _: impl Fn() + Send + 'static,
) -> crate::storage::Result<()> {
    Err("Native notifications require Windows.".into())
}
#[cfg(windows)]
pub fn play_sound() -> crate::storage::Result<()> {
    use windows::{
        core::w,
        Win32::Media::Audio::{PlaySoundW, SND_ALIAS, SND_ASYNC, SND_NODEFAULT},
    };
    if unsafe {
        PlaySoundW(
            w!("SystemNotification"),
            None,
            SND_ALIAS | SND_ASYNC | SND_NODEFAULT,
        )
    }
    .as_bool()
    {
        Ok(())
    } else {
        Err("The notification sound could not be played.".into())
    }
}
#[cfg(not(windows))]
pub fn play_sound() -> crate::storage::Result<()> {
    Err("Native notification sounds require Windows.".into())
}
use crate::notifications::{Alert, Delivery, DeliveryStatus};

#[derive(Clone, Default)]
pub struct CardState {
    pub manual: bool,
    /// Opened by clicking the notch: pointer exits no longer fold the card.
    pub pinned: bool,
    pub dismissed: bool,
    pub alert_until: f64,
    alert: Option<Alert>,
}
impl CardState {
    pub fn open(&self, now: f64, collapse_idle: bool) -> bool {
        self.expanded(now) || (!collapse_idle && !self.dismissed)
    }
    pub fn expanded(&self, now: f64) -> bool {
        self.manual || now < self.alert_until
    }
    pub fn automatic(&self, now: f64) -> bool {
        !self.manual && now < self.alert_until
    }
    pub fn alert(&self, now: f64) -> Option<&Alert> {
        self.alert.as_ref().filter(|_| now < self.alert_until)
    }
    pub fn reveal(&mut self, alert: Alert, now: f64) {
        self.alert_until = now + 3000.0;
        self.alert = Some(alert);
    }
    pub fn set_manual(&mut self, value: bool, dismiss: bool) {
        self.manual = value;
        if value {
            self.dismissed = false;
        } else if dismiss {
            self.dismissed = true;
        }
        if !value {
            self.pinned = false;
        }
        if dismiss {
            self.clear_alert();
        }
    }
    pub fn clear_alert(&mut self) {
        self.alert_until = 0.0;
        self.alert = None;
    }
    pub fn dismiss_hidden(&mut self) -> bool {
        let changed = self.manual || self.pinned || !self.dismissed || self.alert.is_some();
        self.set_manual(false, true);
        changed
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channel {
    Desktop,
    Sound,
    Card,
}
pub fn deliver_channels(
    delivery: Delivery,
    now: f64,
    mut deliver: impl FnMut(Channel) -> crate::storage::Result<()>,
) -> DeliveryStatus {
    let mut status = DeliveryStatus {
        observed_at: Some(now),
        ..Default::default()
    };
    for (channel, enabled) in [
        (Channel::Desktop, delivery.desktop),
        (Channel::Sound, delivery.sound),
        (Channel::Card, delivery.card),
    ] {
        if !enabled {
            continue;
        }
        let result = Some(match deliver(channel) {
            Ok(()) => match channel {
                Channel::Desktop => "Desktop banner posted",
                Channel::Sound => "Sound played",
                Channel::Card => "Card requested on eligible displays",
            }
            .into(),
            Err(message) => message,
        });
        match channel {
            Channel::Desktop => status.desktop = result,
            Channel::Sound => status.sound = result,
            Channel::Card => status.card = result,
        }
    }
    status
}

#[cfg(windows)]
pub fn notification_permission(app_id: &str) -> crate::storage::Result<String> {
    use windows::{
        core::HSTRING,
        UI::Notifications::{NotificationSetting, ToastNotificationManager},
    };
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(app_id))
        .map_err(|_| {
            "Windows notification identity is unavailable. Use a registered application build."
        })?;
    let setting = notifier
        .Setting()
        .map_err(|_| "Windows notification settings could not be read for this application identity. A registered installation is required for desktop notification acceptance.")?;
    Ok(match setting {
        NotificationSetting::Enabled => "Allowed",
        NotificationSetting::DisabledForApplication => {
            "Disabled for Tokenotch in Windows notification settings"
        }
        NotificationSetting::DisabledForUser => "Windows notifications are disabled for this user",
        NotificationSetting::DisabledByGroupPolicy => {
            "Windows desktop notifications are disabled by group policy"
        }
        NotificationSetting::DisabledByManifest => {
            "Desktop notifications are disabled by the application manifest"
        }
        _ => return Err("Windows returned an unsupported notification setting.".into()),
    }
    .into())
}
#[cfg(not(windows))]
pub fn notification_permission(_: &str) -> crate::storage::Result<String> {
    Err("Native notification settings require Windows.".into())
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Accessibility {
    pub text_scale: f64,
    pub animations_enabled: bool,
    pub transparency_enabled: bool,
}
#[cfg(windows)]
pub fn accessibility() -> crate::storage::Result<Accessibility> {
    use windows::UI::ViewManagement::UISettings;
    let settings = UISettings::new().map_err(|_| "Windows visual preferences are unavailable.")?;
    let text_scale = settings
        .TextScaleFactor()
        .map_err(|_| "Windows text scaling is unavailable.")?;
    if !text_scale.is_finite() || !(1.0..=5.0).contains(&text_scale) {
        return Err("Windows returned an unsupported text scale.".into());
    }
    Ok(Accessibility {
        text_scale,
        animations_enabled: settings
            .AnimationsEnabled()
            .map_err(|_| "Windows animation preferences are unavailable.")?,
        transparency_enabled: settings
            .AdvancedEffectsEnabled()
            .map_err(|_| "Windows transparency preferences are unavailable.")?,
    })
}
#[cfg(not(windows))]
pub fn accessibility() -> crate::storage::Result<Accessibility> {
    Err("Windows visual preferences are unavailable on this host.".into())
}

#[cfg(windows)]
pub fn foreground_window() -> Option<isize> {
    let window = unsafe { windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow() };
    (!window.is_invalid()).then_some(window.0 as isize)
}
#[cfg(not(windows))]
pub fn foreground_window() -> Option<isize> {
    None
}
#[cfg(windows)]
pub fn restore_foreground(handle: isize) -> crate::storage::Result<()> {
    use windows::Win32::{
        Foundation::HWND,
        UI::WindowsAndMessaging::{IsWindow, IsWindowVisible, SetForegroundWindow},
    };
    let window = HWND(handle as _);
    if unsafe {
        IsWindow(Some(window)).as_bool()
            && IsWindowVisible(window).as_bool()
            && SetForegroundWindow(window).as_bool()
    } {
        Ok(())
    } else {
        Err("The previous window is no longer available for keyboard focus.".into())
    }
}
#[cfg(not(windows))]
pub fn restore_foreground(_: isize) -> crate::storage::Result<()> {
    Err("Native focus restoration requires Windows.".into())
}
