"use strict";
// Icons: one SVG sprite of stroke icons (20×20 grid, currentColor) and small colored file-type icons.

const ICONS = {
  project: '<path d="M2.5 5.5a1 1 0 0 1 1-1h4l1.5 1.5h7.5a1 1 0 0 1 1 1v8.5a1 1 0 0 1-1 1h-13a1 1 0 0 1-1-1z"/>',
  commit: '<circle cx="10" cy="10" r="3.2"/><path d="M2 10h4.8M13.2 10H18"/>',
  history: '<path d="M3.6 10a6.4 6.4 0 1 0 1.9-4.6"/><path d="M3.2 3.4v3.3h3.3"/><path d="M10 6.6V10l2.6 1.6"/>',
  structure: '<rect x="2.5" y="2.5" width="6" height="4" rx="1"/><rect x="11.5" y="8" width="6" height="4" rx="1"/><rect x="11.5" y="13.5" width="6" height="4" rx="1"/><path d="M5.5 6.5v9h6M5.5 10h6"/>',
  more: '<circle cx="4.5" cy="10" r="1.1" fill="currentColor" stroke="none"/><circle cx="10" cy="10" r="1.1" fill="currentColor" stroke="none"/><circle cx="15.5" cy="10" r="1.1" fill="currentColor" stroke="none"/>',
  kebab: '<circle cx="10" cy="4.5" r="1.1" fill="currentColor" stroke="none"/><circle cx="10" cy="10" r="1.1" fill="currentColor" stroke="none"/><circle cx="10" cy="15.5" r="1.1" fill="currentColor" stroke="none"/>',
  run: '<path d="M6 4.2v11.6l9.2-5.8z"/>',
  terminal: '<rect x="2.5" y="3.5" width="15" height="13" rx="2"/><path d="M6 8l2.6 2L6 12M10.5 12.5H14"/>',
  problems: '<circle cx="10" cy="10" r="7"/><path d="M10 6v4.8M10 13.6v.2"/>',
  git: '<circle cx="6" cy="4.5" r="1.8"/><circle cx="6" cy="15.5" r="1.8"/><circle cx="14" cy="7" r="1.8"/><path d="M6 6.3v7.4M14 8.8c0 3.4-4.2 2.6-7.4 5"/>',
  branch: '<circle cx="6" cy="4.5" r="1.8"/><circle cx="6" cy="15.5" r="1.8"/><circle cx="14" cy="7" r="1.8"/><path d="M6 6.3v7.4M14 8.8c0 3.4-4.2 2.6-7.4 5"/>',
  branchNew: '<circle cx="6" cy="4.5" r="1.8"/><circle cx="6" cy="15.5" r="1.8"/><path d="M6 6.3v7.4M6 11c0-3 3-3.5 5-3.5"/><path d="M15 4v6M12 7h6"/>',
  merge: '<circle cx="5.5" cy="4.5" r="1.8"/><circle cx="5.5" cy="15.5" r="1.8"/><circle cx="14.5" cy="15.5" r="1.8"/><path d="M5.5 6.3v7.4M5.5 6.5c0 5 9 3 9 7.2"/>',
  database: '<ellipse cx="10" cy="5" rx="6" ry="2.4"/><path d="M4 5v10c0 1.3 2.7 2.4 6 2.4s6-1.1 6-2.4V5M4 10c0 1.3 2.7 2.4 6 2.4s6-1.1 6-2.4"/>',
  remote: '<rect x="3" y="3.5" width="14" height="5.5" rx="1.2"/><rect x="3" y="11" width="14" height="5.5" rx="1.2"/><path d="M6 6.25h.5M6 13.75h.5M10 6.25h4M10 13.75h4"/>',
  agents: '<path d="M10 2.6l1.7 4.6 4.6 1.7-4.6 1.7L10 15.2l-1.7-4.6-4.6-1.7 4.6-1.7z"/><path d="M15.5 13.5l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6z"/>',
  elio: '<path d="M10 2.5l1.9 5.6 5.6 1.9-5.6 1.9L10 17.5l-1.9-5.6L2.5 10l5.6-1.9z"/>',
  find: '<circle cx="8.6" cy="8.6" r="5.1"/><path d="M12.4 12.4L17 17"/>',
  search: '<circle cx="8.6" cy="8.6" r="5.1"/><path d="M12.4 12.4L17 17"/>',
  plus: '<path d="M10 4v12M4 10h12"/>',
  minus: '<path d="M4.5 10h11"/>',
  close: '<path d="M5.5 5.5l9 9M14.5 5.5l-9 9"/>',
  check: '<path d="M4 10.5l4 4 8-9"/>',
  chevronDown: '<path d="M5.5 8l4.5 4.5L14.5 8"/>',
  chevronRight: '<path d="M8 5.5l4.5 4.5L8 14.5"/>',
  chevronUp: '<path d="M5.5 12L10 7.5l4.5 4.5"/>',
  locate: '<circle cx="10" cy="10" r="5.5"/><circle cx="10" cy="10" r="1.6" fill="currentColor" stroke="none"/><path d="M10 2v2.5M10 15.5V18M2 10h2.5M15.5 10H18"/>',
  expandAll: '<path d="M6 4.5l4 4 4-4M6 11l4 4 4-4"/>',
  collapseAll: '<path d="M6 9l4-4 4 4M6 15.5l4-4 4 4"/>',
  refresh: '<path d="M16 10a6 6 0 1 1-1.8-4.3"/><path d="M16.2 3.6v3.6h-3.6"/>',
  push: '<path d="M10 16.5V4.5M5 9l5-5 5 5"/>',
  update: '<path d="M10 3v10M5.5 8.5L10 13l4.5-4.5M4 16.5h12"/>',
  arrowUp: '<path d="M10 16V4.5M5.5 9L10 4.5 14.5 9"/>',
  arrowDown: '<path d="M10 4v11.5M5.5 11L10 15.5 14.5 11"/>',
  tag: '<path d="M3 3h6.4l7.6 7.6-6.4 6.4L3 9.4z"/><circle cx="6.6" cy="6.6" r="1.1"/>',
  stop: '<rect x="5" y="5" width="10" height="10" rx="1.5"/>',
  rerun: '<path d="M15.8 10a5.8 5.8 0 1 1-1.7-4.1"/><path d="M16 3.8v3.4h-3.4"/><path d="M8.6 7.6v4.8l3.8-2.4z" fill="currentColor" stroke="none"/>',
  settings: '<circle cx="10" cy="10" r="2.6"/><path d="M10 2.5v2.2M10 15.3v2.2M2.5 10h2.2M15.3 10h2.2M4.7 4.7l1.6 1.6M13.7 13.7l1.6 1.6M4.7 15.3l1.6-1.6M13.7 6.3l1.6-1.6"/>',
  diff: '<rect x="2.5" y="3" width="6" height="14" rx="1"/><rect x="11.5" y="3" width="6" height="14" rx="1"/><path d="M4.5 8.5h2M13.5 8.5h2M14.5 7.5v2M4.5 12.5h2"/>',
  rollback: '<path d="M7 4.5L3.5 8 7 11.5"/><path d="M3.5 8H12a4.5 4.5 0 0 1 0 9H8.5"/>',
  copy: '<rect x="6.5" y="6.5" width="10" height="10.5" rx="1.5"/><path d="M13.5 6.5V4.5a1.5 1.5 0 0 0-1.5-1.5H5A1.5 1.5 0 0 0 3.5 4.5V12A1.5 1.5 0 0 0 5 13.5h1.5"/>',
  trash: '<path d="M3.5 5.5h13M8 5.5V3.5h4v2M5 5.5l.8 11a1 1 0 0 0 1 1h6.4a1 1 0 0 0 1-1l.8-11"/>',
  edit: '<path d="M12.5 3.5l4 4L7 17H3v-4z"/>',
  file: '<path d="M5 2.5h6.5L15 6v11.5H5z"/><path d="M11.5 2.5V6H15"/>',
  folder: '<path d="M2.5 5.5a1 1 0 0 1 1-1h4l1.5 1.5h7.5a1 1 0 0 1 1 1v8.5a1 1 0 0 1-1 1h-13a1 1 0 0 1-1-1z"/>',
  newFolder: '<path d="M2.5 5.5a1 1 0 0 1 1-1h4l1.5 1.5h7.5a1 1 0 0 1 1 1v8.5a1 1 0 0 1-1 1h-13a1 1 0 0 1-1-1z"/><path d="M10 9v5M7.5 11.5h5"/>',
  newFile: '<path d="M5 2.5h6.5L15 6v11.5H5z"/><path d="M10 8.5v6M7 11.5h6"/>',
  filter: '<path d="M3 4h14l-5.5 6.5v5L8.5 17v-6.5z"/>',
  hide: '<path d="M4.5 10h11"/>',
  warning: '<path d="M10 3l7.5 13.2h-15z"/><path d="M10 8.2v3.6M10 14v.2"/>',
  error: '<circle cx="10" cy="10" r="7"/><path d="M7.4 7.4l5.2 5.2M12.6 7.4l-5.2 5.2"/>',
  info: '<circle cx="10" cy="10" r="7"/><path d="M10 9v5M10 6.2v.2"/>',
  cherry: '<circle cx="6" cy="14" r="2.8"/><circle cx="14" cy="14" r="2.8"/><path d="M6 11.2C6 7 9 4 13 3M14 11.2C14 7.5 13 5 13 3"/>',
  revert: '<path d="M7 4.5L3.5 8 7 11.5"/><path d="M3.5 8h8a4.5 4.5 0 1 1 0 9H7"/>',
  reset: '<path d="M4 10a6 6 0 1 0 1.8-4.3"/><path d="M3.8 3.6v3.6h3.6"/><circle cx="10" cy="10" r="1.4" fill="currentColor" stroke="none"/>',
  hash: '<path d="M7.5 3.5l-1.5 13M14 3.5l-1.5 13M3.5 7.5h13M3 12.5h13"/>',
  user: '<circle cx="10" cy="7" r="3.2"/><path d="M3.5 17c.8-3.3 3.4-5 6.5-5s5.7 1.7 6.5 5"/>',
  eye: '<path d="M1.8 10S4.8 4.5 10 4.5 18.2 10 18.2 10 15.2 15.5 10 15.5 1.8 10 1.8 10z"/><circle cx="10" cy="10" r="2.5"/>',
  annotate: '<path d="M3 4.5h6M3 8h6M3 11.5h6M3 15h6"/><path d="M12 4.5h5M12 8h3.5M12 11.5h5M12 15h3.5"/>',
  sidebar: '<rect x="2.5" y="3.5" width="15" height="13" rx="2"/><path d="M7.5 3.5v13"/>',
  panel: '<rect x="2.5" y="3.5" width="15" height="13" rx="2"/><path d="M2.5 12h15"/>',
  pin: '<path d="M8 3h4l-.5 5 3 3H5.5l3-3z"/><path d="M10 11v6"/>',
  lock: '<rect x="4.5" y="9" width="11" height="8" rx="1.5"/><path d="M7 9V6.5a3 3 0 0 1 6 0V9"/>',
  key: '<circle cx="6.5" cy="13.5" r="3"/><path d="M8.6 11.4L16 4M13 7l2 2M14.5 5.5l1.5 1.5"/>',
  open: '<path d="M11 3.5h5.5V9M16.5 3.5L9 11"/><path d="M14 12v4.5H3.5V6H8"/>',
  shelf: '<path d="M3 6h14M3 10h14M3 14h14"/>',
  dot: '<circle cx="10" cy="10" r="3" fill="currentColor" stroke="none"/>',
};

