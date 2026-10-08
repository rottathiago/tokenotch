use tokenotch_core::placement::{
    card_frame, notch_size, place_at, recover_window, ring_center, Edge, Rect,
};
use tokenotch_platform::{
    desktop::CardState,
    display::{is_fullscreen, physical_region, region_contains, DisplayRegistry, WindowState},
    preferences::Preferences,
};

fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect {
        x,
        y,
        width,
        height,
    }
}
#[test]
fn monitor_reordering_keeps_state_and_removal_does_not_transfer_it() {
    let mut registry = DisplayRegistry::default();
    let first = registry
        .reconcile(&["primary".into(), "second".into()])
        .unwrap();
    assert_eq!(first.labels, ["widget", "widget-1"]);
    let reordered = registry
        .reconcile(&["second".into(), "primary".into()])
        .unwrap();
    assert_eq!(reordered.labels, ["widget-1", "widget"]);
    assert!(reordered.removed.is_empty());
    let replacement = registry
        .reconcile(&["second".into(), "third".into()])
        .unwrap();
    assert_eq!(replacement.removed, ["widget"]);
    assert_eq!(replacement.labels, ["widget-1", "widget-2"]);
    assert_eq!(registry.label("second"), Some("widget-1"));
    let switched = registry.reconcile(&["primary".into()]).unwrap();
    assert_eq!(switched.removed, ["widget-1", "widget-2"]);
    assert_eq!(switched.labels, ["widget-3"]);
    assert!(registry
        .reconcile(&["second".into(), "second".into()])
        .is_err());
    assert!(registry.reconcile(&[]).is_err());
}
#[test]
fn recovery_fits_negative_coordinate_changed_work_areas_and_oversized_windows() {
    let primary = rect(0.0, 32.0, 1280.0, 688.0);
    let second = rect(-1920.0, -200.0, 1920.0, 1040.0);
    let lost = rect(-1800.0, 20.0, 860.0, 680.0);
    assert_eq!(recover_window(lost, &[primary, second]), Some(lost));
    assert_eq!(
        recover_window(lost, &[primary]),
        Some(rect(0.0, 32.0, 860.0, 680.0))
    );
    let huge = rect(500.0, -500.0, 4000.0, 3000.0);
    assert_eq!(recover_window(huge, &[primary]), Some(primary));
    assert!(recover_window(lost, &[]).is_none());
    assert!(recover_window(rect(f64::NAN, 0.0, 20.0, 20.0), &[primary]).is_none());
}
#[test]
fn bounded_card_geometry_matches_dpi_edges_and_clamped_tail_bridge() {
    for work in [
        rect(-1920.0, -300.0, 1920.0, 1040.0),
        rect(48.0, 0.0, 752.0, 552.0),
        rect(0.0, 30.0, 360.0, 230.0),
    ] {
        for scale in [0.75, 1.0, 1.25, 1.5, 2.0, 3.0] {
            for edge in [Edge::Left, Edge::Right, Edge::Top, Edge::Bottom] {
                for fraction in [0.0, 0.5, 1.0] {
                    let size = notch_size(edge, scale);
                    let notch = place_at(work, size.0, size.1, edge, fraction).unwrap();
                    let center = ring_center(edge, notch, scale);
                    let card = card_frame(notch, center, edge, work, 4000.0, scale).unwrap();
                    assert!(card.frame.x >= work.x && card.frame.y >= work.y);
                    assert!(card.frame.x + card.frame.width <= work.x + work.width + 0.001);
                    assert!(card.frame.y + card.frame.height <= work.y + work.height + 0.001);
                    assert!(card.frame.valid() && card.bridge.valid());
                }
            }
        }
    }
}
#[test]
fn fullscreen_excludes_own_cards_cloaked_shell_and_maximized_windows_on_each_monitor() {
    let screen = rect(-1920.0, 0.0, 1920.0, 1080.0);
    let window = WindowState {
        frame: screen,
        visible: true,
        minimized: false,
        maximized: false,
        captioned: false,
        cloaked: false,
        own_process: false,
        shell: false,
    };
    assert!(is_fullscreen(window, screen));
    assert!(!is_fullscreen(window, rect(0.0, 0.0, 1920.0, 1080.0)));
    for modified in [
        WindowState {
            own_process: true,
            ..window
        },
        WindowState {
            cloaked: true,
            ..window
        },
        WindowState {
            maximized: true,
            captioned: true,
            ..window
        },
        WindowState {
            captioned: true,
            ..window
        },
        WindowState {
            shell: true,
            ..window
        },
        WindowState {
            minimized: true,
            ..window
        },
        WindowState {
            visible: false,
            ..window
        },
    ] {
        assert!(!is_fullscreen(modified, screen));
    }
    assert!(!is_fullscreen(
        WindowState {
            frame: rect(-1920.0, 0.0, 1920.0, 1040.0),
            ..window
        },
        screen
    ));
}
#[test]
fn borderless_fullscreen_can_retain_the_maximized_style() {
    let screen = rect(-1920.0, -200.0, 1920.0, 1080.0);
    let window = WindowState {
        frame: screen,
        visible: true,
        minimized: false,
        maximized: true,
        captioned: false,
        cloaked: false,
        own_process: false,
        shell: false,
    };
    assert!(is_fullscreen(window, screen));
    assert!(!is_fullscreen(
        WindowState {
            frame: rect(-1920.0, -200.0, 1920.0, 1040.0),
            ..window
        },
        screen
    ));
    assert!(!is_fullscreen(
        WindowState {
            captioned: true,
            ..window
        },
        screen
    ));
}
#[test]
fn region_conversion_and_hover_use_the_drawn_shape_not_its_bounding_box() {
    let shape = vec![vec![[0.0, 0.0], [100.0, 0.0], [0.0, 100.0]]];
    for scale in [1.0, 1.25, 1.5, 2.0] {
        let physical = physical_region(&shape, scale).unwrap();
        assert!(region_contains(&physical, 10.0 * scale, 10.0 * scale));
        assert!(!region_contains(&physical, 90.0 * scale, 90.0 * scale));
    }
    assert!(physical_region(&shape, f64::NAN).is_err());
    assert!(physical_region(&[vec![[0.0, 0.0], [f64::INFINITY, 0.0], [0.0, 10.0]]], 1.0).is_err());
}
#[test]
fn explicit_dismissal_closes_an_always_open_card_until_deliberate_reopening() {
    let mut card = CardState::default();
    assert!(card.open(0.0, false));
    card.set_manual(false, true);
    assert!(!card.open(0.0, false));
    card.set_manual(true, false);
    assert!(card.open(0.0, false));
    let preferences: Preferences = serde_json::from_str("{}").unwrap();
    assert_eq!(preferences.text_scale, 1.0);
    assert!(!preferences.reduce_motion && !preferences.reduce_transparency);
    assert!(Preferences {
        text_scale: f64::NAN,
        ..preferences
    }
    .validate()
    .is_err());
}

