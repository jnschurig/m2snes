// The sprite editor's page script (sprite-pixel-editor F3-F6). The model and
// the editable state come from /api/model, and Save posts the state back to
// /api/save; nothing here holds ROM bytes.
//
// Sections:
//   Data    - the model and state as the page works on them (tile pixels with
//             edits applied, frame names, where each tile is used), and the
//             edits to them.
//   History - undo and redo over every edit.
//   Render  - colours and drawing, as the cart draws them under `full`
//             (`swatch_full.spritePng`): kept free of the UI so a later
//             background editor can reuse it.
//   UI      - the list, the zoomed frame and its tools, the frame, palette,
//             tile and conflict panels, the uses strip, and saving.
"use strict";

const $ = (sel, root = document) => root.querySelector(sel);
const el = (tag, props = {}, ...kids) => {
  const e = Object.assign(document.createElement(tag), props);
  for (const k of kids) if (k != null) e.append(k);
  return e;
};
const hex2 = (n) => n.toString(16).toUpperCase().padStart(2, "0");
const css = (rgb) => "#" + rgb.toString(16).padStart(6, "0");
/** `rgb` as the SNES shows it: each channel cut to 5 bits (`colors.bgr555`), widened as `colors.rgb888` does. */
const to555 = (rgb) => {
  const f = (v) => { v >>= 3; return (v << 3) | (v >> 2); };
  return (f(rgb >> 16) << 16) | (f((rgb >> 8) & 255) << 8) | f(rgb & 255);
};

// ---- Data -----------------------------------------------------------------

// What each OBJ palette is for (`swatch_full.obj_slots`).
const PALETTE_NAMES = [
  "shell: robots, Metroid shells", "Samus's suit", "the Queen; a hit Metroid's body",
  "frozen, flash", "Metroid body, green parts", "organic: most enemies",
  "beams, missiles, wave beam", "Samus's visor",
];
// Above this many copies, or frames using it, an edit to a tile reaches far.
const WIDE_COPIES = 8;
const WIDE_FRAMES = 16;

const D = {
  model: null,
  state: null,
  /** Per tile: its 64 original 2bpp indices. */
  original: [],
  /** Tile index by key. */
  byKey: new Map(),
  /** key -> { palette: number|null, pixels: Map<y*8+x, index> } */
  edits: new Map(),
  /** "set:id" -> { set, id, name, group, sheet } from the state's frames. */
  frameMeta: new Map(),
  /** Per tile: the frame indices that draw it. */
  framesOf: [],
  viewByName: new Map(),

  load(model, state) {
    this.model = model;
    this.state = state;
    this.original = model.tiles.map((t) => decode2bpp(t.gb));
    model.tiles.forEach((t, i) => this.byKey.set(t.key, i));
    model.views.forEach((v, i) => this.viewByName.set(v.name, i));
    for (const e of state.edits) {
      const pixels = new Map();
      for (const p of e.pixels) pixels.set(p.y * 8 + p.x, p.index);
      this.edits.set(e.key, { palette: e.palette ?? null, pixels });
    }
    for (const f of state.frames) this.frameMeta.set(`${f.set}:${f.id}`, { ...f });
    this.indexUses();
  },

  indexUses() {
    this.framesOf = this.model.tiles.map(() => []);
    this.model.frames.forEach((f, fi) => {
      const vi = this.frameView(f);
      if (vi == null) return;
      const view = this.model.views[vi];
      const seen = new Set();
      for (const p of f.parts) {
        const s = view.vram[p.tile];
        if (s && !seen.has(s.tile)) { seen.add(s.tile); this.framesOf[s.tile].push(fi); }
      }
    });
  },

  meta(f) { return this.frameMeta.get(`${f.set}:${f.id}`); },
  /** A frame's view: the state's sheet choice, else the model's. */
  frameView(f) {
    const m = this.meta(f);
    if (m && m.sheet) return this.viewByName.get(m.sheet) ?? null;
    return f.view;
  },
  frameName(f) {
    const m = this.meta(f);
    return (m && m.name) || f.name || null;
  },
  frameGroup(f) {
    const m = this.meta(f);
    if (m && m.group) return m.group;
    if (f.group) return f.group;
    const vi = this.frameView(f);
    return vi == null ? null : this.model.views[vi].title;
  },
  frameLabel(f) {
    const n = this.frameName(f);
    return n ?? `${f.set} $${hex2(f.id)}`;
  },
  /** Sets a frame's `name`, `group` or `sheet` (empty clears it); returns the old value. */
  setMeta(f, field, value) {
    const k = `${f.set}:${f.id}`;
    const m = this.frameMeta.get(k) ?? { set: f.set, id: f.id, name: null, group: null, sheet: null };
    const old = m[field] ?? null;
    m[field] = value || null;
    if (!m.name && !m.group && !m.sheet) this.frameMeta.delete(k); else this.frameMeta.set(k, m);
    if (field === "sheet") this.indexUses();
    return old;
  },

  /** Tile `ti`'s 64 4bpp indices, its edits applied. */
  indices(ti) {
    const e = this.edits.get(this.model.tiles[ti].key);
    if (!e || e.pixels.size === 0) return this.original[ti];
    const out = this.original[ti].slice();
    for (const [n, idx] of e.pixels) out[n] = idx;
    return out;
  },
  /** The slot a loaded VRAM tile is drawn in: the edit's palette choice, else the derived one. */
  slotOf(s) {
    const c = this.chosen(s.tile);
    return c != null ? c : s.slot;
  },
  /** Tile `ti`'s palette choice, or null for its derived slots. */
  chosen(ti) {
    const e = this.edits.get(this.model.tiles[ti].key);
    return e ? e.palette : null;
  },
  edited(ti) {
    const e = this.edits.get(this.model.tiles[ti].key);
    return !!e && e.pixels.size > 0;
  },
  entry(ti) {
    const key = this.model.tiles[ti].key;
    let e = this.edits.get(key);
    if (!e) { e = { palette: null, pixels: new Map() }; this.edits.set(key, e); }
    return e;
  },
  tidy(ti) {
    const key = this.model.tiles[ti].key;
    const e = this.edits.get(key);
    if (e && e.palette == null && e.pixels.size === 0) this.edits.delete(key);
  },
  /** Sets pixel `n` of tile `ti` to `index`; returns the old index. Setting the original drops the edit. */
  setPixel(ti, n, index) {
    const old = this.indices(ti)[n];
    const e = this.entry(ti);
    if (index === this.original[ti][n]) e.pixels.delete(n); else e.pixels.set(n, index);
    this.tidy(ti);
    return old;
  },
  /** Sets tile `ti`'s palette choice (null: derived); returns the old one. */
  setPalette(ti, p) {
    const e = this.entry(ti);
    const old = e.palette;
    e.palette = p;
    this.tidy(ti);
    return old;
  },
  /** The tile's derived slots, one per distinct copy slot. */
  derived(ti) { return [...new Set(this.model.tiles[ti].copies.map((c) => c.slot))]; },

  /** The state as `/api/save` takes it, in a fixed order so equal states compare equal. */
  serialize() {
    const edits = [...this.edits].filter(([, e]) => e.palette != null || e.pixels.size > 0)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([key, e]) => ({ key, palette: e.palette,
        pixels: [...e.pixels].sort(([a], [b]) => a - b).map(([n, index]) => ({ x: n & 7, y: n >> 3, index })) }));
    const order = (f) => (f.set === "samus" ? 0 : 1) * 0x10000 + f.id;
    const frames = [...this.frameMeta.values()].filter((f) => f.name || f.group || f.sheet)
      .sort((a, b) => order(a) - order(b))
      .map((f) => ({ set: f.set, id: f.id, name: f.name || null, group: f.group || null, sheet: f.sheet || null }));
    return { colors: this.state.colors, edits, frames };
  },
};

