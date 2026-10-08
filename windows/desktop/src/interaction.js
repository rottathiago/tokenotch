export function visibleFraction(rect, clips) {
  if (!(rect.width > 0 && rect.height > 0)) return 0;
  let left = rect.left, top = rect.top, right = rect.right, bottom = rect.bottom;
  for (const clip of clips) {
    left = Math.max(left,clip.left); top = Math.max(top,clip.top);
    right = Math.min(right,clip.right); bottom = Math.min(bottom,clip.bottom);
  }
  return Math.max(0,right-left)*Math.max(0,bottom-top)/(rect.width*rect.height);
}
export function clippedFraction(element) {
  const clips = [{left:0,top:0,right:window.innerWidth,bottom:window.innerHeight}];
  for (let parent = element.parentElement; parent; parent = parent.parentElement) {
    // Body overflow propagates to the viewport in these fixed-window surfaces.
    if (parent === document.body || parent === document.documentElement) break;
    const style = window.getComputedStyle(parent);
    const clipX = ["hidden","clip","scroll","auto"].includes(style.overflowX);
    const clipY = ["hidden","clip","scroll","auto"].includes(style.overflowY);
    if (!clipX && !clipY) continue;
    const box = parent.getBoundingClientRect();
    const left = box.left+parent.clientLeft, top = box.top+parent.clientTop;
    clips.push({left:clipX ? left : -Infinity,right:clipX ? left+parent.clientWidth : Infinity,
      top:clipY ? top : -Infinity,bottom:clipY ? top+parent.clientHeight : Infinity});
  }
  return visibleFraction(element.getBoundingClientRect(),clips);
}

// Mirrors macOS: rows visible in a deliberately opened card are marked viewed after a
// dwell and stay readable while the card is open; folding the card dismisses every
// non-stopped notice seen during that card session (stopped notices only need viewing).
export class NoticeExposure {
  rows = new Map();
  seen = new Map();
  last = null;
  clear() { this.rows.clear(); this.last = null; }
  update(now, observations, eligible, quick = false) {
    if (!Number.isFinite(now)) throw new Error("Notice exposure time is invalid.");
    if (!eligible) { this.clear(); return []; }
    if (this.last !== null && (now < this.last || now-this.last > 750)) this.rows.clear();
    this.last = now;
    const visible = observations.filter(row => row.fraction >= 0.5 && !row.dismissed && !row.resolved);
    const ids = new Set(visible.map(row => row.id));
    for (const id of this.rows.keys()) if (!ids.has(id)) this.rows.delete(id);
    const result = [];
    for (const row of visible) {
      const state = this.rows.get(row.id) ?? {began:now,viewed:row.viewed};
      this.rows.set(row.id,state);
      if (now-state.began < (quick ? 500 : 1000)) continue;
      this.seen.set(row.id,row.kind);
      if (!state.viewed) {
        state.viewed = true;
        result.push({id:row.id,dismiss:false});
      }
    }
    return result;
  }
  finish() {
    const result = [...this.seen].filter(([,kind]) => kind !== "stopped").map(([id]) => ({id,dismiss:true}));
    this.seen.clear();
    this.clear();
    return result;
  }
}

export function visualPreferences(snapshot) {
  const textScale = (snapshot.preferences.textScale ?? 1) * (snapshot.accessibility?.textScale ?? 1);
  if (!Number.isFinite(textScale) || textScale < 1 || textScale > 10) throw new Error("Unsupported text scaling preference.");
  // Motion follows Tokenotch's own Reduce motion toggle. Windows "Animation effects" is often
  // off (RDP, VMs, best-performance presets) and must not freeze the notch and card.
  return {textScale,reduceMotion:Boolean(snapshot.preferences.reduceMotion),
    reduceStatusMotion:Boolean(snapshot.preferences.reduceMotion),
    reduceTransparency:Boolean(snapshot.preferences.reduceTransparency || snapshot.accessibility?.transparencyEnabled === false)};
}
