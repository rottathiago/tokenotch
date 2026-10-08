use crate::storage::Result;
use std::collections::{BTreeMap, BTreeSet};
use tokenotch_core::placement::Rect;

#[derive(Default)]
pub struct DisplayRegistry {
    labels: BTreeMap<String, String>,
    next: u64,
}
pub struct Displays {
    pub labels: Vec<String>,
    pub removed: Vec<String>,
}
impl DisplayRegistry {
    pub fn reconcile(&mut self, identifiers: &[String]) -> Result<Displays> {
        let present: BTreeSet<_> = identifiers.iter().collect();
        if identifiers.is_empty() || present.len() != identifiers.len() {
            return Err("Display identifiers are unavailable or ambiguous.".into());
        }
        let removed = self
            .labels
            .iter()
            .filter(|(id, _)| !present.contains(id))
            .map(|(_, label)| label.clone())
            .collect();
        self.labels.retain(|id, _| present.contains(id));
        let mut labels = Vec::new();
        for id in identifiers {
            if !self.labels.contains_key(id) {
                // Labels are never reused: a removed display's window is still closing
                // asynchronously and Tauri keeps resolving its label until it is destroyed.
                let label = if self.next == 0 {
                    "widget".into()
                } else {
                    format!("widget-{}", self.next)
                };
                self.next += 1;
                self.labels.insert(id.clone(), label);
            }
            labels.push(self.labels[id].clone());
        }
        Ok(Displays { labels, removed })
    }
    pub fn label(&self, id: &str) -> Option<&str> {
        self.labels.get(id).map(String::as_str)
    }
}

#[derive(Clone, Copy)]
pub struct WindowState {
    pub frame: Rect,
    pub visible: bool,
    pub minimized: bool,
    pub maximized: bool,
    pub captioned: bool,
    pub cloaked: bool,
    pub own_process: bool,
    pub shell: bool,
}
pub fn is_fullscreen(window: WindowState, screen: Rect) -> bool {
    // Borderless fullscreen apps can retain WS_MAXIMIZE; a title bar or
    // work-area-only bounds, not that flag alone, distinguish ordinary windows.
    window.frame.valid()
        && screen.valid()
        && window.visible
        && !window.minimized
        && !window.captioned
        && !window.cloaked
        && !window.own_process
        && !window.shell
        && window.frame.x <= screen.x
        && window.frame.y <= screen.y
        && window.frame.x + window.frame.width >= screen.x + screen.width
        && window.frame.y + window.frame.height >= screen.y + screen.height
}

pub fn physical_region(polygons: &[Vec<[f64; 2]>], factor: f64) -> Result<Vec<Vec<(i32, i32)>>> {
    if !factor.is_finite() || factor <= 0.0 || polygons.is_empty() || polygons.len() > 8 {
        return Err("Unsupported widget region or display scale.".into());
    }
    polygons
        .iter()
        .map(|polygon| {
            if !(3..=2048).contains(&polygon.len()) {
                return Err("Unsupported widget region.".into());
            }
            polygon
                .iter()
                .map(|[x, y]| {
                    if !x.is_finite()
                        || !y.is_finite()
                        || x.abs() > 20_000.0
                        || y.abs() > 20_000.0
                        || (x * factor).abs() > f64::from(i32::MAX) - 1.0
                        || (y * factor).abs() > f64::from(i32::MAX) - 1.0
                    {
                        return Err("Unsupported widget region coordinates.".into());
                    }
                    Ok(((x * factor).round() as i32, (y * factor).round() as i32))
                })
                .collect()
        })
        .collect()
}
pub fn region_contains(polygons: &[Vec<(i32, i32)>], x: f64, y: f64) -> bool {
    if !x.is_finite() || !y.is_finite() {
        return false;
    }
    polygons.iter().any(|polygon| {
        let mut inside = false;
        for index in 0..polygon.len() {
            let (a, b) = (polygon[index], polygon[(index + 1) % polygon.len()]);
            let (ax, ay, bx, by) = (
                f64::from(a.0),
                f64::from(a.1),
                f64::from(b.0),
                f64::from(b.1),
            );
            if (ay > y) != (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax {
                inside = !inside;
            }
        }
        inside
    })
}