function decode2bpp(hex) {
  const b = new Uint8Array(16);
  for (let i = 0; i < 16; i++) b[i] = parseInt(hex.substr(i * 2, 2), 16);
  const out = new Uint8Array(64);
  for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) {
    const s = 7 - x;
    out[y * 8 + x] = ((b[y * 2] >> s) & 1) | (((b[y * 2 + 1] >> s) & 1) << 1);
  }
  return out;
}

// ---- History ----------------------------------------------------------------

/** Undo and redo. An action is `{ label, undo(), redo() }`, already applied when pushed. */
const History = {
  done: [],
  undone: [],
  push(a) { this.done.push(a); this.undone = []; changed(); },
  undo() { const a = this.done.pop(); if (!a) return; a.undo(); this.undone.push(a); refreshAll(); },
  redo() { const a = this.undone.pop(); if (!a) return; a.redo(); this.done.push(a); refreshAll(); },
};

// ---- Render ---------------------------------------------------------------

/** Preview settings: frozen, damage step 0-3, OBP1 flash, suit 0 Power / 1 Varia. */
const preview = { frozen: false, damage: 0, flash: false, suit: 0 };

const Render = {
  /** The page a view's parts read, under the preview. */
  page(view) {
    const P = D.model.pages;
    const p = P[view.page];
    if (p === P.samus) return p;
    if (preview.frozen) return P.frozen;
    // Only a Metroid reads the hit page (`EnemyObjPage`); palette 2's colours
    // change for everyone, which `rows` shows.
    if (preview.damage > 0 && view.name.startsWith("gfx_met")) return P.metroid_hit;
    return p;
  },
  /** A part's OBJ palette: `full_slots.objAttr` through the page table. */
  palette(page, attr, slot) {
    const a = preview.flash ? attr | 0x10 : attr;
    return (D.model.obj_attr[page * 256 + ((a & 0xF0) | slot)] >> 1) & 7;
  },
  /**
   * OBJ palette `p`'s colour rows ([variant][shade] 0xRRGGBB) under the
   * preview: the state's own arrays, so an edit writes through them.
   */
  rows(p, suit) {
    const c = D.state.colors;
    const [suitPal, visorPal] = D.model.samus_palettes;
    if (p === suitPal) return c.suits[suit][0];
    if (p === visorPal) return c.suits[suit][1];
    if (p === 2 && preview.damage > 0 && !preview.frozen) return c.damage[preview.damage - 1];
    return c.obj[p];
  },
  /** Which table `rows(p, suit)` is, in words. */
  rowsName(p, suit) {
    const [suitPal, visorPal] = D.model.samus_palettes;
    if (p === suitPal || p === visorPal) return suit ? "Varia" : "Power";
    if (p === 2 && preview.damage > 0 && !preview.frozen) return `damage step ${preview.damage}`;
    return null;
  },
  /** Where CGRAM entry `i` lives in `rows`: variant `i >> 2`, shade field `i & 3` of OBP0. */
  cell(i) { return [i >> 2, (D.model.obp0 >> (2 * (i & 3))) & 3]; },
  colour(rows, i) {
    const [v, s] = this.cell(i);
    return rows[v][s];
  },
  /** All 16 entries of palette `p` (entry 0 is transparent but listed). */
  entries(p, suit) {
    const rows = this.rows(p, suit);
    return Array.from({ length: 16 }, (_, i) => this.colour(rows, i));
  },

  /** A view as a frame: every loaded tile at its VRAM place, sixteen to a row. */
  sheetParts(view) {
    const parts = [];
    view.vram.forEach((s, t) => { if (s) parts.push({ x: (t % 16) * 8, y: (t >> 4) * 8, tile: t, attr: 0 }); });
    return parts;
  },

  /**
   * Draws `parts` with `view` loaded, as `spritePng` does: flips, earlier
   * parts over later ones, colour 0 transparent. Returns the image (-1 =
   * transparent), each shown pixel's index and palette, and per pixel the
   * first part whose box covers it.
   */
  frame(parts, view, suit) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const q of parts) {
      if (!view.vram[q.tile]) continue;
      x0 = Math.min(x0, q.x); y0 = Math.min(y0, q.y);
      x1 = Math.max(x1, q.x + 8); y1 = Math.max(y1, q.y + 8);
    }
    if (x0 === Infinity) return null;
    const pad = 2;
    const w = x1 - x0 + 2 * pad, h = y1 - y0 + 2 * pad;
    const px = new Int32Array(w * h).fill(-1);
    const ix = new Int8Array(w * h).fill(-1);
    const pl = new Int8Array(w * h).fill(-1);
    const cover = new Int16Array(w * h).fill(-1);
    const page = this.page(view);
    const boxes = [];
    for (let k = parts.length - 1; k >= 0; k--) {
      const q = parts[k];
      const s = view.vram[q.tile];
      if (!s) continue;
      const idx = D.indices(s.tile);
      const pal = this.palette(page, q.attr, D.slotOf(s));
      const rows = this.rows(pal, suit);
      const ox = q.x - x0 + pad, oy = q.y - y0 + pad;
      boxes[k] = { x: ox, y: oy };
      for (let r = 0; r < 8; r++) for (let c = 0; c < 8; c++) {
        const at = (oy + r) * w + ox + c;
        cover[at] = k;
        const sr = q.attr & 0x40 ? 7 - r : r;
        const sc = q.attr & 0x20 ? 7 - c : c;
        const i = idx[sr * 8 + sc];
        if (i !== 0) { px[at] = this.colour(rows, i); ix[at] = i; pl[at] = pal; }
      }
    }
    return { w, h, px, ix, pl, cover, boxes, page };
  },

  /** One tile alone, in palette `pal`. */
  tile(ti, pal, suit) {
    const idx = D.indices(ti);
    const rows = this.rows(pal, suit);
    const px = new Int32Array(64);
    for (let n = 0; n < 64; n++) px[n] = idx[n] === 0 ? -1 : this.colour(rows, idx[n]);
    return { w: 8, h: 8, px };
  },

  /** `img` onto a new canvas at integer `zoom`, transparent as `ground`. */
  canvas(img, zoom, ground) {
    const cv = el("canvas", { width: img.w * zoom, height: img.h * zoom });
    this.paint(cv, img, zoom, ground);
    return cv;
  },
  paint(cv, img, zoom, ground) {
    const small = new OffscreenCanvas(img.w, img.h);
    const sc = small.getContext("2d");
    const data = sc.createImageData(img.w, img.h);
    for (let i = 0; i < img.px.length; i++) {
      const c = img.px[i] < 0 ? ground : img.px[i];
      data.data[i * 4] = c >> 16; data.data[i * 4 + 1] = (c >> 8) & 255; data.data[i * 4 + 2] = c & 255; data.data[i * 4 + 3] = 255;
    }
    sc.putImageData(data, 0, 0);
    const ctx = cv.getContext("2d");
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(small, 0, 0, img.w * zoom, img.h * zoom);
  },
};