const SVGNS = "http://www.w3.org/2000/svg";
let iconSprite = null;
function ensureSprite() {
  if (iconSprite) return iconSprite;
  iconSprite = document.createElementNS(SVGNS, "svg");
  iconSprite.setAttribute("id", "iconSprite");
  iconSprite.setAttribute("aria-hidden", "true");
  iconSprite.style.cssText = "position:absolute;width:0;height:0;overflow:hidden";
  document.body.prepend(iconSprite);
  for (const [id, markup] of Object.entries(ICONS)) defineIcon(id, markup);
  return iconSprite;
}
// Adds (or replaces) a symbol in the sprite. Markup is drawn on a 20×20 grid, stroke = currentColor.
function defineIcon(id, markup) {
  ICONS[id] = markup;
  if (!iconSprite) return;
  let sym = iconSprite.querySelector(`#i-${CSS.escape(id)}`);
  if (!sym) { sym = document.createElementNS(SVGNS, "symbol"); sym.setAttribute("id", "i-" + id); iconSprite.append(sym); }
  sym.setAttribute("viewBox", "0 0 20 20");
  sym.innerHTML = markup;
}
// <svg class="i"> using a sprite symbol; `id` can also be inline SVG markup ("<svg…" or "<path…").
function icon(id, cls = "") {
  if (id && id.trim().startsWith("<svg")) return id.replace("<svg", `<svg class="i ${cls}"`);
  if (id && id.trim().startsWith("<")) return `<svg class="i ${cls}" viewBox="0 0 20 20">${id}</svg>`;
  return `<svg class="i ${cls}"><use href="#i-${id}"/></svg>`;
}
function iconEl(id, cls = "") { const s = document.createElement("span"); s.className = "ico " + cls; s.innerHTML = icon(id); return s; }

