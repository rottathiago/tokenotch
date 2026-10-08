// Notch and card geometry ported from the macOS NotchLayout, SideNotchShape,
// TooltipShape and NotchCardPlacement. Every measurement is a reference-sheet
// pixel times 44/117, so the Windows notch keeps the macOS proportions.
export const DESIGN_SCALE = 44 / 117;
const px = value => value * DESIGN_SCALE;
export const fontSize = cap => px(cap) / 0.714;

export const layout = Object.freeze({
  curlRadius: px(103), cornerRadius: px(78.8), bodyDepth: px(186),
  pillWidth: px(26), pillHeight: px(210),
  ringDiameter: px(117), trackStroke: px(15.5), progressStroke: px(8), glyphSize: px(46),
  ringLabelGap: px(26.9), activityDiameter: px(72), activityStroke: px(5.5),
  padStart: px(69.5), padEnd: px(50.1),
  gaugeThickness: px(7), gaugeEndZone: px(38),
  labelHeight: 17,
  cardWidth: px(851), cardCorner: px(49.5), cardPadding: px(42.5),
  tailLength: px(75), tailHeight: px(87), tailGap: px(28),
  barHeight: px(10.5), timelineHeight: px(95.7), timelineInset: px(21.3), timelineMeridiemInset: px(42.5),
  blockSpacing: px(21.3), hairline: px(2.5), footerHeight: px(69), provenanceHeight: px(28), rowHeight: px(64),
});
export const cellHeight = layout.ringDiameter + layout.ringLabelGap + layout.labelHeight;
export const gaugeLength = layout.pillHeight - 2 * layout.gaugeEndZone;
export const isVertical = edge => edge === "left" || edge === "right";
export const tooltipDirection = edge => ({ right: "leading", left: "trailing", top: "down", bottom: "up" })[edge];

export function clampScale(value) {
  return Number.isFinite(value) ? Math.min(Math.max(value, 0.75), 1.5) : 1;
}

export function notchSize(edge, scale = 1) {
  const vertical = isVertical(edge);
  const length = 2 * layout.curlRadius + layout.padStart + layout.padEnd + (vertical ? cellHeight : layout.ringDiameter);
  const depth = layout.bodyDepth + (vertical ? 0 : layout.ringLabelGap + layout.labelHeight);
  return { width: (vertical ? depth : length) * scale, height: (vertical ? length : depth) * scale };
}

export function ringCenter(size, edge, scale = 1) {
  const along = (layout.curlRadius + layout.padStart + layout.ringDiameter / 2) * scale;
  return isVertical(edge) ? { x: size.width / 2, y: along } : { x: along, y: layout.bodyDepth / 2 * scale };
}

export function badgeRect(bounds, edge, scale = 1, collapsed = false) {
  if (!collapsed) return bounds;
  const depth = layout.pillWidth * scale;
  const length = layout.pillHeight * scale;
  const midX = bounds.x + bounds.width / 2;
  const midY = bounds.y + bounds.height / 2;
  switch (edge) {
    case "right": return { x: bounds.x + bounds.width - depth, y: midY - length / 2, width: depth, height: length };
    case "left": return { x: bounds.x, y: midY - length / 2, width: depth, height: length };
    case "top": return { x: midX - length / 2, y: bounds.y, width: length, height: depth };
    default: return { x: midX - length / 2, y: bounds.y + bounds.height - depth, width: length, height: depth };
  }
}

const QUARTER_STEPS = 18;
function arc(points, cx, cy, radius, from, to) {
  if (radius <= 0) return;
  for (let index = 1; index <= QUARTER_STEPS; index++) {
    const angle = (from + (to - from) * index / QUARTER_STEPS) * Math.PI / 180;
    points.push([cx + radius * Math.cos(angle), cy + radius * Math.sin(angle)]);
  }
}
function cubic(points, p0, c1, c2, p1, steps = 14) {
  for (let index = 1; index <= steps; index++) {
    const t = index / steps;
    const u = 1 - t;
    points.push([u * u * u * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * p1[0],
      u * u * u * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * p1[1]]);
  }
}

// The canonical shape is written once for a right-edge notch (bezel at maxX)
// and transformed onto the actual edge, as SideNotchShape does.
export function sideNotchPolygon(edge, rect, scale = 1) {
  const vertical = isVertical(edge);
  const depth = vertical ? rect.width : rect.height;
  const length = vertical ? rect.height : rect.width;
  const wanted = Math.max(0, Math.min(layout.cornerRadius * scale, depth / 2));
  const curl = Math.max(0, Math.min(layout.curlRadius * scale, length / 2, depth - wanted));
  const corner = Math.max(0, Math.min(wanted, (length - 2 * curl) / 2));
  const top = curl;
  const bottom = length - curl;
  const points = [[depth, 0]];
  arc(points, depth - curl, 0, curl, 0, 90);
  points.push([corner, top]);
  arc(points, corner, top + corner, corner, 270, 180);
  points.push([0, bottom - corner]);
  arc(points, corner, bottom - corner, corner, 180, 90);
  points.push([depth - curl, bottom]);
  arc(points, depth - curl, length, curl, 270, 360);
  const place = ([u, v]) => {
    switch (edge) {
      case "left": return [depth - u, v];
      case "top": return [v, depth - u];
      case "bottom": return [v, u];
      default: return [u, v];
    }
  };
  return points.map(point => {
    const [x, y] = place(point);
    return [rect.x + x, rect.y + y];
  });
}