// ---- UI -------------------------------------------------------------------

const GROUND = 0x22262e;
const TOOLS = [
  { id: "select", label: "Select", key: "v", title: "Select a tile (V)" },
  { id: "pencil", label: "Pencil", key: "b", title: "Paint the chosen colour (B); Alt-click picks a colour" },
  { id: "picker", label: "Eyedropper", key: "i", title: "Pick a pixel's colour (I)" },
];
const ui = {
  /** { kind: "frame", index } or { kind: "view", index } */
  open: null,
  zoom: 8,
  grid: true,
  tool: "select",
  /** The pencil's index (0 transparent). */
  index: 1,
  /** Mark the frame's pixels in the chosen palette entry. */
  highlight: true,
  /** The selected tile: its model index, and the part it was picked in. */
  tile: null,
  part: null,
  palette: 5,
  img: null,
  canvas: null,
  filter: "",
  /** The pencil stroke being drawn: "tile:n" -> { ti, n, before, after }. */
  stroke: null,
  /** The JSON of the state as last loaded or saved. */
  saved: "",
  dirty: false,
};

/** What the centre shows: parts, the view they're drawn with, and its suit. */
function opened() {
  if (!ui.open) return null;
  if (ui.open.kind === "view") {
    const view = D.model.views[ui.open.index];
    return { parts: Render.sheetParts(view), view, suit: view.suit, title: view.title, sub: view.name };
  }
  const f = D.model.frames[ui.open.index];
  const vi = D.frameView(f);
  if (vi == null) return { frame: f, title: D.frameLabel(f), sub: `${f.set} $${hex2(f.id)}`, unresolved: true };
  let view = D.model.views[vi];
  // The suit toggle swaps Samus's sheet as well as her palettes.
  if (view.page === "samus") {
    const want = D.model.views.find((v) => v.page === "samus" && v.suit === preview.suit);
    if (want) view = want;
  }
  return { frame: f, parts: f.parts, view, suit: view.suit, title: D.frameLabel(f), sub: `${f.set} $${hex2(f.id)} · ${view.title}` };
}

/** The suit the side panels show colours in. */
function shownSuit() {
  const o = opened();
  return o && o.view ? o.suit : preview.suit;
}

function buildShell() {
  const app = $("#app");
  app.replaceChildren(
    el("header", { id: "bar" },
      el("h1", { textContent: "Sprite editor" }),
      el("span", { className: "tools", id: "tools" }),
      el("span", { className: "tools" },
        el("button", { id: "undo", textContent: "Undo", title: "Undo (⌘Z)", onclick: () => History.undo() }),
        el("button", { id: "redo", textContent: "Redo", title: "Redo (⇧⌘Z)", onclick: () => History.redo() })),
      toggle("Frozen", "frozen"),
      el("label", {}, "Damage ", select(["none", "1 (3/4)", "2 (1/2)", "3 (1/4)"], (v) => { preview.damage = v; }, "damage")),
      toggle("OBP1 flash", "flash"),
      el("label", {}, "Suit ", select(["Power", "Varia"], (v) => { preview.suit = v; }, "suit")),
      el("span", { className: "spacer" }),
      el("label", {}, "Zoom ", select([2, 4, 6, 8, 12, 16].map(String), (v) => { ui.zoom = [2, 4, 6, 8, 12, 16][v]; }, null, 3)),
      checkbox("Grid", ui.grid, (v) => { ui.grid = v; drawMain(); }),
      el("span", { id: "saveState", className: "savestate" }),
      el("button", { id: "save", className: "primary", textContent: "Save", title: "Write the data files (⌘S)", onclick: save }),
    ),
    el("nav", { id: "list" },
      el("input", { type: "search", placeholder: "Filter frames…", oninput: (e) => { ui.filter = e.target.value.toLowerCase(); buildList(); } }),
      el("div", { id: "groups" })),
    el("section", { id: "main" },
      el("div", { id: "title" }), el("div", { id: "stage" }), el("div", { id: "status" })),
    el("section", { id: "uses" }, el("h3", { id: "usesTitle" }), el("div", { id: "strip" })),
    el("aside", { id: "side" }, el("div", { id: "framePanel" }), el("div", { id: "palPanel" }), el("div", { id: "tilePanel" }),
      el("div", { id: "conflictPanel" })),
  );
  drawTools();
  addEventListener("mouseup", endStroke);
  addEventListener("keydown", keys);
  addEventListener("beforeunload", (e) => { if (ui.dirty) { e.preventDefault(); e.returnValue = ""; } });
}

