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
    place_at(work, width, height, edge, 0.5)
}

impl Rect {
    pub fn valid(&self) -> bool {
        [
            self.x,
            self.y,
            self.width,
            self.height,
            self.x + self.width,
            self.y + self.height,
        ]
        .iter()
        .all(|v| v.is_finite())
            && self.width > 0.0
            && self.height > 0.0
    }
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && x < self.x + self.width && y >= self.y && y < self.y + self.height
    }
}

/// Keep the whole recovery window reachable after a work-area or display change.
/// Callers put the primary display first for the completely offscreen case.
pub fn recover_window(frame: Rect, works: &[Rect]) -> Option<Rect> {
    if !frame.valid() || works.is_empty() || works.iter().any(|work| !work.valid()) {
        return None;
    }
    let area = |work: &Rect| {
        ((frame.x + frame.width).min(work.x + work.width) - frame.x.max(work.x)).max(0.0)
            * ((frame.y + frame.height).min(work.y + work.height) - frame.y.max(work.y)).max(0.0)
    };
    let mut work = &works[0];
    for candidate in &works[1..] {
        if area(candidate) > area(work) {
            work = candidate;
        }
    }
    let width = frame.width.min(work.width);
    let height = frame.height.min(work.height);
    Some(Rect {
        x: frame.x.clamp(work.x, work.x + work.width - width),
        y: frame.y.clamp(work.y, work.y + work.height - height),
        width,
        height,
    })
}

/// macOS NotchLayout reference pixels are scaled by 44/117. These mirror
/// windows/desktop/src/geometry.js, which draws the same shapes.
const DESIGN_SCALE: f64 = 44.0 / 117.0;
const fn px(value: f64) -> f64 {
    value * DESIGN_SCALE
}
const CURL_RADIUS: f64 = px(103.0);
const BODY_DEPTH: f64 = px(186.0);
const RING_DIAMETER: f64 = px(117.0);
const RING_LABEL_GAP: f64 = px(26.9);
const PAD_START: f64 = px(69.5);
const PAD_END: f64 = px(50.1);
const LABEL_HEIGHT: f64 = 17.0;
const CARD_WIDTH: f64 = px(851.0);
const TAIL_LENGTH: f64 = px(75.0);
const TAIL_GAP: f64 = px(28.0);

impl Edge {
    pub fn is_vertical(self) -> bool {
        matches!(self, Edge::Left | Edge::Right)
    }
    /// The way the card's tail points, as named by the frontend shape builder.
    pub fn tooltip_direction(self) -> &'static str {
        match self {
            Edge::Right => "leading",
            Edge::Left => "trailing",
            Edge::Top => "down",
            Edge::Bottom => "up",
        }
    }
}

/// The resting notch: ring, label and the flares that join it to the edge.
pub fn notch_size(edge: Edge, scale: f64) -> (f64, f64) {
    let cell = RING_DIAMETER + RING_LABEL_GAP + LABEL_HEIGHT;
    let length = 2.0 * CURL_RADIUS
        + PAD_START
        + PAD_END
        + if edge.is_vertical() {
            cell
        } else {
            RING_DIAMETER
        };
    let depth = BODY_DEPTH
        + if edge.is_vertical() {
            0.0
        } else {
            RING_LABEL_GAP + LABEL_HEIGHT
        };
    if edge.is_vertical() {
        (depth * scale, length * scale)
    } else {
        (length * scale, depth * scale)
    }
}