export function cardRect(direction, size, scale = 1) {
  const tail = layout.tailLength * scale;
  switch (direction) {
    case "leading": return { x: 0, y: 0, width: size.width - tail, height: size.height };
    case "trailing": return { x: tail, y: 0, width: size.width - tail, height: size.height };
    case "down": return { x: 0, y: tail, width: size.width, height: size.height - tail };
    default: return { x: 0, y: 0, width: size.width, height: size.height - tail };
  }
}

export function clampTailOffset(direction, size, offset, scale = 1) {
  const card = cardRect(direction, size, scale);
  const extent = direction === "leading" || direction === "trailing" ? card.height : card.width;
  const limit = Math.max(0, extent / 2 - layout.cardCorner * scale - layout.tailHeight * scale / 2);
  return Math.min(Math.max(offset, -limit), limit);
}

export function tooltipTip(direction, size, offset, scale = 1) {
  const clamped = clampTailOffset(direction, size, offset, scale);
  switch (direction) {
    case "leading": return [size.width, size.height / 2 + clamped];
    case "trailing": return [0, size.height / 2 + clamped];
    case "down": return [size.width / 2 + clamped, 0];
    default: return [size.width / 2 + clamped, size.height];
  }
}

export function roundedRectPolygon(rect, radius) {
  const r = Math.max(0, Math.min(radius, rect.width / 2, rect.height / 2));
  const { x, y, width, height } = rect;
  const points = [[x + r, y]];
  points.push([x + width - r, y]);
  arc(points, x + width - r, y + r, r, 270, 360);
  points.push([x + width, y + height - r]);
  arc(points, x + width - r, y + height - r, r, 0, 90);
  points.push([x + r, y + height]);
  arc(points, x + r, y + height - r, r, 90, 180);
  points.push([x, y + r]);
  arc(points, x + r, y + r, r, 180, 270);
  return points;
}

// The card body and its curved pointer, as two polygons whose union is the
// TooltipShape. Native windows clip their hit region to the same polygons.
export function tooltipPolygons(direction, size, offset, scale = 1) {
  const card = cardRect(direction, size, scale);
  const tip = tooltipTip(direction, size, offset, scale);
  const half = layout.tailHeight * scale / 2;
  const length = layout.tailLength * scale;
  let a, b, ca, cb, ta, tb;
  if (direction === "leading" || direction === "trailing") {
    const sign = direction === "leading" ? 1 : -1;
    const base = tip[0] - sign * length;
    a = [base, tip[1] - half]; b = [base, tip[1] + half];
    ca = [base, tip[1] - half / 2]; cb = [base, tip[1] + half / 2];
    ta = [tip[0] - sign * length * 0.42, tip[1] - half * 0.24]; tb = [ta[0], tip[1] + half * 0.24];
  } else {
    const sign = direction === "down" ? -1 : 1;
    const base = tip[1] - sign * length;
    a = [tip[0] - half, base]; b = [tip[0] + half, base];
    ca = [tip[0] - half / 2, base]; cb = [tip[0] + half / 2, base];
    ta = [tip[0] - half * 0.24, tip[1] - sign * length * 0.42]; tb = [tip[0] + half * 0.24, ta[1]];
  }
  const tail = [a];
  cubic(tail, a, ca, ta, tip);
  cubic(tail, tip, tb, cb, b);
  return { card, tip, polygons: [roundedRectPolygon(card, layout.cardCorner * scale), tail] };
}

export function pathData(polygons) {
  return polygons.map(points => `M${points.map(([x, y]) => `${x.toFixed(2)},${y.toFixed(2)}`).join("L")}Z`).join("");
}

// NotchCardPlacement in Windows screen coordinates (y grows downward).
export function cardPlacement({ notch, ringCenter: center, edge, work, contentHeight, scale = 1 }) {
  const usable = { x: work.x + 8, y: work.y + 8, width: work.width - 16, height: work.height - 16 };
  const vertical = isVertical(edge);
  const tail = layout.tailLength * scale;
  const gap = layout.tailGap * scale;
  const space = edge === "right" ? notch.x - usable.x - gap - tail :
    edge === "left" ? usable.x + usable.width - (notch.x + notch.width) - gap - tail : usable.width;
  const width = Math.min(layout.cardWidth * scale, Math.max(80, space), usable.width - (vertical ? tail : 0));
  const available = edge === "top" ? usable.y + usable.height - (notch.y + notch.height) - gap - tail :
    edge === "bottom" ? notch.y - usable.y - gap - tail : usable.height;
  const bodyHeight = Math.min(Math.ceil(contentHeight), Math.max(80, available), usable.height - (vertical ? 0 : tail));
  const size = { width: width + (vertical ? tail : 0), height: bodyHeight + (vertical ? 0 : tail) };
  let x, y;
  switch (edge) {
    case "right": x = notch.x - gap - size.width; y = center.y - size.height / 2; break;
    case "left": x = notch.x + notch.width + gap; y = center.y - size.height / 2; break;
    case "top": x = center.x - size.width / 2; y = notch.y + notch.height + gap; break;
    default: x = center.x - size.width / 2; y = notch.y - gap - size.height;
  }
  x = Math.min(Math.max(x, usable.x), usable.x + usable.width - size.width);
  y = Math.min(Math.max(y, usable.y), usable.y + usable.height - size.height);
  const frame = { x, y, ...size };
  const direction = tooltipDirection(edge);
  const tailOffset = vertical ? center.y - (y + size.height / 2) : center.x - (x + size.width / 2);
  return { frame, direction, tailOffset };
}