#[test]
fn hiding_dismisses_manual_pinned_and_always_open_cards_without_replay() {
    for manual in [false, true] {
        for pinned in [false, true] {
            for collapse_idle in [false, true] {
                let mut card = CardState::default();
                card.set_manual(manual, false);
                card.pinned = pinned;
                assert!(card.dismiss_hidden());
                assert!(!card.manual && !card.pinned);
                assert!(card.dismissed);
                assert!(!card.open(0.0, collapse_idle));
                assert!(
                    !card.dismiss_hidden(),
                    "A repeated hidden poll is idempotent"
                );
                card.set_manual(true, false);
                assert!(card.open(0.0, collapse_idle));
            }
        }
    }
}

#[cfg(windows)]
#[test]
fn windows_region_round_trip_clips_corners_and_empty_region_folds_surface() {
    use windows::{
        core::w,
        Win32::{
            Foundation::HWND,
            Graphics::Gdi::{CreateRectRgn, DeleteObject, GetWindowRgn, PtInRegion},
            UI::WindowsAndMessaging::{CreateWindowExW, DestroyWindow, WS_EX_TOOLWINDOW, WS_POPUP},
        },
    };
    struct Fixture(HWND);
    impl Drop for Fixture {
        fn drop(&mut self) {
            unsafe {
                DestroyWindow(self.0).unwrap();
            }
        }
    }
    let fixture = Fixture(unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW,
            w!("STATIC"),
            w!("Tokenotch isolated region fixture"),
            WS_POPUP,
            0,
            0,
            240,
            240,
            None,
            None,
            None,
            None,
        )
        .unwrap()
    });
    let shape = vec![vec![[0.0, 0.0], [100.0, 0.0], [0.0, 100.0]]];
    for scale in [1.0, 1.25, 2.0] {
        let region = physical_region(&shape, scale).unwrap();
        tokenotch_platform::desktop::set_window_region(fixture.0 .0 as isize, &region).unwrap();
        unsafe {
            let actual = CreateRectRgn(0, 0, 0, 0);
            assert_ne!(GetWindowRgn(fixture.0, actual).0, 0);
            assert!(PtInRegion(actual, (10.0 * scale) as i32, (10.0 * scale) as i32).as_bool());
            assert!(!PtInRegion(actual, (90.0 * scale) as i32, (90.0 * scale) as i32).as_bool());
            let _ = DeleteObject(actual.into());
        }
    }
    tokenotch_platform::desktop::set_window_region(fixture.0 .0 as isize, &[]).unwrap();
    unsafe {
        let actual = CreateRectRgn(0, 0, 0, 0);
        assert_eq!(GetWindowRgn(fixture.0, actual).0, 1);
        assert!(!PtInRegion(actual, 10, 10).as_bool());
        let _ = DeleteObject(actual.into());
    }
}