pub fn ring_center(edge: Edge, notch: Rect, scale: f64) -> (f64, f64) {
    let along = (CURL_RADIUS + PAD_START + RING_DIAMETER / 2.0) * scale;
    if edge.is_vertical() {
        (notch.x + notch.width / 2.0, notch.y + along)
    } else {
        (notch.x + along, notch.y + BODY_DEPTH / 2.0 * scale)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CardFrame {
    pub frame: Rect,
    /// Offset of the tail tip from the card's centre along the notch edge.
    pub tail_offset: f64,
    /// The region the pointer may cross between the notch and the card tail.
    pub bridge: Rect,
}

/// macOS NotchCardPlacement in screen coordinates whose y grows downward.
pub fn card_frame(
    notch: Rect,
    ring: (f64, f64),
    edge: Edge,
    work: Rect,
    content_height: f64,
    scale: f64,
) -> Option<CardFrame> {
    if [
        notch.x,
        notch.y,
        notch.width,
        notch.height,
        ring.0,
        ring.1,
        work.x,
        work.y,
        work.width,
        work.height,
        content_height,
        scale,
    ]
    .iter()
    .any(|value| !value.is_finite())
        || scale <= 0.0
        || work.width <= 16.0
        || work.height <= 16.0
    {
        return None;
    }
    if !notch.valid() || content_height <= 0.0 {
        return None;
    }
    let inset = (8.0 * scale.max(1.0)).min(work.width.min(work.height) / 4.0);
    let usable = Rect {
        x: work.x + inset,
        y: work.y + inset,
        width: work.width - 2.0 * inset,
        height: work.height - 2.0 * inset,
    };
    let tail = TAIL_LENGTH * scale;
    if (edge.is_vertical() && usable.width <= tail)
        || (!edge.is_vertical() && usable.height <= tail)
    {
        return None;
    }
    let gap = TAIL_GAP * scale;
    let vertical = edge.is_vertical();
    let space = match edge {
        Edge::Right => notch.x - usable.x - gap - tail,
        Edge::Left => usable.x + usable.width - (notch.x + notch.width) - gap - tail,
        _ => usable.width,
    };
    let width = (CARD_WIDTH * scale)
        .min(space.max(80.0))
        .min(usable.width - if vertical { tail } else { 0.0 })
        .max(1.0);
    let available = match edge {
        Edge::Top => usable.y + usable.height - (notch.y + notch.height) - gap - tail,
        Edge::Bottom => notch.y - usable.y - gap - tail,
        _ => usable.height,
    };
    let body = content_height
        .ceil()
        .min(available.max(80.0))
        .min(usable.height - if vertical { 0.0 } else { tail })
        .max(1.0);
    let size = (
        width + if vertical { tail } else { 0.0 },
        body + if vertical { 0.0 } else { tail },
    );
    let (mut x, mut y) = match edge {
        Edge::Right => (notch.x - gap - size.0, ring.1 - size.1 / 2.0),
        Edge::Left => (notch.x + notch.width + gap, ring.1 - size.1 / 2.0),
        Edge::Top => (ring.0 - size.0 / 2.0, notch.y + notch.height + gap),
        Edge::Bottom => (ring.0 - size.0 / 2.0, notch.y - gap - size.1),
    };
    x = x.max(usable.x).min(usable.x + usable.width - size.0);
    y = y.max(usable.y).min(usable.y + usable.height - size.1);
    let frame = Rect {
        x,
        y,
        width: size.0,
        height: size.1,
    };
    let tail_offset = if vertical {
        ring.1 - (y + size.1 / 2.0)
    } else {
        ring.0 - (x + size.0 / 2.0)
    };
    let limit =
        ((if vertical { body } else { width }) / 2.0 - px(49.5) * scale - px(87.0) * scale / 2.0)
            .max(0.0);
    let tail_offset = tail_offset.clamp(-limit, limit);
    let tip_along = if vertical {
        y + size.1 / 2.0 + tail_offset
    } else {
        x + size.0 / 2.0 + tail_offset
    };
    let (anchor, tip) = match edge {
        Edge::Right => ((notch.x, ring.1), (x + size.0, tip_along)),
        Edge::Left => ((notch.x + notch.width, ring.1), (x, tip_along)),
        Edge::Top => ((ring.0, notch.y + notch.height), (tip_along, y)),
        Edge::Bottom => ((ring.0, notch.y), (tip_along, y + size.1)),
    };
    let slack = 6.0 * scale.max(1.0);
    let bridge = Rect {
        x: anchor.0.min(tip.0) - slack,
        y: anchor.1.min(tip.1) - slack,
        width: (anchor.0 - tip.0).abs() + 2.0 * slack,
        height: (anchor.1 - tip.1).abs() + 2.0 * slack,
    };
    Some(CardFrame {
        frame,
        tail_offset,
        bridge,
    })
}

pub fn place_at(work: Rect, width: f64, height: f64, edge: Edge, fraction: f64) -> Option<Rect> {
    if !fraction.is_finite() || !(0.0..=1.0).contains(&fraction) {
        return None;
    }
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
        _ => work.x + (work.width - width) * fraction,
    };
    let y = match edge {
        Edge::Top => work.y,
        Edge::Bottom => work.y + work.height - height,
        _ => work.y + (work.height - height) * fraction,
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
    fn notch_size_matches_the_macos_reference_sheet() {
        let (width, height) = notch_size(Edge::Right, 1.0);
        assert!((width - 69.949).abs() < 0.01, "{width}");
        assert!((height - 193.57).abs() < 0.05, "{height}");
        let (top_width, top_height) = notch_size(Edge::Top, 2.0);
        assert!((top_width - 2.0 * (height - 27.11)).abs() < 0.1);
        assert!((top_height - 2.0 * (width + 10.114 + 17.0)).abs() < 0.1);
    }

    #[test]
    fn card_sits_beside_the_notch_with_the_tail_on_the_ring() {
        let work = Rect {
            x: -1920.0,
            y: 0.0,
            width: 1920.0,
            height: 1040.0,
        };
        for edge in [Edge::Right, Edge::Left, Edge::Top, Edge::Bottom] {
            let (width, height) = notch_size(edge, 1.5);
            let notch = place(work, width, height, edge).unwrap();
            let ring = ring_center(edge, notch, 1.5);
            let card = card_frame(notch, ring, edge, work, 500.0, 1.5).unwrap();
            let frame = card.frame;
            assert!(frame.x >= work.x && frame.x + frame.width <= work.x + work.width);
            assert!(frame.y >= work.y && frame.y + frame.height <= work.y + work.height);
            match edge {
                Edge::Right => assert!(frame.x + frame.width <= notch.x),
                Edge::Left => assert!(frame.x >= notch.x + notch.width),
                Edge::Top => assert!(frame.y >= notch.y + notch.height),
                Edge::Bottom => assert!(frame.y + frame.height <= notch.y),
            }
            let centre = if edge.is_vertical() {
                frame.y + frame.height / 2.0
            } else {
                frame.x + frame.width / 2.0
            };
            let target = if edge.is_vertical() { ring.1 } else { ring.0 };
            assert!((centre + card.tail_offset - target).abs() < 0.001);
            let midpoint = match edge {
                Edge::Right => ((notch.x + frame.x + frame.width) / 2.0, ring.1),
                Edge::Left => ((notch.x + notch.width + frame.x) / 2.0, ring.1),
                Edge::Top => (ring.0, (notch.y + notch.height + frame.y) / 2.0),
                Edge::Bottom => (ring.0, (notch.y + frame.y + frame.height) / 2.0),
            };
            assert!(card.bridge.contains(midpoint.0, midpoint.1), "{edge:?}");
        }
    }

    #[test]
    fn tall_cards_and_invalid_geometry_are_bounded() {
        let work = Rect {
            x: 0.0,
            y: 0.0,
            width: 1280.0,
            height: 600.0,
        };
        let (width, height) = notch_size(Edge::Right, 1.0);
        let notch = place(work, width, height, Edge::Right).unwrap();
        let ring = ring_center(Edge::Right, notch, 1.0);
        let card = card_frame(notch, ring, Edge::Right, work, 5000.0, 1.0).unwrap();
        assert!(card.frame.height <= 584.0 && card.frame.y >= 8.0);
        assert!(card_frame(notch, ring, Edge::Right, work, f64::NAN, 1.0).is_none());
        assert!(card_frame(notch, ring, Edge::Right, work, 100.0, 0.0).is_none());
    }

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