function drawTools() {
  $("#tools").replaceChildren(...TOOLS.map((t) =>
    el("button", { className: ui.tool === t.id ? "sel" : "", textContent: t.label, title: t.title, onclick: () => setTool(t.id) })));
}
function setTool(t) {
  ui.tool = t;
  drawTools();
  if (ui.canvas) ui.canvas.dataset.tool = t;
}

function keys(e) {
  const mod = e.metaKey || e.ctrlKey;
  if (mod && e.key.toLowerCase() === "s") { e.preventDefault(); save(); return; }
  if (e.target.closest("input, select, textarea")) return;
  if (mod && e.key.toLowerCase() === "z") { e.preventDefault(); if (e.shiftKey) History.redo(); else History.undo(); return; }
  if (mod && e.key.toLowerCase() === "y") { e.preventDefault(); History.redo(); return; }
  if (mod || e.altKey) return;
  const t = TOOLS.find((x) => x.key === e.key.toLowerCase());
  if (t) setTool(t.id);
}

function toggle(label, key) {
  return checkbox(label, preview[key], (v) => { preview[key] = v; redraw(); });
}
function checkbox(label, on, f) {
  return el("label", {}, el("input", { type: "checkbox", checked: on, onchange: (e) => f(e.target.checked) }), label);
}
function select(opts, f, key, sel = 0) {
  const s = el("select", { onchange: (e) => { f(+e.target.value); if (key) redraw(); else drawMain(); } });
  opts.forEach((o, i) => s.append(el("option", { value: i, textContent: o, selected: i === sel })));
  return s;
}

function buildList() {
  const root = $("#groups");
  root.replaceChildren();
  const groups = new Map();
  const unresolved = [];
  D.model.frames.forEach((f, i) => {
    const label = D.frameLabel(f);
    if (ui.filter && !(label + " " + (D.frameGroup(f) ?? "")).toLowerCase().includes(ui.filter)) return;
    if (D.frameView(f) == null) { unresolved.push(i); return; }
    const g = D.frameGroup(f);
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(i);
  });
  const item = (kind, index, label, id) => {
    const sel = ui.open && ui.open.kind === kind && ui.open.index === index;
    return el("button", { className: "item" + (sel ? " sel" : ""), onclick: () => openThing({ kind, index }) },
      id ? el("span", { className: "id", textContent: id }) : null, label);
  };
  const frameItem = (i) => {
    const f = D.model.frames[i];
    const n = D.frameName(f);
    return item("frame", i, n ?? "", `${f.set === "samus" ? "S" : "E"}$${hex2(f.id)}`);
  };
  const section = (title, entries, open) => {
    const d = el("details", { open },
      el("summary", {}, title + " ", el("span", { className: "n", textContent: String(entries.length) })));
    for (const e of entries) d.append(e);
    return d;
  };
  root.append(el("div", { className: "head", textContent: "Frames" }));
  const openGroup = ui.open && ui.open.kind === "frame" ? D.frameGroup(D.model.frames[ui.open.index]) : null;
  for (const [g, is] of groups) root.append(section(g, is.map(frameItem), !!ui.filter || g === openGroup));
  if (unresolved.length) {
    root.append(el("div", { className: "head", textContent: "Unresolved (no sheet yet)" }));
    const openHere = ui.open && ui.open.kind === "frame" && unresolved.includes(ui.open.index);
    root.append(section("Unresolved", unresolved.map(frameItem), !!ui.filter || openHere));
  }
  if (!ui.filter) {
    root.append(el("div", { className: "head", textContent: "Sheets, as in VRAM" }));
    D.model.views.forEach((v, i) => root.append(item("view", i, v.title)));
  }
  const sel = $(".item.sel", root);
  if (sel) sel.scrollIntoView({ block: "nearest" });
}

function openThing(t, tile = null) {
  ui.open = t;
  ui.tile = tile;
  ui.part = null;
  buildList();
  drawMain();
  drawSide();
  for (const fig of document.querySelectorAll("#strip figure"))
    fig.classList.toggle("sel", t.kind === "frame" && +fig.dataset.frame === t.index);
}

/** Everything that depends on the preview or the colours. */
function redraw() {
  drawMain();
  drawSide();
  drawUses();
}
/** After undo or redo: names, sheets and tiles may all have changed. */
function refreshAll() {
  buildList();
  redraw();
  changed();
}

function drawMain() {
  const o = opened();
  const title = $("#title"), stage = $("#stage");
  title.replaceChildren();
  stage.replaceChildren();
  ui.img = null;
  ui.canvas = null;
  if (!o) { stage.append(el("p", { className: "none", textContent: "Pick a frame or a sheet on the left." })); return; }
  title.append(el("h2", { textContent: o.title }), el("span", { className: "sub", textContent: o.sub }));
  if (o.unresolved) {
    stage.append(el("p", { className: "none", textContent: "No sheet the model knows loads this frame's tiles. Choose one in the Frame panel on the right." }));
    return;
  }
  const img = Render.frame(o.parts, o.view, o.suit);
  if (!img) { stage.append(el("p", { className: "none", textContent: "None of this frame's tiles is loaded in its sheet." })); return; }
  ui.img = { ...img, o };
  const cv = Render.canvas(img, ui.zoom, GROUND);
  cv.dataset.tool = ui.tool;
  overlay(cv, ui.img, o);
  cv.onmousedown = (e) => down(cv, e);
  cv.onmousemove = (e) => move(cv, e);
  cv.onmouseleave = () => { $("#status").replaceChildren(); };
  ui.canvas = cv;
  stage.append(cv);
}