// ---------- File-type icons (PhpStorm-like: small colored chips and glyphs) ----------
const FT = {
  php: ["#8E86E8", "php"], phtml: ["#8E86E8", "<>"], inc: ["#8E86E8", "php"],
  js: ["#E5C14F", "JS"], mjs: ["#E5C14F", "JS"], cjs: ["#E5C14F", "JS"], jsx: ["#E5C14F", "JSX"],
  ts: ["#4C8EDA", "TS"], tsx: ["#4C8EDA", "TSX"], mts: ["#4C8EDA", "TS"],
  json: ["#E5A24F", "{}"], neon: ["#6AAB73", "N"], lock: null,
  xml: ["#E0844B", "</>"], xsd: ["#E0844B", "xsd"], wsdl: ["#E0844B", "</>"], plist: ["#E0844B", "</>"],
  html: ["#E3714F", "<>"], htm: ["#E3714F", "<>"], twig: ["#9BB53F", "tw"], vue: ["#42B883", "V"], blade: ["#F05340", "b"],
  css: ["#4A9FE0", "#"], scss: ["#D36BA8", "#"], sass: ["#D36BA8", "#"], less: ["#5B83C9", "#"],
  md: ["#7DA6D9", "M"], markdown: ["#7DA6D9", "M"], txt: null, log: null,
  yml: ["#D0675E", "Y"], yaml: ["#D0675E", "Y"], toml: ["#9C8E7A", "T"], ini: ["#9C8E7A", "ini"], conf: ["#9C8E7A", "cf"],
  sh: ["#6BB36E", ">_"], zsh: ["#6BB36E", ">_"], bash: ["#6BB36E", ">_"], fish: ["#6BB36E", ">_"],
  swift: ["#F0743E", "S"], py: ["#4F8CC9", "Py"], rb: ["#D0504A", "rb"], go: ["#3FB3D6", "go"], rs: ["#D88A5A", "rs"],
  java: ["#E07B39", "J"], kt: ["#A97BFF", "K"], dart: ["#40C4FF", "D"], c: ["#7D97C7", "C"], h: ["#9E86C9", "h"], cpp: ["#5E8FD0", "C+"],
  cs: ["#7A5DC7", "C#"], sql: ["#D8A84A", "SQL"], graphql: ["#E535AB", "GQ"], csv: ["#6AAB73", "csv"],
  pdf: ["#E05A4F", "pdf"], zip: ["#9A9DA3", "zip"], gz: ["#9A9DA3", "gz"], tar: ["#9A9DA3", "tar"], phar: ["#8E86E8", "phr"],
  dockerfile: ["#3F8FD8", "D"], env: null, less_: null,
};
const IMG = new Set(["png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "heic", "avif", "svg"]);
const fileIconCache = new Map();
function chip(color, text) {
  const fs = text.length >= 3 ? 6.3 : text.length === 2 ? 7.2 : 8.6;
  return `<svg class="fi" viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="13" height="11" rx="2.6" fill="${color}22" stroke="${color}" stroke-width="1"/>` +
    `<text x="8" y="10.6" text-anchor="middle" font-size="${fs}" font-weight="700" font-family="-apple-system,system-ui,sans-serif" fill="${color}">${text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")}</text></svg>`;
}
function glyph(color, inner) { return `<svg class="fi" viewBox="0 0 16 16" fill="none" stroke="${color}" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`; }
const DOC = '<path d="M4 1.8h5.2L12.5 5v9.2H4z"/><path d="M9.2 1.8V5h3.3"/>';
// Returns SVG markup for a file/folder row.
function fileIcon(name, dir, open, root) {
  const key = (dir ? (root ? "R" : open ? "O" : "D") : "F") + name.toLowerCase();
  if (fileIconCache.has(key)) return fileIconCache.get(key);
  let svg;
  const lower = name.toLowerCase();
  if (dir) {
    const color = root ? "#6C9BD2" : "#9AA0A8";
    svg = open
      ? glyph(color, '<path d="M1.8 4.2a.8.8 0 0 1 .8-.8h3.3l1.2 1.2h5.6a.8.8 0 0 1 .8.8v1.2"/><path d="M1.8 12.6V4.2M1.8 12.6l1.9-5.3a.8.8 0 0 1 .8-.5h9.4a.6.6 0 0 1 .6.8l-1.7 4.6a.8.8 0 0 1-.8.5H2.6a.8.8 0 0 1-.8-.1z"/>')
      : `<svg class="fi" viewBox="0 0 16 16"><path d="M1.8 4.2a.8.8 0 0 1 .8-.8h3.3l1.2 1.2h6.3a.8.8 0 0 1 .8.8v7.2a.8.8 0 0 1-.8.8H2.6a.8.8 0 0 1-.8-.8z" fill="${color}33" stroke="${color}" stroke-width="1.2" stroke-linejoin="round"/>${root ? `<circle cx="8" cy="8.6" r="1.6" fill="${color}"/>` : ""}</svg>`;
  } else {
    const ext = lower.includes(".") ? lower.split(".").pop() : "";
    if (lower === "dockerfile" || lower.startsWith("dockerfile.")) svg = chip("#3F8FD8", "D");
    else if (lower === "makefile") svg = chip("#9C8E7A", "M");
    else if (lower.endsWith(".blade.php")) svg = chip("#F05340", "b");
    else if ([".gitignore", ".gitattributes", ".gitmodules", ".gitkeep"].includes(lower))
      svg = glyph("#E0684B", '<path d="M8 1.8l6.2 6.2L8 14.2 1.8 8z"/><circle cx="8" cy="5.6" r=".9"/><circle cx="8" cy="10.4" r=".9"/><path d="M8 6.5v3"/>');
    else if (lower === ".htaccess" || lower === ".htpasswd" || lower === "nginx.conf") svg = chip("#9C8E7A", "ht");
    else if (lower.startsWith(".env")) svg = glyph("#C9A44A", '<circle cx="5.5" cy="10.5" r="2.6"/><path d="M7.3 8.7L13 3M10.6 5.4l1.6 1.6M12 4l1.4 1.4"/>');
    else if (ext === "lock" || lower === "composer.lock" || lower === "package-lock.json")
      svg = glyph("#9AA0A8", '<rect x="3.5" y="7" width="9" height="7" rx="1.2"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/>');
    else if (IMG.has(ext)) svg = glyph("#B18BE0", '<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="1.6"/><circle cx="5.6" cy="6.3" r="1.2"/><path d="M2.4 12.2l3.8-3.6 2.6 2.4 2-1.8 3.2 3"/>');
    else if (ext === "txt" || ext === "log" || ext === "") svg = glyph("#9AA0A8", DOC + '<path d="M6 8h4.5M6 10.3h4.5M6 12.4h3"/>');
    else if (FT[ext]) svg = chip(FT[ext][0], FT[ext][1]);
    else svg = glyph("#8C9097", DOC);
  }
  fileIconCache.set(key, svg);
  return svg;
}
