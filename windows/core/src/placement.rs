use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Edge {
    Top,
    Right,
    Bottom,
    Left,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

pub fn place(work: Rect, width: f64, height: f64, edge: Edge) -> Option<Rect> {
    if [work.x, work.y, work.width, work.height, width, height]
        .iter()
        .any(|value| !value.is_finite())
        || work.width <= 0.0
        || work.height <= 0.0
        || width <= 0.0
        || height <= 0.0
    {
        return None;
    }
    let width = width.min(work.width);
    let height = height.min(work.height);
    let x = match edge {
        Edge::Left => work.x,
        Edge::Right => work.x + work.width - width,
        _ => work.x + (work.width - width) / 2.0,
    };
    let y = match edge {
        Edge::Top => work.y,
        Edge::Bottom => work.y + work.height - height,
        _ => work.y + (work.height - height) / 2.0,
    };
    Some(Rect {
        x,
        y,
        width,
        height,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_edges_stay_reachable_on_negative_coordinate_monitors() {
        let work = Rect {
            x: -1920.0,
            y: -200.0,
            width: 1920.0,
            height: 1040.0,
        };
        for edge in [Edge::Top, Edge::Right, Edge::Bottom, Edge::Left] {
            let frame = place(work, 340.0, 240.0, edge).unwrap();
            assert!(frame.x >= work.x && frame.x + frame.width <= work.x + work.width);
            assert!(frame.y >= work.y && frame.y + frame.height <= work.y + work.height);
        }
    }

    #[test]
    fn clamping_and_invalid_geometry_are_explicit() {
        let work = Rect {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 80.0,
        };
        assert_eq!(place(work, 340.0, 240.0, Edge::Right), Some(work));
        assert!(place(work, f64::NAN, 20.0, Edge::Right).is_none());
        assert!(place(work, 20.0, -1.0, Edge::Right).is_none());
    }
}