/** Redraws the open frame on its canvas: for edits, which keep its size. */
function repaintMain() {
  const o = ui.img && ui.img.o;
  if (!o || !ui.canvas) return drawMain();
  const img = Render.frame(o.parts, o.view, o.suit);
  if (!img || img.w !== ui.img.w || img.h !== ui.img.h) return drawMain();
  ui.img = { ...img, o };
  Render.paint(ui.canvas, img, ui.zoom, GROUND);
  overlay(ui.canvas, ui.img, o);
}

/** The tile grid, the selected tile's copies, and the chosen colour's pixels. */
function overlay(cv, img, o) {
  const z = ui.zoom;
  const ctx = cv.getContext("2d");
  if (ui.grid && z >= 6) {
    ctx.strokeStyle = "rgba(255,255,255,.07)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = 1; x < img.w; x++) { ctx.moveTo(x * z + .5, 0); ctx.lineTo(x * z + .5, img.h * z); }
    for (let y = 1; y < img.h; y++) { ctx.moveTo(0, y * z + .5); ctx.lineTo(img.w * z, y * z + .5); }
    ctx.stroke();
  }
  img.boxes.forEach((b, k) => {
    if (!b) return;
    const s = o.view.vram[o.parts[k].tile];
    const sel = ui.tile != null && s.tile === ui.tile;
    if (!ui.grid && !sel) return;
    ctx.strokeStyle = sel ? "#ffcc33" : "rgba(255,255,255,.28)";
    ctx.lineWidth = sel ? 2 : 1;
    ctx.strokeRect(b.x * z + .5, b.y * z + .5, 8 * z - 1, 8 * z - 1);
  });
  if (ui.highlight && ui.index !== 0 && z >= 4) {
    const d = Math.max(2, Math.round(z / 3));
    for (let i = 0; i < img.ix.length; i++) {
      if (img.ix[i] !== ui.index || img.pl[i] !== ui.palette) continue;
      const x = (i % img.w) * z + (z - d) / 2, y = Math.floor(i / img.w) * z + (z - d) / 2;
      ctx.fillStyle = "#000"; ctx.fillRect(x - 1, y - 1, d + 2, d + 2);
      ctx.fillStyle = "#fff"; ctx.fillRect(x, y, d, d);
    }
  }
}

/** The part and tile pixel under the mouse, or null. */
function at(cv, e) {
  const img = ui.img;
  if (!img) return null;
  const r = cv.getBoundingClientRect();
  const x = Math.floor((e.clientX - r.left) * (cv.width / r.width) / ui.zoom);
  const y = Math.floor((e.clientY - r.top) * (cv.height / r.height) / ui.zoom);
  if (x < 0 || y < 0 || x >= img.w || y >= img.h) return null;
  const k = img.cover[y * img.w + x];
  if (k < 0) return null;
  const q = img.o.parts[k];
  const b = img.boxes[k];
  const lr = y - b.y, lc = x - b.x;
  const ty = q.attr & 0x40 ? 7 - lr : lr;
  const tx = q.attr & 0x20 ? 7 - lc : lc;
  const s = img.o.view.vram[q.tile];
  const pal = Render.palette(img.page, q.attr, D.slotOf(s));
  return { k, q, s, tx, ty, n: ty * 8 + tx, index: D.indices(s.tile)[ty * 8 + tx], pal };
}

function move(cv, e) {
  const h = at(cv, e);
  if (ui.stroke) {
    if (!(e.buttons & 1)) endStroke();
    else if (h) paint(h);
  }
  status(h);
}

/** The status line: what's under the mouse, and what the pencil would paint there. */
function status(h) {
  const st = $("#status");
  if (!h) { st.replaceChildren(); return; }
  const t = D.model.tiles[h.s.tile];
  const text = `VRAM $${hex2(h.q.tile)} · tile ${t.key} · pixel (${h.tx},${h.ty}) index ${h.index}` +
    ` · palette ${h.pal}${h.q.attr & 0x60 ? " · flip " + (h.q.attr & 0x20 ? "x" : "") + (h.q.attr & 0x40 ? "y" : "") : ""}` +
    `${h.q.attr & 0x10 ? " · OBP1" : ""} · ${tileShared(h.s.tile)}`;
  const kids = [text];
  if (ui.tool === "pencil") {
    const c = ui.index === 0 ? null : Render.colour(Render.rows(h.pal, ui.img.o.suit), ui.index);
    kids.push(" · paints ", el("span", { className: "chip" + (c == null ? " t" : ""), style: c == null ? "" : `background:${css(c)}` }),
      ` ${ui.index}${c == null ? " (clear)" : " " + css(c)}`);
  }
  st.replaceChildren(...kids);
}

function down(cv, e) {
  if (e.button !== 0) return;
  const h = at(cv, e);
  if (!h) return;
  e.preventDefault();
  const tool = ui.tool === "pencil" && e.altKey ? "picker" : ui.tool;
  if (tool === "picker") {
    ui.index = h.index;
    select_(h);
    return;
  }
  if (tool === "select") { select_(h); return; }
  // Pencil: a stroke is one undo step.
  if (!confirmWide(h.s.tile)) return;
  if (ui.tile !== h.s.tile || ui.palette !== h.pal) select_(h);
  ui.stroke = new Map();
  paint(h);
}

function select_(h) {
  ui.tile = h.s.tile;
  ui.part = h.k;
  ui.palette = h.pal;
  repaintMain();
  drawSide();
  drawUses();
}

function paint(h) {
  const ti = h.s.tile;
  if (!ui.stroke.has(`${ti}:-`) && !confirmWide(ti)) return;
  ui.stroke.set(`${ti}:-`, null);
  if (h.index === ui.index) return;
  const key = `${ti}:${h.n}`;
  const before = D.setPixel(ti, h.n, ui.index);
  const c = ui.stroke.get(key);
  ui.stroke.set(key, { ti, n: h.n, before: c ? c.before : before, after: ui.index });
  repaintMain();
}

function endStroke() {
  const s = ui.stroke;
  if (!s) return;
  ui.stroke = null;
  const changes = [...s.values()].filter((c) => c && c.before !== c.after);
  if (!changes.length) return;
  History.push({
    label: `paint ${changes.length} pixel${changes.length === 1 ? "" : "s"}`,
    undo: () => { for (const c of changes) D.setPixel(c.ti, c.n, c.before); },
    redo: () => { for (const c of changes) D.setPixel(c.ti, c.n, c.after); },
  });
  drawSide();
  drawUses();
}

function tileShared(ti) {
  const t = D.model.tiles[ti];
  return `shared by ${D.framesOf[ti].length} frame${D.framesOf[ti].length === 1 ? "" : "s"}, ${t.copies.length} cop${t.copies.length === 1 ? "y" : "ies"}`;
}

/** Whether an edit to tile `ti` reaches far: the blank tile, or many copies or frames. */
function wideImpact(ti) {
  const t = D.model.tiles[ti];
  const blank = D.original[ti].every((v) => v === 0);
  if (blank) return "This is a blank tile: every sprite that leaves a gap uses it.";
  if (t.copies.length >= WIDE_COPIES || D.framesOf[ti].length >= WIDE_FRAMES)
    return `An edit here changes ${D.framesOf[ti].length} frames and ${t.copies.length} copies of this tile.`;
  return null;
}
/** The first edit to a wide-impact tile asks first. */
const confirmed = new Set();
function confirmWide(ti) {
  const w = wideImpact(ti);
  if (!w || confirmed.has(ti)) return true;
  if (!confirm(w + " Edit it anyway?")) return false;
  confirmed.add(ti);
  return true;
}

function drawSide() {
  drawFrame();
  drawPalette();
  drawTile();
  drawConflicts();
}

/** Name, group and (for a frame the model can't place) sheet. */
function drawFrame() {
  const root = $("#framePanel");
  const o = opened();
  if (!o || !o.frame) { root.replaceChildren(); return; }
  const f = o.frame;
  const m = D.meta(f) ?? {};
  const field = (name, label, placeholder, list) => {
    const input = el("input", { type: "text", value: m[name] ?? "", placeholder, onchange: (e) => setMeta(f, name, e.target.value.trim()) });
    if (list) input.setAttribute("list", list);
    return el("label", { className: "field" }, el("span", { textContent: label }), input);
  };
  const groups = new Set();
  for (const x of D.frameMeta.values()) if (x.group) groups.add(x.group);
  for (const x of D.model.frames) if (x.group) groups.add(x.group);
  const kids = [el("h3", { textContent: "Frame" }),
    field("name", "Name", f.name ?? `${f.set} $${hex2(f.id)}`),
    field("group", "Group", f.group ?? (f.view != null ? D.model.views[f.view].title : ""), "groupList"),
    el("datalist", { id: "groupList" }, ...[...groups].sort().map((g) => el("option", { value: g })))];
  if (f.view == null || m.sheet) {
    const s = el("select", { onchange: (e) => setMeta(f, "sheet", e.target.value) },
      el("option", { value: "", textContent: f.view == null ? "— choose a sheet —" : "— the model's —" }),
      ...D.model.views.map((v) => el("option", { value: v.name, textContent: v.title, selected: v.name === m.sheet })));
    kids.push(el("label", { className: "field" }, el("span", { textContent: "Sheet" }), s));
  }
  root.replaceChildren(...kids);
}

function setMeta(f, field, value) {
  const before = D.setMeta(f, field, value);
  const after = value || null;
  if (before === after) return;
  History.push({
    label: `${field} of ${f.set} $${hex2(f.id)}`,
    undo: () => D.setMeta(f, field, before),
    redo: () => D.setMeta(f, field, after),
  });
  buildList();
  if (field === "sheet") redraw();
  else { drawMain(); drawUses(); }
}

/** The palette entry `i` of palette `p` is edited through: its rows array and cell. */
function entryTarget(p, i) {
  const rows = Render.rows(p, shownSuit());
  const [v, s] = Render.cell(i);
  return { rows, v, s, get: () => rows[v][s], set: (c) => { rows[v][s] = c; } };
}

function drawPalette() {
  const p = ui.palette;
  const root = $("#palPanel");
  const suit = shownSuit();
  const ents = Render.entries(p, suit);
  const pals = el("div", { className: "pals" });
  for (let i = 0; i < 8; i++)
    pals.append(el("button", { className: i === p ? "sel" : "", textContent: String(i), title: PALETTE_NAMES[i],
      onclick: () => { ui.palette = i; repaintMain(); drawSide(); drawUses(); } }));
  const grid = el("div", { className: "swatches" },
    el("span"), ...[0, 1, 2, 3].map((v) => el("span", { className: "ch", textContent: `variant ${v}` })));
  const pick = (i) => { ui.index = i; repaintMain(); drawPalette(); };
  ["light", "middle", "dark"].forEach((name, r) => {
    grid.append(el("span", { className: "rl", textContent: name }));
    for (let v = 0; v < 4; v++) {
      const i = v * 4 + r + 1;
      const sw = el("button", { className: "sw" + (i === ui.index ? " sel" : ""), title: `index ${i}: ${css(ents[i])}`, onclick: () => pick(i) });
      sw.dataset.i = i;
      swatchStyle(sw, ents[i], i);
      grid.append(sw);
    }
  });
  grid.append(el("span", { className: "rl", textContent: "clear" }),
    el("button", { className: "sw t" + (ui.index === 0 ? " sel" : ""), textContent: "0", title: "index 0: transparent", onclick: () => pick(0) }));
  const table = Render.rowsName(p, suit);
  const kids = [el("h3", { textContent: "Palette" }), pals,
    el("p", { className: "palname", textContent: `${p}: ${PALETTE_NAMES[p]}${table ? ` (${table})` : ""}` }), grid,
    checkbox("Mark its pixels in the frame", ui.highlight, (v) => { ui.highlight = v; repaintMain(); })];
  if (ui.index !== 0) kids.push(colourEditor(p, ui.index));
  root.replaceChildren(...kids);
}

function swatchStyle(sw, c, i) {
  sw.style.background = css(c);
  sw.style.color = lum(c) > 140 ? "#000" : "#fff";
  sw.textContent = String(i);
  sw.title = `index ${i}: ${css(c)}`;
}

/** The chosen entry's colour: edited live, one undo step per change. */
function colourEditor(p, i) {
  const t = entryTarget(p, i);
  const hexOut = el("span", { className: "k", textContent: css(t.get()) });
  let before = null;
  const input = el("input", { type: "color", value: css(t.get()) });
  input.oninput = (e) => {
    if (before == null) before = t.get();
    const c = to555(parseInt(e.target.value.slice(1), 16));
    t.set(c);
    hexOut.textContent = css(c);
    const sw = $(`#palPanel .sw[data-i="${i}"]`);
    if (sw) swatchStyle(sw, c, i);
    live();
  };
  input.onchange = () => {
    if (before == null) return;
    const b = before, a = t.get();
    before = null;
    input.value = css(a);
    if (a === b) return;
    History.push({ label: `colour ${p}:${i}`, undo: () => t.set(b), redo: () => t.set(a) });
  };
  return el("div", { className: "colour" }, el("span", { textContent: `Entry ${i}` }), input, hexOut,
    el("span", { className: "muted", textContent: "rounded to BGR555" }));
}

/** A colour edit's redraw, once per animation frame. */
let livePending = false;
function live() {
  if (livePending) return;
  livePending = true;
  requestAnimationFrame(() => { livePending = false; repaintMain(); drawUses(); drawConflicts(); });
}

function lum(c) { return 0.3 * (c >> 16) + 0.59 * ((c >> 8) & 255) + 0.11 * (c & 255); }

function paletteName(p) { return `${p}: ${PALETTE_NAMES[p]}`; }

/** A select of the palettes tile `ti` may take (F4). */
function paletteMenu(ti, unsetLabel) {
  const t = D.model.tiles[ti];
  const allowed = t.samus ? D.model.samus_palettes : D.model.enemy_palettes;
  const cur = D.chosen(ti);
  const s = el("select", { onchange: (e) => {
    const v = e.target.value === "" ? null : +e.target.value;
    if (!setTilePalette(ti, v)) e.target.value = cur == null ? "" : String(cur);
  } },
  el("option", { value: "", textContent: unsetLabel, selected: cur == null }),
  ...allowed.map((p) => el("option", { value: p, textContent: paletteName(p), selected: cur === p })));
  return s;
}

function setTilePalette(ti, p) {
  // A choice equal to the tile's one derived slot is no choice.
  const d = D.derived(ti);
  if (p != null && d.length === 1 && d[0] === p) p = null;
  if (D.chosen(ti) === p) { drawSide(); return true; }
  if (!confirmWide(ti)) return false;
  const before = D.setPalette(ti, p);
  History.push({ label: `palette of tile ${D.model.tiles[ti].key}`, undo: () => D.setPalette(ti, before), redo: () => D.setPalette(ti, p) });
  redraw();
  return true;
}

function drawTile() {
  const root = $("#tilePanel");
  root.replaceChildren(el("h3", { textContent: "Tile" }));
  if (ui.tile == null) { root.append(el("p", { className: "muted", textContent: "Click a tile in the frame to see where it is used." })); return; }
  const ti = ui.tile;
  const t = D.model.tiles[ti];
  const badges = el("div", { className: "badges" },
    el("span", { className: "badge", textContent: `Shared by ${D.framesOf[ti].length} frames` }),
    el("span", { className: "badge", textContent: `${t.copies.length} cop${t.copies.length === 1 ? "y" : "ies"}` }));
  if (D.edited(ti)) badges.append(el("span", { className: "badge edit", textContent: "Edited" }));
  if (t.twin) badges.append(el("span", { className: "badge warn", textContent: "BG twin", title: "Also drawn on the 2bpp background, where each pixel shows its shade (index & 3)." }));
  if (t.copies.some((c) => c.sheet != null && D.model.sheets[c.sheet].name === "gfx_queenSPR"))
    badges.append(el("span", { className: "badge", textContent: "Queen's head", title: "BG2 draws her head from her object tiles, in her 16-entry palette." }));
  if (t.samus) badges.append(el("span", { className: "badge", textContent: "Samus" }));
  if (t.conflict) {
    const slots = D.derived(ti).join(", ");
    badges.append(el("span", { className: "badge warn", textContent: `Conflict: slots ${slots}` }));
  }
  root.append(el("p", { className: "k", style: "margin:4px 0 0;font-family:var(--mono);font-size:11px", textContent: t.key }), badges);
  const w = wideImpact(ti);
  if (w) root.append(el("div", { className: "warnbox", textContent: w }));

  const d = D.derived(ti);
  root.append(el("label", { className: "field" }, el("span", { textContent: "Palette" }),
    paletteMenu(ti, `derived (slot${d.length === 1 ? "" : "s"} ${d.join(", ")})`)));
  if (D.edited(ti)) {
    root.append(el("button", { className: "link", textContent: "Revert this tile's pixels", onclick: () => revertPixels(ti) }));
  }

  const copies = el("ul", { className: "where" });
  for (const c of t.copies) {
    const sh = c.sheet != null ? D.model.sheets[c.sheet] : null;
    copies.append(el("li", {}, sh ? `${sh.title} ` : "", el("span", { className: "k", textContent: `${sh ? "#" + c.tile + " · " : ""}ROM $${c.rom_at.toString(16).toUpperCase()} · slot ${c.slot}` })));
  }
  const frames = el("ul", { className: "where" });
  for (const fi of D.framesOf[ti]) {
    const f = D.model.frames[fi];
    frames.append(el("li", {}, el("button", { textContent: D.frameLabel(f), onclick: () => openThing({ kind: "frame", index: fi }, ti) }),
      " ", el("span", { className: "k", textContent: `${f.set} $${hex2(f.id)}` })));
  }
  root.append(el("h3", { textContent: "Copies", style: "margin-top:12px" }), copies,
    el("h3", { textContent: "Frames", style: "margin-top:12px" }), frames);
}

function revertPixels(ti) {
  const e = D.edits.get(D.model.tiles[ti].key);
  if (!e) return;
  const changes = [...e.pixels].map(([n, idx]) => ({ n, before: idx, after: D.original[ti][n] }));
  for (const c of changes) D.setPixel(ti, c.n, c.after);
  History.push({
    label: `revert tile ${D.model.tiles[ti].key}`,
    undo: () => { for (const c of changes) D.setPixel(ti, c.n, c.before); },
    redo: () => { for (const c of changes) D.setPixel(ti, c.n, c.after); },
  });
  redraw();
}

/** Tiles whose copies take different slots today: pick one palette for each. */
function drawConflicts() {
  const root = $("#conflictPanel");
  const cs = D.model.conflicts;
  if (!cs.length) { root.replaceChildren(); return; }
  const open = root.querySelector("details")?.open ?? false;
  const left = cs.filter((ti) => D.chosen(ti) == null).length;
  const list = el("ul", { className: "conflicts" });
  for (const ti of cs) {
    const t = D.model.tiles[ti];
    const slot = D.chosen(ti) ?? t.copies[0].slot;
    const pal = Render.palette(D.model.pages.full, 0, slot);
    const thumb = Render.canvas(Render.tile(ti, pal, preview.suit), 3, GROUND);
    const view = D.model.views.findIndex((v) => v.vram.some((s) => s && s.tile === ti));
    const where = [...new Set(t.copies.map((c) => (c.sheet != null ? D.model.sheets[c.sheet].title : "ROM") + ` (${c.slot})`))].join(", ");
    list.append(el("li", {}, thumb,
      el("div", {},
        el("div", { className: "k", textContent: t.key }),
        el("div", { className: "muted", textContent: where }),
        paletteMenu(ti, `unresolved (slots ${D.derived(ti).join(", ")})`),
        view < 0 ? null : el("button", { className: "link", textContent: "show", onclick: () => openThing({ kind: "view", index: view }, ti) }))));
  }
  root.replaceChildren(el("details", { open },
    el("summary", {}, el("h3", { textContent: `Conflicts · ${left} of ${cs.length} open` })), list));
}

/** Every resolved frame with a part in the selected palette, redrawn as colours change. */
function drawUses() {
  const p = ui.palette;
  const strip = $("#strip");
  strip.replaceChildren();
  let n = 0;
  D.model.frames.forEach((f, fi) => {
    const vi = D.frameView(f);
    if (vi == null) return;
    let view = D.model.views[vi];
    if (view.page === "samus") view = D.model.views.find((v) => v.page === "samus" && v.suit === preview.suit) ?? view;
    const page = Render.page(view);
    const uses = f.parts.some((q) => { const s = view.vram[q.tile]; return s && Render.palette(page, q.attr, D.slotOf(s)) === p; });
    if (!uses) return;
    const img = Render.frame(f.parts, view, view.suit);
    if (!img) return;
    n++;
    const sel = ui.open && ui.open.kind === "frame" && ui.open.index === fi;
    const fig = el("figure", { className: sel ? "sel" : "", title: `${D.frameLabel(f)} (${f.set} $${hex2(f.id)})`, onclick: () => openThing({ kind: "frame", index: fi }) },
      Render.canvas(img, 2, GROUND), el("figcaption", { textContent: D.frameName(f) ?? `$${hex2(f.id)}` }));
    fig.dataset.frame = fi;
    strip.append(fig);
  });
  $("#usesTitle").textContent = `Uses palette ${p} · ${n} frame${n === 1 ? "" : "s"}`;
}

// ---- Saving -----------------------------------------------------------------

/** After any edit: the undo buttons and the unsaved mark. */
function changed() {
  ui.dirty = JSON.stringify(D.serialize()) !== ui.saved;
  $("#undo").disabled = History.done.length === 0;
  $("#redo").disabled = History.undone.length === 0;
  $("#save").disabled = !ui.dirty;
  const s = $("#saveState");
  s.className = "savestate" + (ui.dirty ? " dirty" : "");
  if (ui.dirty) s.textContent = "Unsaved changes";
  else if (s.textContent === "Unsaved changes") s.textContent = "";
  document.title = (ui.dirty ? "• " : "") + "m2snes sprite editor";
}

async function save() {
  if (ui.stroke) endStroke();
  const body = JSON.stringify(D.serialize());
  const s = $("#saveState");
  s.className = "savestate";
  s.textContent = "Saving…";
  let res, out;
  try {
    res = await fetch("/api/save", { method: "POST", headers: { "content-type": "application/json" }, body });
    out = await res.json();
  } catch (e) {
    s.className = "savestate err";
    s.textContent = `Save failed: ${e.message}`;
    return;
  }
  if (!res.ok) {
    s.className = "savestate err";
    s.textContent = `Not saved: ${out.error}`;
    return;
  }
  ui.saved = body;
  changed();
  s.textContent = out.written.length ? `Saved ${out.written.map((p) => p.split("/").pop()).join(", ")}` : "Saved (no file changed)";
}

async function main() {
  const res = await fetch("/api/model");
  const body = await res.json();
  if (!res.ok) { $("#app").textContent = `Couldn't load the model: ${body.error}`; return; }
  D.load(body.model, body.state);
  ui.saved = JSON.stringify(D.serialize());
  buildShell();
  buildList();
  const first = D.model.frames.findIndex((f) => f.set === "enemy" && f.view != null);
  openThing({ kind: "frame", index: first < 0 ? 0 : first });
  drawUses();
  changed();
}

main();
