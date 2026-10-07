"use strict";
// Elio IDE: Monaco + xterm.js, bridged to Swift (files, git, search, shells, agents).
// The page is split in classic scripts sharing one global scope, loaded in order: icons.js (sprite), ide.js (core:
// workspace, tree, editor, tool windows, terminals, window.IDE), git.js, gitlog.js, problems.js, structure.js, run.js.

// ---------- Bridge ----------
const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.elio;
const api = (op, args = {}) => native ? native.postMessage({ op, args }) : Promise.reject(new Error("fuori da Elio"));
const listeners = {};
window.__elio = { event(e) { emitLocal(e.name, e.data); } };
const on = (name, f) => (listeners[name] = listeners[name] || []).push(f);
// Errors in the page end up in ~/Library/Logs/Elio/ide.log (there's no console to look at in the app).
const reportError = (kind, msg, where) => { try { api("pageError", { kind, message: String(msg).slice(0, 2000), where: String(where || "").slice(0, 500) }).catch(() => {}); } catch {} };
window.addEventListener("error", e => reportError("error", e.message, `${e.filename || ""}:${e.lineno || 0}:${e.colno || 0}\n${e.error && e.error.stack || ""}`));
window.addEventListener("unhandledrejection", e => reportError("rejection", e.reason && (e.reason.message || e.reason), e.reason && e.reason.stack));
// Page-side events go through the same registry, so IDE.on() also hears "projectChanged", "tabChanged", "saved".
function emitLocal(name, data) { (listeners[name] || []).forEach(f => { try { f(data); } catch (err) { console.error(err); } }); }

const $ = s => document.querySelector(s);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const basename = p => p.split("/").pop();
const dirname = p => p.slice(0, p.lastIndexOf("/"));
const tilde = p => (p || "").replace(/^\/Users\/[^/]+/, "~");
const store = {
  get(k, d) { try { const v = localStorage.getItem("ide." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem("ide." + k, JSON.stringify(v)); } catch {} },
};
function toast(text, kind = "info") {
  const t = $("#toast");
  const ms = typeof kind === "number" ? kind : kind === "error" ? 7000 : 2800;
  t.className = "toast-" + (typeof kind === "string" ? kind : "info");
  t.textContent = String(text || "");
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.add("hidden"), ms);
  t.onclick = () => t.classList.add("hidden");
}
// External links: only http(s) and mailto leave the IDE (Swift checks again before opening the browser).
function openLink(uri) {
  const u = String(uri || "").trim();
  if (!/^(https?:\/\/|mailto:)/i.test(u)) { toast("Link non aperto: solo http, https e mailto", "error"); return; }
  api("openExternal", { url: u }).catch(e => toast(e.message || String(e), "error"));
}
function status(text) { $("#stMsg").textContent = text || ""; }
function relTime(sec) {
  const d = Date.now() / 1000 - sec;
  if (d < 60) return "adesso";
  if (d < 3600) return `${Math.floor(d / 60)} min fa`;
  if (d < 86400) return `${Math.floor(d / 3600)} ore fa`;
  if (d < 172800) return "ieri";
  if (d < 86400 * 30) return `${Math.floor(d / 86400)} giorni fa`;
  return fmtDate(sec);
}
function fmtDate(sec, time) {
  const dt = new Date(sec * 1000);
  const s = dt.toLocaleDateString("it-IT", { day: "2-digit", month: "2-digit", year: "numeric" });
  return time ? s + " " + dt.toLocaleTimeString("it-IT", { hour: "2-digit", minute: "2-digit" }) : s;
}
const boots = [];
// Modules (git.js, problems.js…) run their setup once Monaco is loaded and the workspace restored.
function onBoot(f) { boots.push(f); }

// ---------- State ----------
const S = {
  roots: [],                // workspace: several projects at once { name, path }
  projects: [],             // known projects (Settings)
  filesBy: new Map(),       // root path → relative paths (go to file)
  tabs: [],                 // { path, model, view, dirty, mtime, head, saving, agentEdit, virtual… }
  active: null,
  closed: [],
  recent: [],               // absolute paths
  expanded: new Set(),
  selected: null,           // tree selection (absolute path)
  agents: [],
  panels: [],               // terminal tool window tabs: { id, kind: 'shell'|'agent', title, el, term, … }
  panel: null,
  nav: [], navIndex: -1,
  elio: { state: "off", connected: false },
};

// ---------- Workspace ----------
function rootOf(path) {
  if (!path) return null;
  let best = null;
  for (const r of S.roots) if ((path === r.path || path.startsWith(r.path + "/")) && (!best || r.path.length > best.path.length)) best = r;
  return best;
}
// The current project: the root of the active editor tab, else of the tree selection, else the first.
function cur() {
  const p = S.active && !S.active.virtual ? S.active.path : null;
  return (p && rootOf(p)) || (S.selected && rootOf(S.selected)) || S.roots[0] || null;
}
function relative(p, root) {
  const r = root || rootOf(p);
  if (!r) return p;
  return p === r.path ? "" : p.startsWith(r.path + "/") ? p.slice(r.path.length + 1) : p;
}
function saveWorkspace() { store.set("workspace", S.roots.map(r => ({ name: r.name, path: r.path }))); }
function watchRoots() { api("watch", { roots: S.roots.map(r => r.path) }).catch(() => {}); }
async function addRoot(p, opts = {}) {
  let r = S.roots.find(x => x.path === p.path);
  if (!r) {
    const known = S.projects.find(x => x.path === p.path);
    r = { name: p.name || (known && known.name) || basename(p.path), path: p.path };
    S.roots.push(r);
    S.expanded.add(r.path);
    saveWorkspace(); watchRoots(); loadFiles(r);
    if (typeof refreshGit === "function") refreshGit(r);
  }
  if (opts.select !== false) S.selected = r.path;
  await renderTree();
  onCurrentChanged(true);
  return r;
}
const openProject = p => addRoot(p);
async function removeRoot(r) {
  const inside = S.tabs.filter(t => !t.virtual && (t.path === r.path || t.path.startsWith(r.path + "/")));
  for (const t of inside) await closeTab(t);
  S.roots = S.roots.filter(x => x !== r);
  S.filesBy.delete(r.path);
  if (S.selected && S.selected.startsWith(r.path)) S.selected = null;
  saveWorkspace(); watchRoots();
  if (typeof forgetRepo === "function") forgetRepo(r.path);
  await renderTree();
  onCurrentChanged(true);
}
async function addFolder() {
  let paths = [];
  try { paths = await api("pickFolder"); } catch (e) { toast(e.message, "error"); return; }
  let last = null;
  for (const p of paths || []) last = await addRoot({ path: p });
  if (last) { showToolWindow("project"); revealInTree(last.path); }
}
async function loadFiles(r) {
  if (!r) return;
  try { S.filesBy.set(r.path, await api("files", { root: r.path })); } catch { S.filesBy.set(r.path, []); }
}
let lastCurrent = null;
function onCurrentChanged(force) {
  const r = cur();
  const key = r ? r.path : "";
  if (!force && key === lastCurrent) return;
  lastCurrent = key;
  $("#projectName").textContent = r ? r.name : "Aggiungi un progetto";
  const badge = $("#projBadge");
  badge.textContent = r ? initials(r.name) : "+";
  badge.style.background = r ? colorFor(r.name) : "#ffffff18";
  api("title", { title: r ? `${r.name} — Elio IDE` : "Elio IDE" }).catch(() => {});
  if (typeof renderGitWidget === "function") renderGitWidget();
  emitLocal("projectChanged", r ? { name: r.name, path: r.path } : null);
}
function initials(name) {
  const w = name.replace(/[^A-Za-z0-9 _.-]/g, "").split(/[\s_.-]+/).filter(Boolean);
  return ((w[0] || "?")[0] + (w[1] ? w[1][0] : (w[0] || "").slice(1, 2))).toUpperCase();
}
function colorFor(s) {
  const colors = ["#3D7BD9", "#C2507A", "#4E9A5C", "#B07A2C", "#7E5BC9", "#2F95A3", "#C4613A", "#5C6BC0"];
  let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return colors[h % colors.length];
}

// ---------- Monaco ----------
require.config({ paths: { vs: "vendor/monaco/vs" } });
window.MonacoEnvironment = { getWorkerUrl: () => "vendor/monaco/vs/base/worker/workerMain.js" };
let editor, diffEditor;

const LANG = { php: "php", phtml: "php", inc: "php", js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "javascript", ts: "typescript", tsx: "typescript",
  vue: "html", html: "html", htm: "html", twig: "twig", css: "css", scss: "scss", less: "less", json: "json", md: "markdown",
  yml: "yaml", yaml: "yaml", xml: "xml", xsd: "xml", plist: "xml", svg: "xml", sql: "sql", sh: "shell", zsh: "shell", bash: "shell", py: "python",
  swift: "swift", dart: "dart", kt: "kotlin", kts: "kotlin", java: "java", go: "go", rs: "rust", rb: "ruby", c: "c", h: "c",
  m: "objective-c", cpp: "cpp", cs: "csharp", ini: "ini", env: "ini", toml: "ini", conf: "ini", neon: "yaml", graphql: "graphql", dockerfile: "dockerfile",
  lua: "lua", r: "r", scala: "scala", txt: "plaintext", lock: "json" };
function langOf(path) {
  const name = basename(path).toLowerCase();
  if (name === "dockerfile") return "dockerfile";
  if (name.endsWith(".blade.php")) return "html";
  if (name.startsWith(".env")) return "ini";
  if (name === ".htaccess") return "ini";
  const ext = name.includes(".") ? name.split(".").pop() : "";
  return LANG[ext] || "plaintext";
}

require(["vs/editor/editor.main"], () => {
  monaco.editor.defineTheme("darcula", {
    base: "vs-dark", inherit: true,
    rules: [
      { token: "keyword", foreground: "CF8E6D" }, { token: "keyword.php", foreground: "CF8E6D" },
      { token: "string", foreground: "6AAB73" }, { token: "string.escape", foreground: "CF8E6D" },
      { token: "number", foreground: "2AACB8" }, { token: "comment", foreground: "7A7E85", fontStyle: "italic" },
      { token: "variable", foreground: "C77DBB" }, { token: "variable.predefined", foreground: "C77DBB" },
      { token: "type", foreground: "BCBEC4" }, { token: "type.identifier", foreground: "BCBEC4" },
      { token: "tag", foreground: "D5B778" }, { token: "metatag", foreground: "D5B778" }, { token: "attribute.name", foreground: "BABABA" },
      { token: "attribute.value", foreground: "6AAB73" }, { token: "delimiter", foreground: "BCBEC4" }, { token: "annotation", foreground: "B3AE60" },
      { token: "identifier", foreground: "BCBEC4" }, { token: "constant", foreground: "C77DBB" }, { token: "regexp", foreground: "42C3D4" },
    ],
    colors: {
      "editor.background": "#1E1F22", "editor.foreground": "#BCBEC4", "editorLineNumber.foreground": "#4B5059",
      "editorLineNumber.activeForeground": "#A1A3AB", "editor.lineHighlightBackground": "#26282E", "editor.lineHighlightBorder": "#00000000",
      "editor.selectionBackground": "#214283", "editor.inactiveSelectionBackground": "#21428388", "editorCursor.foreground": "#CED0D6",
      "editorIndentGuide.background1": "#2F3136", "editorIndentGuide.activeBackground1": "#45484F", "editorWhitespace.foreground": "#393B40",
      "editorGutter.background": "#1E1F22", "editor.findMatchHighlightBackground": "#32593D", "editor.findMatchBackground": "#2E5A3A",
      "editorBracketMatch.background": "#3B514D", "editorBracketMatch.border": "#00000000", "minimap.background": "#1E1F22",
      "editorWidget.background": "#2B2D30", "editorWidget.border": "#393B40", "editorSuggestWidget.selectedBackground": "#2E436E",
      "scrollbarSlider.background": "#ffffff18", "editorOverviewRuler.border": "#00000000",
      "editorError.foreground": "#F75464", "editorWarning.foreground": "#E0A64F",
      "diffEditor.insertedLineBackground": "#294436aa", "diffEditor.removedLineBackground": "#484A4A00",
    },
  });
  editor = monaco.editor.create($("#editor"), {
    theme: "darcula", automaticLayout: true, fontFamily: "JetBrains Mono, SF Mono, Menlo, monospace", fontSize: 13, lineHeight: 20,
    fontLigatures: true, minimap: { enabled: true, renderCharacters: false, scale: 1 }, smoothScrolling: true, cursorSmoothCaretAnimation: "on",
    renderWhitespace: "selection", bracketPairColorization: { enabled: true }, guides: { bracketPairs: "active", indentation: true },
    stickyScroll: { enabled: true }, scrollBeyondLastLine: false, mouseWheelZoom: true, linkedEditing: true, tabSize: 4,
    suggest: { preview: true }, inlayHints: { enabled: "on" }, occurrencesHighlight: "singleFile", padding: { top: 6 },
  });
  diffEditor = monaco.editor.createDiffEditor($("#diffEditor"), {
    theme: "darcula", automaticLayout: true, readOnly: false, renderSideBySide: true, fontFamily: "JetBrains Mono, SF Mono, Menlo, monospace",
    fontSize: 13, originalEditable: false, ignoreTrimWhitespace: false,
  });
  // Links in the editor (ctrl+click, hovers): through the same checked path, never window.open.
  try { monaco.editor.registerLinkOpener({ open(uri) { openLink(uri.toString(true)); return true; } }); } catch {}
  setupKeys();
  editor.onDidChangeCursorPosition(e => {
    $("#stPos").textContent = `${e.position.lineNumber}:${e.position.column}`;
    rememberNav();
    clearTimeout(crumbTimer); crumbTimer = setTimeout(renderCrumbSymbol, 160);
  });
  editor.onDidChangeModelContent(() => onEdit());
  editor.onDidBlurEditorText(() => saveActive());
  boot();
});

// ---------- Boot ----------
let booted = false;
async function boot() {
  ensureSprite();
  buildChrome();
  wireUI();
  setupSplitters();
  setupDocks();
  try { S.projects = await api("projects"); } catch (e) { S.projects = []; }
  let ws = store.get("workspace", null);
  if (!ws) { const last = store.get("project", null); ws = last ? [{ name: (S.projects.find(p => p.path === last) || {}).name || basename(last), path: last }] : []; }
  S.roots = ws.filter(r => r && r.path);
  S.expanded = new Set(store.get("expanded", S.roots.map(r => r.path)));
  S.recent = store.get("recent", []);
  watchRoots();
  await renderTree();
  S.roots.forEach(loadFiles);
  booted = true;
  renderStrip();
  for (const f of boots) { try { await f(); } catch (e) { console.error(e); } }
  const session = store.get("session", null);
  if (session) {
    for (const path of session.tabs || []) if (rootOf(path)) await openFile(path, { background: true });
    if (session.active && rootOf(session.active)) await openFile(session.active);
  }
  renderTabs(); showEditor(); onCurrentChanged(true);
  for (const k of PK) {
    const tw = TW.get(layout.open[k]);
    if (tw && !tw.proxy && tw.pk === k) showToolWindow(tw.id, { focus: false });
  }
  saveLayout();
  api("ready").catch(() => {});
  refreshAgents();
  api("elioState").then(setElioState).catch(() => {});
  renderWelcome();
  window.IDE.ready = true;
  window.dispatchEvent(new Event("ide-ready"));
}

// ---------- Tree (several roots, virtualized: only the visible rows are in the DOM) ----------
const treeCache = new Map();
const ROW_H = 22;
let flat = [], treeBuild = 0;
async function listDir(path, force) {
  if (!force && treeCache.has(path)) return treeCache.get(path);
  let items = [];
  try { items = await api("list", { path }); } catch {}
  treeCache.set(path, items);
  return items;
}
async function renderTree() {
  const my = ++treeBuild;
  const rows = [];
  for (const r of S.roots) {
    rows.push({ path: r.path, name: r.name, dir: true, depth: 0, root: r });
    if (S.expanded.has(r.path)) await walkDir(r.path, 1, rows);
  }
  if (my !== treeBuild) return;
  flat = rows;
  paintTree();
}
async function walkDir(path, depth, rows) {
  for (const it of await listDir(path)) {
    rows.push({ name: it.name, path: it.path, dir: it.dir, dim: it.dim, depth });
    if (it.dir && S.expanded.has(it.path)) await walkDir(it.path, depth + 1, rows);
  }
}
let paintQueued = false;
function paintTreeSoon() { if (paintQueued) return; paintQueued = true; requestAnimationFrame(() => { paintQueued = false; paintTree(); }); }
function paintTree() {
  const box = $("#tree");
  if (!box) return;
  if (!S.roots.length) {
    box.innerHTML = "";
    const e = el("div", "empty-state");
    e.append(el("div", "", "Nessun progetto nel workspace."));
    const add = el("button", "btn go", "Aggiungi cartella…"); add.onclick = addFolder;
    const list = el("button", "btn", "Dai progetti…"); list.onclick = () => showPalette("projects");
    e.append(add, list); box.append(e);
    return;
  }
  let inner = box.querySelector(".tree-inner");
  if (!inner) { box.innerHTML = ""; inner = el("div", "tree-inner"); box.append(inner); }
  inner.style.height = flat.length * ROW_H + "px";
  const top = box.scrollTop, h = box.clientHeight || 800;
  const from = Math.max(0, Math.floor(top / ROW_H) - 8), to = Math.min(flat.length, Math.ceil((top + h) / ROW_H) + 8);
  const frag = document.createDocumentFragment();
  for (let i = from; i < to; i++) frag.append(treeRow(flat[i], i));
  inner.replaceChildren(frag);
}
function treeRow(it, i) {
  const open = it.dir && S.expanded.has(it.path);
  const row = el("div", "row" + (it.dim ? " dim" : "") + (it.root ? " root" : "") + (S.selected === it.path ? " sel" : ""));
  row.style.top = i * ROW_H + "px";
  row.style.paddingLeft = (6 + it.depth * 16) + "px";
  const tw = el("span", "tw");
  if (it.dir) tw.innerHTML = icon(open ? "chevronDown" : "chevronRight");
  const ic = el("span", "ic"); ic.innerHTML = fileIcon(it.name, it.dir, open, !!it.root);
  const nm = el("span", "nm", it.name);
  row.append(tw, ic, nm);
  if (it.root) {
    const p = el("span", "rpath", tilde(dirname(it.path)) === "~" ? "~" : tilde(it.path));
    row.append(p);
    if (typeof repoBadge === "function") { const b = repoBadge(it.path); if (b) row.append(b); }
  }
  const g = typeof gitClass === "function" ? gitClass(it.path, it.dir) : "";
  if (g) row.classList.add(g);
  const pc = typeof problemClass === "function" ? problemClass(it.path, it.dir) : "";
  if (pc) row.classList.add(pc);
  row.dataset.path = it.path;
  row.onclick = e => treeClick(it, e);
  row.ondblclick = () => { if (!it.dir) openFile(it.path); };
  row.oncontextmenu = e => { e.preventDefault(); S.selected = it.path; paintTree(); treeMenu(e, it); };
  if (!it.root) {
    row.draggable = true;
    row.ondragstart = e => { e.dataTransfer.setData("text/elio-path", it.path); e.dataTransfer.effectAllowed = "move"; };
  }
  if (it.dir) {
    row.ondragover = e => { if (e.dataTransfer.types.includes("text/elio-path")) { e.preventDefault(); row.classList.add("drop"); } };
    row.ondragleave = () => row.classList.remove("drop");
    row.ondrop = e => { e.preventDefault(); row.classList.remove("drop"); const from = e.dataTransfer.getData("text/elio-path"); if (from) moveEntry(from, it.path); };
  }
  return row;
}
async function treeClick(it, e) {
  S.selected = it.path;
  $("#tree").focus({ preventScroll: true });
  if (it.dir) {
    S.expanded.has(it.path) ? S.expanded.delete(it.path) : S.expanded.add(it.path);
    store.set("expanded", [...S.expanded]);
    await renderTree();
  } else {
    paintTree();
    openFile(it.path, { keepFocus: e && e.detail === 1 });
  }
  onCurrentChanged();
}
function treeKeys(e) {
  if (e.metaKey && e.key !== "Backspace") return;
  const i = flat.findIndex(r => r.path === S.selected);
  const it = flat[i];
  const select = j => {
    const n = flat[Math.max(0, Math.min(flat.length - 1, j))]; if (!n) return;
    S.selected = n.path; paintTree(); scrollTreeTo(flat.indexOf(n)); onCurrentChanged();
  };
  const k = e.key;
  if (k === "ArrowDown") select(i + 1);
  else if (k === "ArrowUp") select(i - 1);
  else if (k === "ArrowRight" && it) { if (it.dir && !S.expanded.has(it.path)) { S.expanded.add(it.path); renderTree(); } else select(i + 1); }
  else if (k === "ArrowLeft" && it) {
    if (it.dir && S.expanded.has(it.path)) { S.expanded.delete(it.path); renderTree(); }
    else { const parent = flat.findIndex(r => r.path === dirname(it.path)); if (parent >= 0) select(parent); }
  }
  else if (k === "Enter" && it) { it.dir ? treeClick(it) : openFile(it.path); }
  else if ((k === "Backspace" && e.metaKey || k === "Delete") && it && !it.root) trashEntry(it);
  else if (k === "F6" && e.shiftKey && it && !it.root) renameEntry(it);
  else return;
  e.preventDefault();
}
function scrollTreeTo(i) {
  const box = $("#tree"); if (i < 0 || !box) return;
  const y = i * ROW_H;
  if (y < box.scrollTop || y > box.scrollTop + box.clientHeight - ROW_H) box.scrollTop = y - box.clientHeight / 2;
  paintTree();
}
async function revealInTree(path) {
  const r = rootOf(path); if (!r) return;
  let d = path;
  while (d.length > r.path.length) { d = dirname(d); S.expanded.add(d); }
  S.expanded.add(r.path);
  S.selected = path;
  showToolWindow("project", { focus: false });
  await renderTree();
  scrollTreeTo(flat.findIndex(x => x.path === path));
  const row = document.querySelector(`#tree .row[data-path="${CSS.escape(path)}"]`);
  if (row) { row.classList.add("flash"); }
}
async function expandAll() {
  const start = S.selected && flat.find(r => r.path === S.selected && r.dir);
  const queue = start ? [start.path] : S.roots.map(r => r.path);
  let count = 0;
  // Bounded: Magento-sized trees would add thousands of folders. Ignored/vendor folders are skipped.
  while (queue.length && count < 400) {
    const d = queue.shift(); S.expanded.add(d); count++;
    for (const it of await listDir(d)) if (it.dir && !it.dim) queue.push(it.path);
  }
  store.set("expanded", [...S.expanded]);
  renderTree();
}
function collapseAll() {
  S.expanded = new Set(S.roots.map(r => r.path));
  store.set("expanded", [...S.expanded]);
  renderTree();
}
function selectedDir() {
  const p = S.selected || (S.active && !S.active.virtual && S.active.path) || (cur() && cur().path);
  if (!p) return null;
  const row = flat.find(r => r.path === p);
  return row ? (row.dir ? p : dirname(p)) : (S.roots.some(r => r.path === p) ? p : dirname(p));
}
function treeMenu(e, it) {
  const dir = it.dir ? it.path : dirname(it.path);
  const r = rootOf(it.path);
  const gitItems = typeof gitTreeItems === "function" ? gitTreeItems(it) : null;
  menu(e, [
    { label: "Nuovo file…", icon: "newFile", action: () => createEntry(dir, false), key: "⌘N" },
    { label: "Nuova cartella…", icon: "newFolder", action: () => createEntry(dir, true) },
    null,
    !it.dir && { label: "Apri", action: () => openFile(it.path) },
    !it.root && { label: "Rinomina…", icon: "edit", action: () => renameEntry(it), key: "⇧F6" },
    !it.root && { label: "Sposta nel Cestino", icon: "trash", action: () => trashEntry(it), key: "⌘⌫", danger: true },
    null,
    { label: "Copia percorso", icon: "copy", action: () => copy(it.path) },
    { label: "Copia percorso relativo", action: () => copy(relative(it.path, r)) },
    { label: "Mostra nel Finder", icon: "open", action: () => api("reveal", { path: it.path }) },
    { label: "Apri in PhpStorm", action: () => api("openExternal", { path: it.path, app: "PhpStorm" }) },
    { label: "Apri terminale qui", icon: "terminal", action: () => newShell(dir) },
    { label: "Cerca in questa cartella…", icon: "find", action: () => openSearch("", dir) },
    gitItems && null,
    gitItems && { label: "Git", icon: "git", items: gitItems },
    null,
    { label: "Chiedi a Elio su questo…", icon: "elio", action: () => askElio(`Riguardo a ${it.path}: `) },
    it.root && null,
    it.root && { label: "Rimuovi dal workspace", icon: "close", action: () => removeRoot(it.root) },
  ]);
}
function newEntryMenu() {
  const dir = selectedDir(); if (!dir) { addFolder(); return; }
  const anchor = $("#tree").getBoundingClientRect();
  menu({ clientX: anchor.left + 40, clientY: anchor.top + 40 }, [
    { label: `Nuovo in ${basename(dir)}`, disabled: true },
    { label: "File…", icon: "newFile", action: () => createEntry(dir, false) },
    { label: "Cartella…", icon: "newFolder", action: () => createEntry(dir, true) },
  ]);
}
async function createEntry(dir, isDir) {
  const name = await prompt_(isDir ? "Nuova cartella" : "Nuovo file", "", isDir ? "nome-cartella (anche a/b/c)" : "NomeFile.php (anche sotto/cartelle/File.php)");
  if (!name) return;
  const path = dir + "/" + name.replace(/^\/+/, "");
  try {
    await api("create", { path, dir: isDir });
    treeCache.delete(dir); treeCache.delete(dirname(path)); S.expanded.add(dir);
    let d = dirname(path); while (d.length > dir.length) { S.expanded.add(d); treeCache.delete(d); d = dirname(d); }
    await renderTree();
    if (!isDir) openFile(path);
    revealInTree(path);
    refreshGitSoon();
  } catch (e) { toast("Non riesco a crearlo: " + e.message, "error"); }
}
async function renameEntry(it) {
  const name = await prompt_("Rinomina", it.name, it.name);
  if (!name || name === it.name) return;
  await moveTo(it.path, dirname(it.path) + "/" + name);
}
async function moveEntry(from, toDir) {
  if (from === toDir || dirname(from) === toDir || toDir.startsWith(from + "/")) return;
  if (!(await confirm_(`Sposto ${basename(from)} in ${basename(toDir)}?`, tilde(toDir), "Sposta"))) return;
  await moveTo(from, toDir + "/" + basename(from));
}
async function moveTo(from, to) {
  try {
    await api("rename", { from, to });
    treeCache.delete(dirname(from)); treeCache.delete(dirname(to));
    for (const t of S.tabs) if (!t.virtual && (t.path === from || t.path.startsWith(from + "/"))) await retargetTab(t, to + t.path.slice(from.length));
    if (S.selected === from) S.selected = to;
    await renderTree(); renderTabs(); refreshGitSoon();
  } catch (e) { toast("Non riesco: " + e.message, "error"); }
}
// A renamed/moved file keeps its tab: new model on the new path, same text and view.
async function retargetTab(t, path) {
  const text = t.model.getValue(), view = t === S.active ? editor.saveViewState() : t.view;
  const model = monaco.editor.createModel(text, langOf(path), monaco.Uri.file(path));
  model._tab = t;
  const old = t.model;
  t.path = path; t.model = model; t.view = view;
  if (t === S.active) { editor.setModel(model); if (view) editor.restoreViewState(view); }
  old.dispose();
}
async function trashEntry(it) {
  if (!(await confirm_(`Sposto nel Cestino ${it.name}?`, "Lo puoi recuperare dal Cestino.", "Sposta nel Cestino", { danger: true }))) return;
  try {
    await api("trash", { path: it.path });
    treeCache.delete(dirname(it.path));
    S.tabs.filter(t => !t.virtual && (t.path === it.path || t.path.startsWith(it.path + "/"))).forEach(t => closeTab(t, { discard: true }));
    await renderTree(); refreshGitSoon();
  } catch (e) { toast("Non riesco: " + e.message, "error"); }
}

// ---------- Tabs & editor ----------
async function openFile(path, opts = {}) {
  let tab = S.tabs.find(t => t.path === path);
  if (!tab) {
    let r;
    try { r = await api("read", { path }); } catch (e) { toast(e.message || String(e), "error"); return; }
    if (r.binary) { api("openExternal", { path }).catch(e => toast(e.message || String(e), "error")); return; }
    const uri = monaco.Uri.file(path);
    const model = monaco.editor.getModel(uri) || monaco.editor.createModel(r.content, langOf(path), uri);
    model.updateOptions({ tabSize: guessIndent(r.content) });
    tab = { path, model, view: null, dirty: false, mtime: r.mtime, head: null };
    model._tab = tab;
    S.tabs.push(tab);
    if (typeof loadHead === "function") loadHead(tab);
    if (typeof runChecks === "function") runChecks(tab, { deep: false });
  }
  if (!opts.background) {
    activate(tab);
    if (opts.line) {
      editor.revealLineInCenter(opts.line);
      editor.setPosition({ lineNumber: opts.line, column: opts.col || 1 });
      if (opts.highlight) flashLine(opts.line);
    }
    if (!opts.keepFocus) editor.focus();
  }
  renderTabs();
  return tab;
}
function guessIndent(text) {
  const m = text.match(/^( +)\S/m);
  return m ? (m[1].length === 2 ? 2 : 4) : 4;
}
function activate(tab) {
  if (S.active && S.active !== tab) { S.active.view = editor.saveViewState(); saveActive(); }
  S.active = tab;
  hideDiff();
  editor.setModel(tab.model);
  editor.updateOptions({ readOnly: !!tab.readOnly });
  if (tab.view) editor.restoreViewState(tab.view);
  if (!tab.virtual) S.recent = [tab.path, ...S.recent.filter(p => p !== tab.path)].slice(0, 50);
  updateStatusFile();
  renderCrumbs(); showEditor();
  if (typeof decorate === "function") decorate(tab);
  if (typeof blameRefresh === "function") blameRefresh();
  if (tab.agentEdit) tab.agentEdit = false;
  onCurrentChanged();
  emitLocal("tabChanged", tab.virtual ? { id: tab.id, virtual: true } : { path: tab.path });
}
function updateStatusFile() {
  const t = S.active;
  $("#stLang").textContent = t ? t.model.getLanguageId() : "";
  $("#stIndent").textContent = t ? `${t.model.getOptions().tabSize} spazi` : "";
  $("#stEol").textContent = t ? (t.model.getEOL() === "\r\n" ? "CRLF" : "LF") : "";
  $("#stEnc").textContent = t ? "UTF-8" : "";
  if (!t) $("#stPos").textContent = "";
}
function showEditor() { $("#welcome").classList.toggle("hidden", !!S.active); }
function tabTitle(t) {
  if (t.virtual) return t.title;
  const name = basename(t.path);
  // Same name in two tabs (index.php, di.xml…): add the parent folder, like PhpStorm.
  return S.tabs.some(o => o !== t && !o.virtual && basename(o.path) === name) ? `${name} · ${basename(dirname(t.path))}` : name;
}
function renderTabs() {
  const bar = $("#tabs"); bar.innerHTML = "";
  for (const t of S.tabs) {
    const g = !t.virtual && typeof gitClass === "function" ? gitClass(t.path) : "";
    const pc = !t.virtual && typeof problemClass === "function" ? problemClass(t.path) : "";
    const tab = el("div", "tab" + (t === S.active ? " on" : "") + (t.dirty ? " dirty" : "") + (g ? " " + g : "") + (pc ? " " + pc : ""));
    const ic = el("span", "ic"); ic.innerHTML = t.virtual ? (t.icon ? icon(t.icon) : fileIcon(t.title, false)) : fileIcon(basename(t.path), false);
    tab.append(ic, el("span", "nm", tabTitle(t)));
    if (t.readOnly) { const l = el("span", "lock"); l.innerHTML = icon("lock"); tab.append(l); }
    if (t.agentEdit) tab.append(el("span", "badge", "AGENTE"));
    const x = el("span", "x"); x.innerHTML = icon("close"); x.onclick = e => { e.stopPropagation(); closeTab(t); };
    tab.append(x);
    tab.title = t.virtual ? t.title : tilde(t.path);
    tab.onclick = () => { activate(t); renderTabs(); editor.focus(); };
    tab.onauxclick = e => { if (e.button === 1) closeTab(t); };
    tab.oncontextmenu = e => { e.preventDefault(); menu(e, [
      ["Chiudi", () => closeTab(t), "⌘W"], ["Chiudi le altre", () => S.tabs.filter(o => o !== t).forEach(o => closeTab(o))],
      ["Chiudi tutte", () => [...S.tabs].forEach(o => closeTab(o))], null,
      !t.virtual && ["Mostra nell'albero", () => revealInTree(t.path), "⌥F1"], !t.virtual && ["Copia percorso", () => copy(t.path)],
      !t.virtual && ["Mostra le modifiche (diff)", () => showDiff(t.path)],
    ]); };
    bar.append(tab);
    if (t === S.active) setTimeout(() => tab.scrollIntoView({ inline: "nearest" }), 0);
  }
  saveSession();
}
function saveSession() {
  if (!booted) return;
  const real = S.tabs.filter(t => !t.virtual);
  store.set("session", { tabs: real.map(t => t.path), active: S.active && !S.active.virtual ? S.active.path : null });
  store.set("expanded", [...S.expanded]);
  store.set("recent", S.recent.slice(0, 50));
}
window.addEventListener("beforeunload", saveSession);
async function closeTab(t, opts = {}) {
  if (t.dirty && !opts.discard) {
    if (t.virtual) {
      if (t.onSave && await confirm_(`Salvo le modifiche a ${t.title}?`, "Altrimenti vanno perse.", "Salva")) await save(t);
    } else await save(t);
  }
  const i = S.tabs.indexOf(t);
  if (i < 0) return;
  S.tabs.splice(i, 1);
  if (!t.virtual) S.closed.push(t.path);
  if (t.onClose) { try { t.onClose(); } catch {} }
  if (S.active === t) {
    S.active = null;
    const next = S.tabs[i] || S.tabs[i - 1];
    if (next) activate(next); else { editor.setModel(null); renderCrumbs(); showEditor(); updateStatusFile(); onCurrentChanged(); }
  }
  t.model.dispose();
  renderTabs();
}
// Editor tabs not backed by a local file (SQL console, remote file): see window.IDE.openEditorTab.
function openVirtualTab(o) {
  let t = S.tabs.find(x => x.virtual && x.id === o.id);
  if (!t) {
    const uri = monaco.Uri.parse(`elio-virtual:/${encodeURIComponent(o.id)}/${encodeURIComponent(o.title || "senza titolo")}`);
    const model = monaco.editor.getModel(uri) || monaco.editor.createModel(o.content || "", o.language || langOf(o.title || ""), uri);
    t = { virtual: true, id: o.id, title: o.title || o.id, path: "virtual:" + o.id, model, readOnly: !!o.readOnly, onSave: o.onSave, onClose: o.onClose,
      icon: o.icon, dirty: false };
    model._tab = t;
    S.tabs.push(t);
  }
  activate(t); renderTabs(); editor.focus();
  const handle = {
    setContent(text) { t.suppress = true; t.model.setValue(text == null ? "" : String(text)); t.suppress = false; t.dirty = false; renderTabs(); },
    getContent() { return t.model.getValue(); },
    focus() { if (S.tabs.includes(t)) { activate(t); renderTabs(); editor.focus(); } },
    close() { closeTab(t, { discard: true }); },
    setReadOnly(v) { t.readOnly = !!v; if (S.active === t) editor.updateOptions({ readOnly: t.readOnly }); renderTabs(); },
    get model() { return t.model; },
    get editor() { return editor; },
  };
  return handle;
}

// ---------- Saving (autosave like PhpStorm) ----------
let saveTimer;
function onEdit() {
  const t = S.active;
  if (!t || t.suppress) return;
  if (!t.dirty) { t.dirty = true; renderTabs(); }
  if (!t.virtual) { clearTimeout(saveTimer); saveTimer = setTimeout(() => save(t), 1200); }
  clearTimeout(t._decor); t._decor = setTimeout(() => { if (typeof decorate === "function") decorate(t); }, 400);
}
function saveActive() { if (S.active && S.active.dirty && !S.active.virtual) save(S.active); }
async function saveAll() {
  for (const t of S.tabs) if (t.dirty && (!t.virtual || t === S.active)) await save(t);
  toast("Tutto salvato", "ok");
}
async function save(t) {
  if (!t.dirty || t.saving) return;
  if (t.virtual) {
    if (!t.onSave) return;
    t.saving = true;
    try { await t.onSave(t.model.getValue()); t.dirty = false; } catch (e) { toast("Salvataggio non riuscito: " + (e.message || e), "error"); }
    t.saving = false; renderTabs();
    return;
  }
  t.saving = true; $("#stSave").textContent = "Salvo…"; $("#stSave").classList.add("saving");
  try {
    const r = await api("write", { path: t.path, content: t.model.getValue() });
    t.mtime = r.mtime; t.dirty = false;
    $("#stSave").textContent = "Salvato"; refreshGitSoon();
    emitLocal("saved", { path: t.path });
    if (typeof runChecks === "function") runChecks(t, { deep: true });
  } catch (e) { toast("Salvataggio non riuscito: " + e.message, "error"); $("#stSave").textContent = "Errore di salvataggio"; }
  t.saving = false; $("#stSave").classList.remove("saving");
  renderTabs();
}
async function saveAllQuiet() { for (const t of S.tabs) if (t.dirty && !t.virtual) await save(t); }

// ---------- Files changed on disk (agents, git) ----------
let fsTimer, fsPaths = new Set();
on("fsChanged", d => {
  d.paths.forEach(p => fsPaths.add(p));
  clearTimeout(fsTimer);
  fsTimer = setTimeout(applyFsChanges, 250);
});
async function applyFsChanges() {
  const paths = [...fsPaths]; fsPaths.clear();
  const dirs = new Set(paths.map(dirname));
  let treeDirty = false;
  for (const d of dirs) if (treeCache.has(d)) { treeCache.delete(d); treeDirty = true; }
  for (const p of paths) if (treeCache.has(p)) { treeCache.delete(p); treeDirty = true; }
  for (const t of S.tabs) {
    if (t.virtual || !paths.includes(t.path)) continue;
    let r; try { r = await api("read", { path: t.path }); } catch { continue; }
    if (r.binary || r.content === t.model.getValue()) { t.mtime = r.mtime; continue; }
    if (t.dirty) {
      showBanner(t, r);
    } else {
      // Keep undo history and the cursor: replace as one edit.
      t.suppress = true;
      t.model.pushEditOperations([], [{ range: t.model.getFullModelRange(), text: r.content }], () => null);
      t.suppress = false;
      t.mtime = r.mtime; t.agentEdit = t !== S.active;
      if (t === S.active) { status(`${basename(t.path)} aggiornato su disco`); if (typeof decorate === "function") decorate(t); }
      if (typeof runChecks === "function") runChecks(t, { deep: false });
      renderTabs();
    }
  }
  if (treeDirty) renderTree();
  const roots = new Set(paths.map(p => rootOf(p)).filter(Boolean));
  roots.forEach(r => refreshGitSoon(r));
  for (const r of roots) {
    const files = S.filesBy.get(r.path);
    if (!files || paths.some(p => rootOf(p) === r && !files.includes(relative(p, r)))) loadFiles(r);
  }
}
function showBanner(t, r) {
  const b = $("#banner"); b.classList.remove("hidden"); b.innerHTML = "";
  b.append(el("span", "", `${basename(t.path)} è cambiato su disco mentre lo stavi modificando.`));
  const reload = el("button", "", "Ricarica dal disco"), keep = el("button", "", "Tieni la mia versione");
  reload.onclick = () => { t.suppress = true; t.model.setValue(r.content); t.suppress = false; t.dirty = false; t.mtime = r.mtime; b.classList.add("hidden"); renderTabs(); };
  keep.onclick = () => { b.classList.add("hidden"); save(t); };
  b.append(reload, keep);
}

// ---------- Diff view ----------
let diffModels = [];
// Shows two texts side by side. `modified` can be a live model (editable: it's the open file).
function openDiff({ title, original, modified, model, path, onClose }) {
  const lang = langOf(path || title || "");
  diffModels.forEach(m => m.dispose()); diffModels = [];
  const orig = monaco.editor.createModel(original || "", lang); diffModels.push(orig);
  let mod = model;
  if (!mod) { mod = monaco.editor.createModel(modified || "", lang); diffModels.push(mod); }
  diffEditor.setModel({ original: orig, modified: mod });
  diffEditor.updateOptions({ readOnly: !model });
  $("#diffEditor").classList.remove("hidden"); $("#editor").classList.add("hidden");
  $("#welcome").classList.add("hidden");
  const bar = $("#diffBar"); bar.innerHTML = ""; bar.classList.remove("hidden");
  const ic = el("span", "ico"); ic.innerHTML = icon("diff");
  bar.append(ic, el("span", "t", title || "Diff"));
  const nav = (d) => { const ch = diffEditor.getLineChanges() || []; if (!ch.length) return;
    const line = diffEditor.getModifiedEditor().getPosition()?.lineNumber || 0;
    const list = ch.map(c => Math.max(1, c.modifiedStartLineNumber));
    const target = d > 0 ? (list.find(l => l > line) || list[0]) : ([...list].reverse().find(l => l < line) || list[list.length - 1]);
    diffEditor.getModifiedEditor().revealLineInCenter(target); diffEditor.getModifiedEditor().setPosition({ lineNumber: target, column: 1 }); };
  const prev = el("button", "tb-ico"); prev.innerHTML = icon("arrowUp"); prev.title = "Modifica precedente"; prev.onclick = () => nav(-1);
  const next = el("button", "tb-ico"); next.innerHTML = icon("arrowDown"); next.title = "Modifica successiva"; next.onclick = () => nav(1);
  const side = el("button", "tb-ico"); side.innerHTML = icon("sidebar"); side.title = "Affiancato / unificato";
  side.onclick = () => { S._inline = !S._inline; diffEditor.updateOptions({ renderSideBySide: !S._inline }); };
  const close = el("button", "btn small", "Chiudi diff"); close.onclick = hideDiff;
  bar.append(el("span", "spacer"), prev, next, side, close);
  S.diffOnClose = onClose;
}
function hideDiff() {
  if ($("#diffEditor").classList.contains("hidden")) return;
  $("#diffEditor").classList.add("hidden"); $("#editor").classList.remove("hidden"); $("#diffBar").classList.add("hidden");
  diffEditor.setModel(null);
  diffModels.forEach(m => m.dispose()); diffModels = [];
  if (S.diffOnClose) { S.diffOnClose(); S.diffOnClose = null; }
  renderCrumbs(); showEditor();
}

// ---------- Search everywhere / go to / recent / actions ----------
let pal = { mode: "all", items: [], index: 0 };
const ACTIONS = [
  ["Cerca nel progetto", "⌘⇧F", () => openSearch()], ["Vai a file", "⌘⇧O", () => showPalette("file")],
  ["File recenti", "⌘E", () => showPalette("recent")], ["Vai alla riga", "⌘L", () => showPalette("line")],
  ["Struttura del file", "⌘F12", () => editor.getAction("editor.action.quickOutline")?.run()],
  ["Nuovo terminale", "⌥F12", () => newShell()], ["Commit", "⌘K", () => commitDialog()], ["Push", "⌘⇧K", () => pushNow()],
  ["Update Project (pull)", "⌘T", () => updateProject()], ["Nuovo branch", "⌥⌘N", () => newBranch()], ["Branch…", "", () => showBranchesPopup()],
  ["Checkout tag o revisione", "", () => checkoutRevision()], ["Fetch", "", () => fetchNow(cur(), false)],
  ["Log di Git", "⌘9", () => showToolWindow("git")], ["Problemi", "⌘6", () => showToolWindow("problems")],
  ["Esegui…", "⌘4", () => showToolWindow("run")], ["Struttura", "⌘7", () => showToolWindow("structure")],
  ["Annota con Git blame", "", () => toggleBlame()], ["Controlla il progetto con tsc", "", () => runTsc()],
  ["Aggiungi cartella al workspace", "", () => addFolder()], ["Aggiungi progetto dalla lista", "", () => showPalette("projects")],
  ["Mostra diff del file", "", () => S.active && showDiff(S.active.path)], ["Riformatta il codice", "⌘⌥L", () => editor.getAction("editor.action.formatDocument")?.run()],
  ["Salva tutto", "⌘S", () => saveAll()], ["Chiudi tutte le tab", "", () => [...S.tabs].forEach(t => closeTab(t))],
  ["Mostra nell'albero", "⌥F1", () => S.active && revealInTree(S.active.path)], ["Riapri tab chiusa", "⌘⇧T", () => reopenTab()],
  ["Espandi tutto l'albero", "", () => expandAll()], ["Comprimi tutto l'albero", "", () => collapseAll()],
  ["Nuovo file o cartella", "⌘⇧N", () => newEntryMenu()],
  ["Chiedi a Elio", "⌘⌥E", () => askElioSelection()],
  ["Aggiorna Elio con le modifiche al suo codice", "", () => { api("askElio", { text: "Aggiornati con le modifiche fatte al tuo codice (self_update)." }); toast("Elio prepara l'aggiornamento"); }], ["Delega a un agente", "", () => delegateSelection()],
  ["Apri in PhpStorm", "", () => S.active && !S.active.virtual && api("openExternal", { path: S.active.path, app: "PhpStorm" })],
  ["Mostra nel Finder", "", () => api("reveal", { path: S.active && !S.active.virtual ? S.active.path : cur() && cur().path })],
  ["Mostra/nascondi pannello in basso", "⌘J", () => toggleArea("bottom")], ["Mostra/nascondi Progetto", "⌘1", () => toggleToolWindow("project")],
  ["Maiuscole / minuscole", "⌘⇧U", () => toggleCase()], ["Duplica riga", "⌘D", () => editor.trigger("k", "editor.action.copyLinesDownAction")],
  ["Cancella riga", "⌘⌫", () => editor.trigger("k", "editor.action.deleteLines")], ["Commenta", "⌘/", () => editor.trigger("k", "editor.action.commentLine")],
  ["Copia percorso del file", "", () => S.active && copy(S.active.path)], ["Copia percorso relativo", "", () => S.active && copy(relative(S.active.path))],
  ["Zoom testo +", "⌘=", () => zoom(1)], ["Zoom testo −", "⌘-", () => zoom(-1)], ["Mappa del codice (minimap)", "", () => editor.updateOptions({ minimap: { enabled: !editor.getOption(monaco.editor.EditorOption.minimap).enabled } })],
  ["A capo automatico", "⌥Z", () => editor.updateOptions({ wordWrap: editor.getOption(monaco.editor.EditorOption.wordWrap) === "on" ? "off" : "on" })],
];
function showPalette(mode, initial = "") {
  pal = { mode, items: [], index: 0 };
  const titles = { all: "Cerca ovunque", file: "Vai a file", recent: "File recenti", action: "Azioni", line: "Vai alla riga",
    projects: "Progetti (aggiungi al workspace)", branches: "Branch", revision: "Checkout tag o revisione", pick: "" };
  $("#palTitle").textContent = titles[mode];
  $("#palHint").textContent = mode === "all" ? "file · azioni · ⇧⇧" : mode === "line" ? "riga[:colonna]" : "↑↓ invio";
  $("#palInput").value = initial;
  $("#palInput").placeholder = mode === "line" ? "Es. 120 o 120:8" : mode === "revision" ? "Tag, branch o hash (es. v2.4.6, a1b2c3d, HEAD~3)" : "Scrivi per cercare…";
  $("#palette").classList.remove("hidden");
  $("#palInput").focus();
  updatePalette();
  if (mode === "branches" && typeof loadBranchesForPalette === "function") loadBranchesForPalette();
  if (mode === "revision" && typeof loadTagsForPalette === "function") loadTagsForPalette();
}
function hidePalette() { $("#palette").classList.add("hidden"); if (editor && S.active) editor.focus(); }
function fuzzy(q, s) {
  if (!q) return 1;
  q = q.toLowerCase(); const t = s.toLowerCase();
  const base = t.slice(t.lastIndexOf("/") + 1);
  if (base.startsWith(q)) return 1000 - base.length;
  if (base.includes(q)) return 800 - base.length;
  let score = 0, ti = 0, prev = -2, inBase = t.lastIndexOf("/") + 1;
  for (const c of q) {
    const i = t.indexOf(c, ti);
    if (i < 0) return 0;
    score += (i === prev + 1 ? 6 : 1) + (i >= inBase ? 3 : 0) + ("/-_.".includes(t[i - 1]) || /[A-Z]/.test(s[i]) ? 4 : 0);
    prev = i; ti = i + 1;
  }
  return score - t.length * 0.02;
}
function highlight(q, s) {
  const frag = document.createDocumentFragment();
  if (!q) { frag.append(s); return frag; }
  const ql = q.toLowerCase(); let qi = 0;
  for (const ch of s) {
    if (qi < ql.length && ch.toLowerCase() === ql[qi]) { frag.append(el("b", "", ch)); qi++; } else frag.append(ch);
  }
  return frag;
}
function updatePalette() {
  const q = $("#palInput").value.trim();
  const items = [];
  const many = S.roots.length > 1;
  const fileItem = (abs) => { const r = rootOf(abs); const rel = relative(abs, r);
    return { kind: "file", label: basename(rel), sub: (many && r ? r.name + " › " : "") + dirname(rel), run: () => openFile(abs), q }; };
  if (pal.mode === "line") {
    items.push({ label: q ? `Vai alla riga ${q}` : "Scrivi un numero di riga", run: () => {
      const [l, c] = q.split(":").map(Number); if (l) { editor.setPosition({ lineNumber: l, column: c || 1 }); editor.revealLineInCenter(l); }
    } });
  } else if (pal.mode === "projects") {
    const extra = S.roots.filter(r => !S.projects.some(p => p.path === r.path));
    for (const p of [...S.projects, ...extra].map(p => ({ p, s: fuzzy(q, p.name) })).filter(x => x.s > 0).sort((a, b) => b.s - a.s).slice(0, 80)) {
      const inWs = S.roots.some(r => r.path === p.p.path);
      items.push({ kind: "proj", label: p.p.name, sub: (inWs ? "nel workspace · " : "") + tilde(p.p.path), run: () => { addRoot(p.p).then(r => revealInTree(r.path)); }, q });
    }
    items.push({ kind: "action", label: "Scegli una cartella dal disco…", run: () => addFolder(), q: "" });
  } else if (pal.mode === "pick") {
    for (const it of (pal.pick || []).filter(x => fuzzy(q, x.label) > 0).slice(0, 200)) items.push({ ...it, kind: it.kind || "pick", q });
  } else if (pal.mode === "branches" || pal.mode === "revision") {
    if (typeof branchPaletteItems === "function") items.push(...branchPaletteItems(q, pal.mode));
  } else if (pal.mode === "recent") {
    for (const p of S.recent.filter(p => rootOf(p) && fuzzy(q, relative(p)) > 0).slice(0, 40)) items.push(fileItem(p));
  } else {
    if (pal.mode === "all" || pal.mode === "action") {
      const acts = ACTIONS.map(a => ({ a, s: fuzzy(q, a[0]) })).filter(x => q ? x.s > 0 : pal.mode === "action").sort((a, b) => b.s - a.s)
        .slice(0, pal.mode === "action" ? 60 : 5);
      if (acts.length && pal.mode === "all") items.push({ sect: "Azioni" });
      acts.forEach(x => items.push({ kind: "action", label: x.a[0], kb: x.a[1], run: x.a[2], q }));
    }
    if (pal.mode === "all" || pal.mode === "file") {
      let ranked;
      if (!q) ranked = S.recent.filter(p => rootOf(p)).slice(0, 20).map(f => ({ f, s: 1 }));
      else {
        ranked = [];
        for (const r of S.roots) for (const f of S.filesBy.get(r.path) || []) { const s = fuzzy(q, f); if (s > 0) ranked.push({ f: r.path + "/" + f, s }); }
        ranked.sort((a, b) => b.s - a.s); ranked = ranked.slice(0, 50);
      }
      if (ranked.length && pal.mode === "all") items.push({ sect: q ? "File" : "Recenti" });
      ranked.forEach(x => items.push(fileItem(x.f)));
      if (S.roots.some(r => !S.filesBy.has(r.path))) items.push({ sect: "Indicizzo i file…" });
    }
  }
  pal.items = items;
  pal.index = items.findIndex(i => !i.sect);
  renderPalette();
}
function renderPalette() {
  const list = $("#palList"); list.innerHTML = "";
  pal.items.forEach((it, i) => {
    if (it.sect) { list.append(el("div", "pi-sect", it.sect)); return; }
    const row = el("div", "pi" + (i === pal.index ? " on" : ""));
    const ic = el("span", "ic");
    ic.innerHTML = it.kind === "file" ? fileIcon(it.label, false) : icon(it.icon || (it.kind === "action" ? "chevronRight" : it.kind === "proj" ? "project" : it.kind === "tag" ? "tag" : it.kind === "commit" ? "commit" : "branch"));
    const t = el("span", "t"); t.append(highlight(it.q, it.label));
    row.append(ic, t);
    if (it.sub) row.append(el("span", "sub", it.sub));
    if (it.kb) row.append(el("kbd", "kb", it.kb));
    row.onmousemove = () => { if (pal.index !== i) { pal.index = i; renderPalette(); } };
    row.onclick = () => { hidePalette(); it.run(); };
    list.append(row);
  });
  const on_ = list.querySelector(".pi.on"); if (on_) on_.scrollIntoView({ block: "nearest" });
}
$("#palInput").addEventListener("input", updatePalette);
$("#palInput").addEventListener("keydown", e => {
  const move = d => { let i = pal.index; do { i += d; } while (pal.items[i] && pal.items[i].sect); if (pal.items[i]) { pal.index = i; renderPalette(); } };
  if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
  else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
  else if (e.key === "Enter") { e.preventDefault(); const it = pal.items[pal.index]; hidePalette(); if (it && it.run) it.run(); }
  else if (e.key === "Escape") { e.preventDefault(); hidePalette(); }
});
$("#palette").addEventListener("mousedown", e => { if (e.target.id === "palette") hidePalette(); });

// ---------- Find in path (tool window) ----------
const find = { pane: null };
function mountFind(box) {
  const bar = el("div", "search-bar");
  const input = el("input"); input.placeholder = "Cerca nel progetto…  (Invio)";
  const where = el("select", "sel-root");
  const scopeIn = el("input"); scopeIn.placeholder = "cartella (opzionale)"; scopeIn.style.maxWidth = "200px";
  const rx = el("button", "opt", ".*"), cs = el("button", "opt", "Aa"), count = el("span", "count", "");
  rx.title = "Espressione regolare"; cs.title = "Maiuscole/minuscole";
  rx.onclick = () => { rx.classList.toggle("on"); run(); }; cs.onclick = () => { cs.classList.toggle("on"); run(); };
  bar.append(input, where, scopeIn, rx, cs, count);
  const results = el("div", "results");
  box.append(bar, results);
  Object.assign(find, { input, where, scopeIn, run, fillRoots });
  function fillRoots() {
    const keep = where.value;
    where.innerHTML = "";
    for (const r of S.roots) where.append(Object.assign(el("option", "", r.name), { value: r.path }));
    if (S.roots.length > 1) where.append(Object.assign(el("option", "", "Tutto il workspace"), { value: "*" }));
    where.value = [...where.options].some(o => o.value === keep) ? keep : (cur() ? cur().path : "");
  }
  let seq = 0;
  async function run() {
    const q = input.value; if (!q || !S.roots.length) return;
    const my = ++seq; count.textContent = "cerco…";
    const roots = where.value === "*" ? S.roots : S.roots.filter(r => r.path === where.value);
    const scope = scopeIn.value.trim().replace(/^\/+|\/+$/g, "");
    const all = [];
    for (const r of roots) {
      const base = scope && !scope.startsWith("/") ? r.path + "/" + scope : r.path;
      let res = [];
      try { res = await api("search", { root: base, query: q, regex: rx.classList.contains("on"), case: cs.classList.contains("on") }); } catch {}
      res.forEach(m => all.push({ ...m, abs: base + "/" + m.file, root: r }));
    }
    if (my !== seq) return;
    results.innerHTML = "";
    count.textContent = `${all.length}${all.length >= 800 ? "+" : ""} risultati`;
    let last = null;
    for (const m of all) {
      if (m.abs !== last) {
        last = m.abs;
        const head = el("div", "res-file");
        const ic = el("span", "ic"); ic.innerHTML = fileIcon(basename(m.abs), false);
        const rel = relative(m.abs, m.root);
        head.append(ic, el("span", "", basename(rel)), el("span", "dir", (roots.length > 1 ? m.root.name + " › " : "") + dirname(rel)));
        results.append(head);
      }
      const line = el("div", "res-line"); line.append(el("span", "n", m.line));
      const text = el("span", ""); const t = m.text.trimStart();
      const idx = rx.classList.contains("on") ? -1 : (cs.classList.contains("on") ? t.indexOf(q) : t.toLowerCase().indexOf(q.toLowerCase()));
      if (idx >= 0) { text.append(t.slice(0, idx), el("mark", "", t.slice(idx, idx + q.length)), t.slice(idx + q.length)); } else text.textContent = t;
      line.append(text);
      line.onclick = () => openFile(m.abs, { line: m.line, col: m.col, highlight: true });
      results.append(line);
    }
    if (!all.length) results.append(el("div", "empty", "Nessun risultato."));
  }
  input.onkeydown = e => { if (e.key === "Enter") run(); if (e.key === "Escape") editor.focus(); };
  scopeIn.onkeydown = e => { if (e.key === "Enter") run(); };
  fillRoots();
}
function openSearch(initial, dir) {
  showToolWindow("find");
  find.fillRoots();
  if (dir) {
    const r = rootOf(dir);
    if (r) { find.where.value = r.path; find.scopeIn.value = relative(dir, r); }
  } else if (cur() && find.where.value !== "*") find.where.value = cur().path;
  if (initial != null && initial !== "") find.input.value = initial;
  setTimeout(() => { find.input.focus(); find.input.select(); if (initial) find.run(); }, 30);
}

// ---------- Terminals (tool window, with tabs) ----------
const TERM_THEME = { background: "#1E1F22", foreground: "#BCBEC4", cursor: "#CED0D6", selectionBackground: "#214283",
  black: "#1E1F22", red: "#E06C75", green: "#6AAB73", yellow: "#E5C07B", blue: "#6C9BD2", magenta: "#C77DBB", cyan: "#2AACB8", white: "#BCBEC4",
  brightBlack: "#6F737A", brightRed: "#F28B82", brightGreen: "#89CA78", brightYellow: "#FFD360", brightBlue: "#8AB4F8", brightMagenta: "#D7A9E3",
  brightCyan: "#56D4DD", brightWhite: "#FFFFFF" };
function makeTerm(readOnly) {
  // Nerd Font variants first: prompts like powerlevel10k / starship use their icons.
  const term = new Terminal({ fontFamily: "MesloLGS NF, MesloLGS Nerd Font, JetBrainsMono Nerd Font, Hack Nerd Font, FiraCode Nerd Font, JetBrains Mono, SF Mono, Menlo, monospace", fontSize: 12.5, lineHeight: 1.15, theme: TERM_THEME,
    cursorBlink: !readOnly, scrollback: 10000, allowProposedApi: true, macOptionIsMeta: true, disableStdin: readOnly, convertEol: readOnly });
  const fit = new FitAddon.FitAddon(); term.loadAddon(fit);
  // Links in terminal output come from servers and programs: Swift opens only http(s)/mailto, in the browser.
  try { term.loadAddon(new WebLinksAddon.WebLinksAddon((e, uri) => openLink(uri))); } catch {}
  return { term, fit };
}
const ptyPanels = new Map();
on("ptyData", d => {
  const p = ptyPanels.get(d.id); if (!p) return;
  const bin = atob(d.data); const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  p.term.write(bytes);
});
on("ptyExit", d => {
  const p = ptyPanels.get(d.id); if (!p) return;
  ptyPanels.delete(d.id);
  p.dead = true; p.exitCode = d.code;
  if (p.onExit) { p.onExit(d.code); return; }
  p.term.write(`\r\n\x1b[90m[processo terminato (${d.code}) — premi un tasto per riaprire]\x1b[0m\r\n`);
});
// A PTY-backed xterm in `box` (terminal tabs, run sessions). `spec`: { cwd, command (shell line), argv (exact args) }.
async function attachPty(p, box, spec) {
  const { term, fit } = makeTerm(false);
  p.term = term; p.fit = fit;
  term.open(box);
  await new Promise(r => setTimeout(r, 30));
  try { fit.fit(); } catch {}
  p.start = async () => {
    const r = await api("ptyCreate", { cwd: spec.cwd, cols: term.cols, rows: term.rows, command: spec.command, argv: spec.argv });
    p.pty = r.id; p.dead = false; ptyPanels.set(r.id, p);
  };
  term.onData(data => {
    if (p.dead) { if (!p.onExit) { term.clear(); p.start(); } return; }
    const bytes = new TextEncoder().encode(data); let bin = ""; bytes.forEach(b => bin += String.fromCharCode(b));
    api("ptyWrite", { id: p.pty, data: btoa(bin) });
  });
  term.onResize(({ cols, rows }) => p.pty && !p.dead && api("ptyResize", { id: p.pty, cols, rows }));
  term.attachCustomKeyEventHandler(e => {
    // ⌘K clears like Terminal.
    if (e.type === "keydown" && e.metaKey && e.key === "k") { term.clear(); return false; }
    return true;
  });
  try { await p.start(); } catch (e) { term.write(`\x1b[31m${e.message || e}\x1b[0m\r\n`); p.dead = true; }
  return p;
}
let shellCount = 0, termBody = null;
async function newShell(cwd, command, opts = {}) {
  const dir = cwd || (cur() && cur().path) || "";
  const tw = TW.get("terminal"); ensureMounted(tw);
  const pane = el("div", "pane"); const box = el("div", "term"); pane.append(box);
  const label = opts.title || (command ? String(command).split(" ")[0] : opts.argv ? opts.argv[0] : `Locale${shellCount ? " " + (shellCount + 1) : ""}`);
  shellCount++;
  const p = { id: "sh" + shellCount, kind: "shell", title: label, el: pane, cwd: dir };
  addPanel(p); showPanel(p);
  await attachPty(p, box, { cwd: dir, command: command || undefined, argv: opts.argv });
  p.term.focus();
  return p;
}
function addPanel(p) {
  ensureMounted(TW.get("terminal"));
  S.panels.push(p);
  termBody.append(p.el);
  renderPanelTabs();
}
function showPanel(p) {
  S.panel = p;
  if (!isOpen("terminal")) showToolWindow("terminal", { focus: false, noAutoShell: true });
  S.panels.forEach(x => x.el.classList.toggle("on", x === p));
  renderPanelTabs();
  if (p.fit) setTimeout(() => { try { p.fit.fit(); } catch {} p.term && p.kind === "shell" && p.term.focus(); }, 20);
  if (p.kind === "agent") setTimeout(() => p.input && p.input.focus(), 20);
}
function closePanel(p) {
  if (p.pty && !p.dead) api("ptyKill", { id: p.pty });
  if (p.term) p.term.dispose();
  p.el.remove();
  S.panels = S.panels.filter(x => x !== p);
  if (S.panel === p) { const next = S.panels[S.panels.length - 1]; if (next) showPanel(next); else S.panel = null; }
  renderPanelTabs();
  if (!S.panels.length && isOpen("terminal")) hideToolWindow("terminal");
}
function renderPanelTabs() {
  const tw = TW.get("terminal"); if (!tw || !tw.headEl) return;
  const bar = tw.headEl; bar.innerHTML = "";
  for (const p of S.panels) {
    const t = el("div", "ptab" + (p === S.panel ? " on" : ""));
    if (p.kind === "agent") { const a = S.agents.find(a => a.id === p.agentId); t.append(el("span", "st " + (a ? a.status : ""))); }
    t.append(el("span", "", p.title));
    const x = el("span", "x"); x.innerHTML = icon("close"); x.onclick = e => { e.stopPropagation(); closePanel(p); };
    t.append(x);
    t.onclick = () => showPanel(p);
    t.onauxclick = e => { if (e.button === 1) closePanel(p); };
    bar.append(t);
  }
  const add = el("div", "ptab add"); add.innerHTML = icon("plus"); add.onclick = () => newShell(); add.title = "Nuovo terminale (⌥F12)";
  bar.append(add);
}
function focusTerminal() {
  const p = S.panels.find(x => x.kind === "shell" && x === S.panel) || S.panels.find(x => x.kind === "shell");
  if (!p) { newShell(); return; }
  if (isOpen("terminal") && S.panel === p && inTerminal()) { hideToolWindow("terminal"); return; }
  showPanel(p); p.term.focus();
}

// Agents: each one has its terminal (what it does, live) and you can write to it.
on("agents", list => { S.agents = list || []; renderAgents(); });
on("agentLog", d => { const p = S.panels.find(x => x.kind === "agent" && x.agentId === d.id); if (p) d.entries.forEach(e => writeLog(p, e)); });
on("openAgent", d => openAgent(d.agent));
on("open", async d => {
  if (!d.path) return;
  if (!rootOf(d.path)) {
    const proj = S.projects.find(p => d.path === p.path || d.path.startsWith(p.path + "/"));
    await addRoot(proj || { name: basename(d.path), path: d.path });
  }
  const r = rootOf(d.path);
  if (r && d.path === r.path) { revealInTree(r.path); return; }
  try { const l = await api("list", { path: d.path }); if (Array.isArray(l)) { revealInTree(d.path); return; } } catch {}
  openFile(d.path, { line: d.line || 0, highlight: !!d.line });
});
async function refreshAgents() { try { S.agents = await api("agents"); } catch { S.agents = []; } renderAgents(); }
function renderAgents() {
  const running = S.agents.filter(a => ["running", "waitingConfirmation", "paused"].includes(a.status));
  $("#agentsCount").textContent = running.length ? `${running.length} al lavoro` : `${S.agents.length} agenti`;
  $("#stAgents").textContent = running.length ? `${running.length} agenti al lavoro` : "";
  const box = $("#agentsList");
  if (box) {
    box.innerHTML = "";
    if (!S.agents.length) { box.append(el("div", "empty", "Nessun agente. Chiedi a Elio di avviarne uno.")); }
    for (const a of S.agents) {
      const row = el("div", "agent");
      const top = el("div", "top"); top.append(el("span", "st " + a.status), el("span", "nm", a.member || a.title));
      row.append(top, el("div", "now", a.now || a.status));
      row.append(el("div", "meta", `${a.project || ""}${a.progress ? ` · passo ${Math.min(a.progress[0] + 1, a.progress[1])}/${a.progress[1]}` : ""}${a.model && !a.model.includes("opus") ? " · " + a.model : ""}`));
      row.onclick = () => openAgent(a.id);
      box.append(row);
    }
  }
  S.panels.filter(p => p.kind === "agent").forEach(updateAgentHead);
  renderPanelTabs(); renderStrip();
}
async function openAgent(id) {
  let p = S.panels.find(x => x.kind === "agent" && x.agentId === id);
  if (!p) {
    const a = S.agents.find(a => a.id === id) || { id, title: "agente", status: "" };
    const pane = el("div", "pane");
    const head = el("div", "agent-head");
    const box = el("div", "term");
    const input = el("input"); input.placeholder = "Scrivi all'agente… (Invio: lo interrompe e riparte con il tuo messaggio)";
    const send = el("button", "", "Invia");
    const bar = el("div", "agent-input"); bar.append(input, send);
    pane.append(head, box, bar);
    const { term, fit } = makeTerm(true);
    p = { id: "ag" + id, kind: "agent", agentId: id, title: a.member || a.title, el: pane, term, fit, head, input };
    addPanel(p); showPanel(p);
    term.open(box);
    setTimeout(() => { try { fit.fit(); } catch {} }, 30);
    const submit = async () => {
      const text = input.value.trim(); if (!text) return;
      input.value = "";
      term.write(`\r\n\x1b[33m❯ tu:\x1b[0m ${text}\r\n`);
      const r = await api("agentSend", { id, text });
      term.write(`\x1b[90m${r}\x1b[0m\r\n`);
    };
    input.onkeydown = e => { if (e.key === "Enter") submit(); };
    send.onclick = submit;
    try { (await api("agentLog", { id })).forEach(e => writeLog(p, e)); } catch {}
  }
  updateAgentHead(p);
  showPanel(p);
}
function updateAgentHead(p) {
  const a = S.agents.find(a => a.id === p.agentId); if (!a) return;
  const h = p.head; h.innerHTML = "";
  const dot = el("span", "dot " + a.status);
  h.append(dot, el("b", "", a.member || a.title), el("span", "now", a.now || ""));
  if (a.progress) { const bar = el("span", "bar"); const i = el("i"); i.style.width = (100 * a.progress[0] / a.progress[1]) + "%"; bar.append(i); h.append(bar); }
  const btn = (ic, title, f) => { const b = el("button", "tb-ico"); b.innerHTML = icon(ic); b.title = title; b.onclick = f; h.append(b); };
  if (a.cwd) {
    btn("folder", "Aggiungi la sua cartella al workspace", () => addRoot({ name: basename(a.cwd), path: a.cwd }).then(r => revealInTree(r.path)));
    btn("terminal", "Terminale nella sua cartella", () => newShell(a.cwd));
  }
  if (["running", "waitingConfirmation"].includes(a.status)) btn("stop", "Pausa", () => api("agentControl", { id: a.id, action: "pause" }));
  if (a.status === "paused") btn("run", "Riprendi", () => api("agentControl", { id: a.id, action: "resume" }));
  if (["running", "waitingConfirmation", "paused"].includes(a.status)) btn("close", "Ferma", () => api("agentControl", { id: a.id, action: "stop" }));
}
function writeLog(p, e) {
  const t = p.term, short = s => (s || "").replace(/\r?\n/g, "\r\n");
  switch (e.kind) {
    case "command": t.write(`\r\n\x1b[38;5;221m$\x1b[0m \x1b[1m${short(e.title)}\x1b[0m${e.body ? `  \x1b[90m# ${e.body}\x1b[0m` : ""}\r\n`); break;
    case "output": t.write(`\x1b[90m${short(e.body)}\x1b[0m\r\n`); break;
    case "edit": t.write(`\x1b[34m✎ ${e.title}\x1b[0m\r\n`); diffLines(t, e); break;
    case "write": t.write(`\x1b[32m＋ ${e.title}\x1b[0m\r\n`); break;
    case "read": t.write(`\x1b[90m· legge ${e.title}\x1b[0m\r\n`); break;
    case "search": t.write(`\x1b[90m⌕ cerca ${e.title}\x1b[0m\r\n`); break;
    case "ask": t.write(`\r\n\x1b[33m? ${short(e.title)}\x1b[0m\r\n`); break;
    case "say": t.write(`\r\n\x1b[37m${short(e.title)}\x1b[0m\r\n`); break;
    default: t.write(`\x1b[90m${short(e.title)}\x1b[0m\r\n`);
  }
}
function diffLines(t, e) {
  const rm = (e.removed || "").split("\n").slice(0, 6), add = (e.added || "").split("\n").slice(0, 6);
  rm.forEach(l => l && t.write(`\x1b[31m  - ${l}\x1b[0m\r\n`)); add.forEach(l => l && t.write(`\x1b[32m  + ${l}\x1b[0m\r\n`));
}

// ---------- Elio ----------
function selectionInfo() {
  if (!S.active) return null;
  const sel = editor.getSelection();
  const text = editor.getModel().getValueInRange(sel);
  return { path: S.active.virtual ? S.active.title : S.active.path, from: sel.startLineNumber, to: sel.endLineNumber, text };
}
async function askElio(prefix = "") {
  const q = await prompt_("Chiedi a Elio", prefix, "Cosa vuoi sapere o fare?");
  if (q) { api("askElio", { text: q }); toast("Chiesto a Elio"); }
}
async function askElioSelection() {
  const s = selectionInfo();
  if (!s) return askElio();
  const q = await prompt_("Chiedi a Elio", "", s.text ? `Su ${basename(s.path)} righe ${s.from}-${s.to}…` : `Su ${basename(s.path)}…`);
  if (!q) return;
  const ctx = s.text ? `\nNel file ${s.path} (righe ${s.from}-${s.to}):\n\`\`\`\n${s.text.slice(0, 6000)}\n\`\`\`` : `\nFile aperto: ${s.path}, riga ${s.from}.`;
  api("askElio", { text: q + ctx }); toast("Chiesto a Elio");
}
async function delegateSelection() {
  const s = selectionInfo();
  const q = await prompt_("Delega a un agente", "", "Cosa deve fare l'agente?");
  const r = cur();
  if (!q || !r) return;
  const ctx = s ? `\nParti da ${s.path}${s.text ? ` (righe ${s.from}-${s.to})` : ""}.` : "";
  api("askElio", { text: `Avvia un agente sul progetto ${r.path} per: ${q}${ctx}` });
  toast("Elio avvia l'agente");
}
on("elioState", setElioState);
function setElioState(s) {
  S.elio = s || S.elio;
  const st = $("#stElio"); if (!st) return;
  const labels = { idle: "pronto", listening: "ascolta", hearing: "sente", thinking: "pensa", speaking: "parla", muted: "muto", off: "spento" };
  st.innerHTML = `<span class="edot ${S.elio.connected ? S.elio.state : "off"}"></span>`;
  st.append(`Elio ${S.elio.connected ? labels[S.elio.state] || S.elio.state : "non collegato"}`);
}

// ---------- Keyboard (PhpStorm-like) ----------
function setupKeys() {
  // Editor-only commands. IDE-wide shortcuts are handled once, in the document's capture listener below.
  const K = monaco.KeyMod, C = monaco.KeyCode;
  const cmd = (keys, f) => editor.addCommand(keys, f);
  cmd(K.CtrlCmd | C.KeyD, () => editor.trigger("k", "editor.action.copyLinesDownAction"));
  cmd(K.CtrlCmd | C.Backspace, () => editor.trigger("k", "editor.action.deleteLines"));
  cmd(K.WinCtrl | C.KeyG, () => editor.trigger("k", "editor.action.addSelectionToNextFindMatch"));
  cmd(K.WinCtrl | K.Shift | C.KeyG, () => editor.trigger("k", "editor.action.selectHighlights"));
  cmd(K.Alt | C.UpArrow, () => editor.trigger("k", "editor.action.smartSelect.expand"));
  cmd(K.Alt | C.DownArrow, () => editor.trigger("k", "editor.action.smartSelect.shrink"));
  cmd(K.Alt | K.Shift | C.UpArrow, () => editor.trigger("k", "editor.action.moveLinesUpAction"));
  cmd(K.Alt | K.Shift | C.DownArrow, () => editor.trigger("k", "editor.action.moveLinesDownAction"));
  cmd(K.CtrlCmd | K.Shift | C.UpArrow, () => editor.trigger("k", "editor.action.moveLinesUpAction"));
  cmd(K.CtrlCmd | K.Shift | C.DownArrow, () => editor.trigger("k", "editor.action.moveLinesDownAction"));
  cmd(K.CtrlCmd | K.Alt | C.KeyL, () => editor.trigger("k", "editor.action.formatDocument"));
  cmd(K.CtrlCmd | C.KeyR, () => editor.trigger("k", "editor.action.startFindReplaceAction"));
  cmd(K.CtrlCmd | C.KeyB, () => editor.trigger("k", "editor.action.revealDefinition"));
  cmd(K.CtrlCmd | C.F12, () => editor.trigger("k", "editor.action.quickOutline"));
  cmd(K.CtrlCmd | K.Shift | C.KeyU, toggleCase);
  cmd(K.CtrlCmd | K.Shift | C.Slash, () => editor.trigger("k", "editor.action.blockComment"));
  cmd(K.CtrlCmd | C.KeyL, () => showPalette("line"));
  cmd(K.CtrlCmd | C.BracketLeft, () => navGo(-1));
  cmd(K.CtrlCmd | C.BracketRight, () => navGo(1));
  cmd(K.CtrlCmd | K.Shift | C.BracketLeft, () => cycleTab(-1));
  cmd(K.CtrlCmd | K.Shift | C.BracketRight, () => cycleTab(1));
  editor.addAction({ id: "elio.ask", label: "Chiedi a Elio", contextMenuGroupId: "0_elio", contextMenuOrder: 1, run: askElioSelection });
  editor.addAction({ id: "elio.delegate", label: "Delega a un agente", contextMenuGroupId: "0_elio", contextMenuOrder: 2, run: delegateSelection });
  editor.addAction({ id: "elio.diff", label: "Mostra le modifiche (diff)", contextMenuGroupId: "0_elio", contextMenuOrder: 3, run: () => S.active && !S.active.virtual && showDiff(S.active.path) });
  editor.addAction({ id: "elio.reveal", label: "Mostra nell'albero", contextMenuGroupId: "0_elio", contextMenuOrder: 4, run: () => S.active && !S.active.virtual && revealInTree(S.active.path) });
  editor.addAction({ id: "elio.blame", label: "Annota con Git blame (on/off)", contextMenuGroupId: "1_git", contextMenuOrder: 1, run: () => toggleBlame() });
  editor.addAction({ id: "elio.history", label: "Git: storia del file", contextMenuGroupId: "1_git", contextMenuOrder: 2, run: () => S.active && !S.active.virtual && showFileHistory(S.active.path) });
  editor.addAction({ id: "elio.rollbackLines", label: "Git: confronta con un branch…", contextMenuGroupId: "1_git", contextMenuOrder: 3, run: () => S.active && !S.active.virtual && compareWithBranch(S.active.path) });
}
let lastShift = 0;
const isInput = () => { const a = document.activeElement; return a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA" || a.tagName === "SELECT") && !a.closest(".monaco-editor") && !a.closest(".term"); };
function inTerminal() { return document.activeElement && document.activeElement.closest && document.activeElement.closest(".term"); }
document.addEventListener("keydown", e => {
  if (e.key === "Shift" && !e.repeat) {
    const now = Date.now();
    if (now - lastShift < 350) { lastShift = 0; e.preventDefault(); showPalette("all"); return; }
    lastShift = now; return;
  }
  lastShift = 0;
  if (document.querySelector(".ctxm") && e.key === "Escape") { e.preventDefault(); e.stopPropagation(); closeMenus(); return; }
  if (document.querySelector(".popup") && e.key === "Escape") { e.preventDefault(); e.stopPropagation(); closePopup(); return; }
  if (!$("#palette").classList.contains("hidden") || !$("#dialog").classList.contains("hidden")) {
    if (e.key === "Escape") { hidePalette(); closeDialog(); }
    return;
  }
  const inEditor = editor && editor.hasTextFocus();
  const m = e.metaKey, sh = e.shiftKey, alt = e.altKey, c = e.code, k = e.key.toLowerCase();
  const combos = [
    [m && sh && c === "KeyO", () => showPalette("file")], [m && !sh && !alt && c === "KeyE", () => showPalette("recent")],
    [m && sh && c === "KeyA", () => showPalette("action")],
    [m && sh && c === "KeyF", () => openSearch(inEditor && editor.getModel() ? editor.getModel().getValueInRange(editor.getSelection()) : "")],
    [m && !sh && !alt && c === "KeyK" && !inTerminal(), () => commitDialog()], [m && sh && c === "KeyK", () => pushNow()],
    [m && !sh && !alt && c === "KeyT", () => updateProject()], [m && alt && c === "KeyN", () => newBranch()],
    [m && sh && !alt && c === "KeyN", () => newEntryMenu()],
    [m && !alt && c === "Digit1", () => toggleToolWindow("project")], [m && !alt && c === "Digit0", () => toggleToolWindow("commit")],
    [m && !alt && c === "Digit9", () => toggleToolWindow("git")], [m && !alt && c === "Digit6", () => toggleToolWindow("problems")],
    [m && !alt && c === "Digit7", () => toggleToolWindow("structure")], [m && !alt && c === "Digit4", () => toggleToolWindow("run")],
    [alt && !m && c === "F12", focusTerminal], [alt && !m && c === "F1", () => S.active && !S.active.virtual && revealInTree(S.active.path)],
    [m && !sh && c === "KeyS", saveAll], [m && !sh && !alt && c === "KeyW", () => S.active ? closeTab(S.active) : api("closeWindow")],
    [m && sh && c === "KeyT", reopenTab], [m && !sh && c === "KeyJ", () => toggleArea("bottom")],
    [m && alt && c === "KeyE", askElioSelection],
    [m && !sh && !alt && c === "KeyN" && !inEditor && !isInput() && !inTerminal(), () => { const d = selectedDir(); d ? createEntry(d, false) : addFolder(); }],
    [m && (k === "=" || k === "+"), () => zoom(1)], [m && k === "-" && !alt, () => zoom(-1)],
    [sh && !m && e.key === "Escape", () => { const k = activeSlot(); if (k) hideSlot(k); }],
    [!sh && !m && e.key === "Escape" && !inEditor && !isInput() && !inTerminal() && S.active, () => editor.focus()],
  ];
  for (const [cond, f] of combos) if (cond) { e.preventDefault(); e.stopPropagation(); f(); return; }
}, true);
// The slot ⇧Esc hides: the one with focus, else the last one used, else any open one.
function activeSlot() {
  const a = document.activeElement;
  for (const k of PK) if (area[k] && a && a.closest && a.closest(SLOTS[k].box)) return k;
  if (activePk && area[activePk]) return activePk;
  return ["bottom/primary", "bottom/secondary", "right/primary", "right/secondary", "left/primary", "left/secondary"].find(k => area[k]) || null;
}
function cycleTab(d) {
  if (!S.tabs.length) return;
  const i = S.tabs.indexOf(S.active);
  activate(S.tabs[(i + d + S.tabs.length) % S.tabs.length]); renderTabs();
}
function reopenTab() { const p = S.closed.pop(); if (p) openFile(p); }
function toggleCase() {
  const sel = editor.getSelection(); const m = editor.getModel(); if (!m || sel.isEmpty()) return;
  const t = m.getValueInRange(sel);
  editor.executeEdits("case", [{ range: sel, text: t === t.toUpperCase() ? t.toLowerCase() : t.toUpperCase() }]);
}
function zoom(d) { const s = editor.getOption(monaco.editor.EditorOption.fontSize) + d; editor.updateOptions({ fontSize: Math.max(9, Math.min(24, s)) }); }
function rememberNav() {
  if (!S.active || S._navigating || S.active.virtual) return;
  const pos = editor.getPosition(); const last = S.nav[S.navIndex];
  if (last && last.path === S.active.path && Math.abs(last.line - pos.lineNumber) < 10) { last.line = pos.lineNumber; last.col = pos.column; return; }
  S.nav = S.nav.slice(0, S.navIndex + 1); S.nav.push({ path: S.active.path, line: pos.lineNumber, col: pos.column });
  if (S.nav.length > 100) S.nav.shift();
  S.navIndex = S.nav.length - 1;
}
async function navGo(d) {
  const target = S.nav[S.navIndex + d]; if (!target) return;
  S.navIndex += d; S._navigating = true;
  await openFile(target.path, { line: target.line, col: target.col });
  S._navigating = false;
}
function flashLine(line) {
  const ids = editor.deltaDecorations([], [{ range: new monaco.Range(line, 1, line, 1), options: { isWholeLine: true, className: "agent-edit-line" } }]);
  setTimeout(() => editor.deltaDecorations(ids, []), 1800);
}

// ---------- Tool windows (JetBrains-style docks: left, right, bottom) ----------
// Each dock has two slots, primary and secondary (side docks: top / bottom; bottom dock: left / right). A slot shows one
// window at a time; when both slots have one the dock is split in two (draggable), otherwise the open one fills it.
// The registration's `side` (and `slot: "secondary"`) is only the default: placement, strip order, open windows,
// dock sizes and split ratios are the user's, saved under LAYOUT_KEY. A placement key ("pk") is "dock/slot".
const TW = new Map();
const DOCK_IDS = ["left", "right", "bottom"];
const SLOT_IDS = ["primary", "secondary"];
const DOCKS = {
  left: { box: "#side", split: "#vsplit", inner: "#sideSplit", label: "Sinistra", row: false },
  right: { box: "#rside", split: "#rvsplit", inner: "#rsideSplit", label: "Destra", row: false },
  bottom: { box: "#panel", split: "#hsplit", inner: "#panelSplit", label: "In basso", row: true },
};
// Strips: left = left/primary, separator, left/secondary … bottom/primary; right = right/primary, separator, right/secondary … bottom/secondary.
const SLOTS = {
  "left/primary": { box: "#sideA", head: "#sideHead", body: "#sideBody", strip: "#stripTop", label: "Sinistra in alto" },
  "left/secondary": { box: "#sideB", head: "#sideHead2", body: "#sideBody2", strip: "#stripTop2", label: "Sinistra in basso" },
  "right/primary": { box: "#rsideA", head: "#rsideHead", body: "#rsideBody", strip: "#rstripTop", label: "Destra in alto" },
  "right/secondary": { box: "#rsideB", head: "#rsideHead2", body: "#rsideBody2", strip: "#rstripTop2", label: "Destra in basso" },
  "bottom/primary": { box: "#panelA", head: "#panelHead", body: "#panelBody", strip: "#stripBottom", label: "In basso a sinistra" },
  "bottom/secondary": { box: "#panelB", head: "#panelHead2", body: "#panelBody2", strip: "#rstripBottom", label: "In basso a destra" },
};
const PK = Object.keys(SLOTS);
for (const k of PK) { const [dock, slot] = k.split("/"); Object.assign(SLOTS[k], { dock, slot }); }
const pkey = (dock, slot) => dock + "/" + (slot === "secondary" ? "secondary" : "primary");
const dockSlots = dock => SLOT_IDS.map(s => pkey(dock, s));
const area = Object.fromEntries(PK.map(k => [k, null]));
let activePk = null;
const DEFAULT_PLACE = { database: "right/primary", remote: "right/secondary", dbResults: "bottom/primary" };
const DEFAULT_OPEN = { "left/primary": "project", "right/primary": "database", "bottom/primary": "terminal" };
const DEFAULT_ORDER = {
  "left/primary": ["project", "commit", "history", "structure"], "right/primary": ["database"], "right/secondary": ["remote"],
  "bottom/primary": ["run", "terminal", "problems", "git", "dbResults"],
};
const DEFAULT_SIZE = { left: 300, right: 320, bottom: 300 };
const DEFAULT_RATIO = { left: 0.5, right: 0.5, bottom: 0.5 };
const LAYOUT_KEY = "elio.ide.layout.v3", LAYOUT_KEY_V2 = "elio.ide.layout.v2";
function freshLayout() {
  return { v: 3, place: {}, order: JSON.parse(JSON.stringify(DEFAULT_ORDER)), strip: {}, open: { ...DEFAULT_OPEN }, last: { ...DEFAULT_OPEN },
    restore: {}, size: { ...DEFAULT_SIZE }, ratio: { ...DEFAULT_RATIO } };
}
function loadLayout() {
  const l = freshLayout();
  const read = k => { try { return JSON.parse(localStorage.getItem(k) || "null"); } catch { return null; } };
  const saved = read(LAYOUT_KEY);
  if (saved && saved.v === 3) {
    for (const k of ["place", "order", "strip", "open", "last", "restore", "size", "ratio"]) if (saved[k] && typeof saved[k] === "object") Object.assign(l[k], saved[k]);
    return l;
  }
  // v2 (one window per dock): what it placed becomes primary; windows it never moved take the new defaults (Remoto below Database).
  const v2 = read(LAYOUT_KEY_V2);
  if (v2 && v2.v === 2) {
    const place = v2.place || {};
    for (const [id, d] of Object.entries(place)) if (DOCKS[d]) l.place[id] = pkey(d);
    for (const [d, ids] of Object.entries(v2.order || {})) if (DOCKS[d] && Array.isArray(ids)) l.order[pkey(d)] = ids.slice();
    Object.assign(l.strip, v2.strip || {});
    const where = (id, d) => DOCKS[place[id]] ? pkey(place[id]) : DEFAULT_PLACE[id] || pkey(d);
    l.open = {};
    for (const d of DOCK_IDS) {
      const o = v2.open && v2.open[d], last = v2.last && v2.last[d];
      if (o) l.open[where(o, d)] = o;
      if (last) l.last[where(last, d)] = last;
    }
    if (v2.size) Object.assign(l.size, v2.size);
    return l;
  }
  // v1 ("ide.tw" + "ide.layout"): keep open windows and sizes; Database and Remoto move to the right once.
  const tw = store.get("tw", null), sz = store.get("layout", null);
  if (tw) {
    if ("left" in tw) l.open["left/primary"] = tw.left && !DEFAULT_PLACE[tw.left] ? tw.left : tw.left ? "project" : null;
    if ("bottom" in tw) l.open["bottom/primary"] = tw.bottom || null;
    if (tw.lastBottom) l.last["bottom/primary"] = tw.lastBottom;
  }
  if (sz) { if (sz.side) l.size.left = sz.side; if (sz.panel) l.size.bottom = sz.panel; }
  return l;
}
let layout = loadLayout();
function saveLayout() { try { localStorage.setItem(LAYOUT_KEY, JSON.stringify(layout)); } catch {} }
function defaultPlace(tw) { return DEFAULT_PLACE[tw.id] || pkey(DOCKS[tw.defSide] ? tw.defSide : "left", tw.defSlot); }
function placeOf(tw) { return SLOTS[layout.place[tw.id]] ? layout.place[tw.id] : defaultPlace(tw); }
function setPlace(tw, pk) { tw.pk = pk; tw.side = SLOTS[pk].dock; tw.slot = SLOTS[pk].slot; }
function onStrip(tw) { return tw.id in layout.strip ? !!layout.strip[tw.id] : tw.stripDef; }
function isOpen(id) { const tw = TW.get(id); return !!tw && area[tw.pk] === id; }
// Is this window (or, for a shortcut like «Storia dei commit», its target in the right tab) on screen?
function isShown(tw) {
  const t = tw && (tw.proxy ? TW.get(tw.proxy) : tw);
  return !!t && area[t.pk] === t.id && (!tw.proxy || !t.isTab || t.isTab(tw.proxyOpts));
}
// Strip icons of a slot, in the user's order (tools never reordered follow their `order`).
function stripIds(pk) {
  const saved = layout.order[pk] || [];
  const rank = t => { const i = saved.indexOf(t.id); return i < 0 ? 1000 + t.order : i; };
  return [...TW.values()].filter(t => onStrip(t) && t.pk === pk).sort((a, b) => rank(a) - rank(b)).map(t => t.id);
}

function registerToolWindow(def) {
  const tw = Object.assign({ side: "left", order: 50, mounted: false, pane: null, headEl: null }, def);
  // Registration `slot`: "more" = off the strip until the user puts it there; "secondary" = default slot of its dock.
  tw.stripDef = def.slot ? def.slot !== "more" : !!tw.external;
  tw.defSide = tw.side;
  tw.defSlot = def.slot === "secondary" ? "secondary" : "primary";
  setPlace(tw, placeOf(tw));
  tw.headEl = tw.headEl || el("div", "tw-headx");
  TW.set(tw.id, tw);
  if (booted) {
    renderStrip();
    if (!tw.proxy && layout.open[tw.pk] === tw.id && !area[tw.pk]) showToolWindow(tw.id, { focus: false });
  }
  return tw;
}
function ensureMounted(tw) {
  if (!tw || tw.mounted || tw.proxy) return;
  tw.pane = el("div", "tw-pane");
  tw.pane.dataset.tw = tw.id;
  $(SLOTS[tw.pk].body).append(tw.pane);
  tw.mounted = true;
  try { tw.mount && tw.mount(tw.pane); } catch (e) { console.error(e); }
}
function paneOff(tw) {
  tw.pane.classList.remove("on"); tw.visible = false;
  try { tw.onHide && tw.onHide(); } catch (e) { console.error(e); }
}
// Shows / hides the dock, its slots and the inner splitter; split sizes follow the saved ratio.
function applyDock(dock) {
  const D = DOCKS[dock], [a, b] = dockSlots(dock);
  const any = !!(area[a] || area[b]), both = !!(area[a] && area[b]);
  $(SLOTS[a].box).classList.toggle("hidden", !area[a]);
  $(SLOTS[b].box).classList.toggle("hidden", !area[b]);
  $(D.box).classList.toggle("hidden", !any); $(D.split).classList.toggle("hidden", !any);
  $(D.inner).classList.toggle("hidden", !both);
  const r = Math.max(0.1, Math.min(0.9, +layout.ratio[dock] || 0.5));
  $(SLOTS[a].box).style.flex = both ? `${r} 1 0px` : "1 1 0px";
  $(SLOTS[b].box).style.flex = both ? `${1 - r} 1 0px` : "1 1 0px";
}
function showToolWindow(id, opts = {}) {
  const tw0 = TW.get(id); if (!tw0) return;
  if (tw0.proxy) return showToolWindow(tw0.proxy, Object.assign({}, tw0.proxyOpts, opts));
  const tw = tw0, pk = tw.pk;
  ensureMounted(tw);
  const prev = area[pk] && TW.get(area[pk]);
  if (prev && prev !== tw) paneOff(prev);
  area[pk] = tw.id;
  tw.pane.classList.add("on");
  layout.open[pk] = tw.id; layout.last[pk] = tw.id; delete layout.restore[tw.side]; activePk = pk; saveLayout();
  applyDock(tw.side);
  renderHead(pk); renderStrip();
  const wasVisible = tw.visible;
  tw.visible = true;
  if (!wasVisible || opts.tab) { try { tw.onShow && tw.onShow(opts); } catch (e) { console.error(e); } }
  // A slot that opens resizes its neighbour (or the editor): xterm, Monaco and the git graph refit.
  if (!prev) relayoutSoon();
  if (opts.focus !== false && tw.focus) setTimeout(() => tw.focus(opts), 20);
}
function hideSlot(pk, opts = {}) {
  const tw = TW.get(area[pk]);
  if (tw) paneOff(tw);
  area[pk] = null; layout.open[pk] = null; saveLayout();
  $(SLOTS[pk].head).innerHTML = "";
  applyDock(SLOTS[pk].dock);
  renderStrip(); relayoutSoon();
  if (!opts.noFocus && editor && S.active) editor.focus();
}
// `what`: a slot ("left/secondary"), a whole dock ("bottom", as before) or a window id (hidden only if it's on screen).
function hideToolWindow(what, opts = {}) {
  if (SLOTS[what]) { hideSlot(what, opts); return; }
  if (DOCKS[what]) {
    for (const k of dockSlots(what)) if (area[k]) hideSlot(k, { noFocus: true });
    if (!opts.noFocus && editor && S.active) editor.focus();
    return;
  }
  const tw = TW.get(what), t = tw && (tw.proxy ? TW.get(tw.proxy) : tw);
  if (t && area[t.pk] === t.id) hideSlot(t.pk, opts);
}
function toggleToolWindow(id) {
  const tw = TW.get(id); if (!tw) return;
  if (isShown(tw)) hideSlot((tw.proxy ? TW.get(tw.proxy) : tw).pk);
  else showToolWindow(id);
}
// ⌘J & co: hide the whole dock (remembering what was open), or bring it back as it was.
function toggleArea(dock) {
  const open = dockSlots(dock).filter(k => area[k]);
  if (open.length) { layout.restore[dock] = open.map(k => area[k]); hideToolWindow(dock); saveLayout(); return; }
  let ids = (layout.restore[dock] || []).filter(id => { const t = TW.get(id); return t && !t.proxy && t.side === dock; });
  if (!ids.length) {
    for (const k of dockSlots(dock)) {
      const last = TW.get(layout.last[k]);
      const id = last && !last.proxy && last.pk === k ? last.id : stripIds(k).find(x => !TW.get(x).proxy) || DEFAULT_OPEN[k];
      const t = TW.get(id);
      if (t && t.pk === k) { ids = [id]; break; }
    }
  }
  ids.forEach((id, i) => showToolWindow(id, { focus: i === ids.length - 1 }));
}
// Moves a tool window (or a strip shortcut) to another dock / slot / strip position. `dock` may also be a "dock/slot" key.
// The pane DOM node is moved, never remounted: terminals, result grids and editors inside keep their state.
function moveToolWindow(id, dock, opts = {}) {
  const tw = TW.get(id); if (!tw) return;
  if (SLOTS[dock]) { opts = Object.assign({}, opts, { slot: SLOTS[dock].slot }); dock = SLOTS[dock].dock; }
  if (!DOCKS[dock]) return;
  const slot = SLOT_IDS.includes(opts.slot) ? opts.slot : tw.side === dock ? tw.slot : "primary";
  const to = pkey(dock, slot), from = tw.pk;
  const wasShown = !tw.proxy && area[from] === id;
  if (from !== to) {
    if (wasShown) hideSlot(from, { noFocus: true });
    setPlace(tw, to);
    if (tw.mounted) $(SLOTS[to].body).append(tw.pane);
  }
  layout.place[id] = to;
  layout.strip[id] = true;
  for (const k of Object.keys(layout.order)) if (Array.isArray(layout.order[k])) layout.order[k] = layout.order[k].filter(x => x !== id);
  const ids = stripIds(to).filter(x => x !== id);
  ids.splice(opts.index == null ? ids.length : Math.max(0, Math.min(ids.length, opts.index)), 0, id);
  layout.order[to] = ids;
  saveLayout();
  if (!tw.proxy && (wasShown || opts.show)) showToolWindow(id, { focus: false });
  renderStrip(); relayoutSoon();
}
function resetLayout() {
  for (const k of PK) if (area[k]) hideSlot(k, { noFocus: true });
  try { localStorage.removeItem(LAYOUT_KEY); } catch {}
  layout = freshLayout();
  for (const tw of TW.values()) { setPlace(tw, placeOf(tw)); if (tw.mounted) $(SLOTS[tw.pk].body).append(tw.pane); }
  applySizes();
  for (const k of PK) { const tw = TW.get(DEFAULT_OPEN[k]); if (tw && tw.pk === k) showToolWindow(tw.id, { focus: false }); }
  layout.open = { ...DEFAULT_OPEN };
  saveLayout(); renderStrip(); relayoutSoon();
  toast("Disposizione ripristinata", "ok");
}
// Fits what depends on the size (xterm, git graph, tree) and tells modules: IDE.on("layout").
let relayoutQueued = false;
function relayoutSoon() {
  if (relayoutQueued) return;
  relayoutQueued = true;
  requestAnimationFrame(() => { relayoutQueued = false; relayout(); });
}
function relayout() {
  if (S.panel && S.panel.fit && S.panel.el && S.panel.el.offsetWidth) { try { S.panel.fit.fit(); } catch {} }
  if (editor) { try { editor.layout(); } catch {} }
  for (const tw of TW.values()) if (tw.visible && tw.onLayout) { try { tw.onLayout(); } catch (e) { console.error(e); } }
  paintTreeSoon();
  emitLocal("layout", {});
}
function windowMenu(tw, opts = {}) {
  const target = tw.proxy ? TW.get(tw.proxy) : tw;
  return [
    isShown(tw) ? { label: "Nascondi", icon: "hide", key: "⇧Esc", action: () => hideSlot(target.pk) }
      : { label: "Mostra", icon: tw.icon, key: tw.key, action: () => showToolWindow(tw.id) },
    { label: tw.proxy ? "Sposta l'icona in" : "Sposta in", icon: "sidebar",
      items: PK.map(k => ({ label: SLOTS[k].label, checked: tw.pk === k, action: () => moveToolWindow(tw.id, SLOTS[k].dock, { slot: SLOTS[k].slot, show: !tw.proxy }) })) },
    opts.strip && { label: "Togli dalla barra (resta in «…»)", action: () => { layout.strip[tw.id] = false; saveLayout(); renderStrip(); } },
    null,
    { label: "Ripristina disposizione", icon: "refresh", action: resetLayout },
  ];
}
function refreshHead(id) { const tw = TW.get(id); if (tw && area[tw.pk] === id) renderHead(tw.pk); }
function renderHead(pk) {
  const head = $(SLOTS[pk].head);
  head.innerHTML = "";
  const tw = TW.get(area[pk]); if (!tw) return;
  const t = el("span", "tw-title", tw.title);
  head.append(t, tw.headEl, el("span", "spacer"));
  for (const a of (tw.actions ? tw.actions() : []).filter(Boolean)) {
    if (a.separator) { head.append(el("span", "tw-sep")); continue; }
    const b = el("button", "tb-ico" + (a.on ? " on" : "")); b.innerHTML = icon(a.icon); b.title = a.title || "";
    b.onclick = e => a.action(e, b);
    head.append(b);
  }
  const opt = el("button", "tb-ico"); opt.innerHTML = icon("kebab"); opt.title = "Opzioni della finestra (sposta, nascondi)";
  opt.onclick = () => { const r = opt.getBoundingClientRect(); menu({ clientX: r.left, clientY: r.bottom + 2 }, windowMenu(tw)); };
  const hide = el("button", "tb-ico"); hide.innerHTML = icon("hide"); hide.title = "Nascondi (⇧Esc)"; hide.onclick = () => hideSlot(pk);
  head.append(opt, hide);
  head.oncontextmenu = e => {
    if (e.target.closest("input, textarea, select")) return;
    e.preventDefault(); menu(e, windowMenu(tw));
  };
  // Drag the header (not its buttons or fields) to move the window, like a JetBrains tool window tab.
  head.onpointerdown = e => {
    if (e.button !== 0 || e.target.closest("button, input, textarea, select, a, .tw-headx > *")) return;
    beginTwDrag(tw, e);
  };
}

// Strip icons: click toggles, right-click moves, drag & drop onto another strip group moves / reorders.
let dragTw = null, dropAt = null, stripDirty = false;
const dropMark = el("div", "sb-drop");
function renderStrip() {
  if (!booted) return;
  if (dragTw) { stripDirty = true; return; }
  for (const k of PK) $(SLOTS[k].strip).innerHTML = "";
  $("#stripMore").innerHTML = "";
  const list = [...TW.values()].sort((a, b) => a.order - b.order);
  const btn = tw => {
    const b = el("button", "sb" + (isShown(tw) ? " on" : ""));
    b.innerHTML = icon(tw.icon || "more");
    b.title = tw.title + (tw.key ? `  ${tw.key}` : "");
    b.dataset.id = tw.id;
    const badge = tw.badge ? tw.badge() : null;
    if (badge) { const d = el("span", "sbadge" + (typeof badge === "object" && badge.kind ? " " + badge.kind : ""), typeof badge === "object" ? badge.text || "" : String(badge === true ? "" : badge)); b.append(d); }
    b.onclick = () => toggleToolWindow(tw.id);
    b.oncontextmenu = e => { e.preventDefault(); menu(e, windowMenu(tw, { strip: true })); };
    b.onpointerdown = e => { if (e.button === 0) beginTwDrag(tw, e, b); };
    return b;
  };
  for (const k of PK) for (const id of stripIds(k)) $(SLOTS[k].strip).append(btn(TW.get(id)));
  // The thin line between a side's primary and secondary groups only shows when the secondary one has icons.
  $("#stripSep").classList.toggle("empty", !$("#stripTop2").children.length);
  $("#rstripSep").classList.toggle("empty", !$("#rstripTop2").children.length);
  const more = el("button", "sb more"); more.innerHTML = icon("more"); more.title = "Altre finestre";
  more.onclick = () => {
    const r = more.getBoundingClientRect();
    menu({ clientX: r.right + 4, clientY: r.top }, [
      ...list.filter(t => !t.proxy).map(t => ({ label: t.title, icon: t.icon, key: t.key, action: () => showToolWindow(t.id), checked: area[t.pk] === t.id })),
      null,
      { label: "Ripristina disposizione", icon: "refresh", action: resetLayout },
    ]);
  };
  $("#stripMore").append(more);
}
// Moving tool windows by dragging (pointer events: HTML5 drag & drop is unreliable in WKWebView). A drag starts
// after a few pixels, so a plain click still toggles. Drop on a strip group (exact position) or on an edge zone of
// the window: left / right edges split in upper / lower half, the bottom edge in left / right half. The highlight
// shows the half the window will take.
let suppressClick = false, ghost = null, zoneMark = null;
function beginTwDrag(tw, e, srcBtn) {
  const x0 = e.clientX, y0 = e.clientY;
  let started = false;
  const move = ev => {
    if (!started) {
      if (Math.hypot(ev.clientX - x0, ev.clientY - y0) < 6) return;
      started = true;
      dragTw = tw.proxy || tw.id;
      document.body.classList.add("tw-dragging");
      srcBtn && srcBtn.classList.add("dragging");
      const t = TW.get(dragTw) || tw;
      ghost = el("div", "tw-ghost"); ghost.innerHTML = icon(t.icon || "more"); ghost.append(el("span", "", t.title));
      zoneMark = el("div", "tw-zone");
      document.body.append(zoneMark, ghost);
    }
    ghost.style.transform = `translate(${ev.clientX + 12}px, ${ev.clientY + 10}px)`;
    trackDrop(ev.clientX, ev.clientY);
  };
  const finish = ev => {
    window.removeEventListener("pointermove", move, true);
    window.removeEventListener("pointerup", up, true);
    window.removeEventListener("keydown", esc, true);
    if (!started) return;
    // The click that follows a drag must not toggle the window.
    suppressClick = true; setTimeout(() => { suppressClick = false; }, 0);
    const id = dragTw, at = ev ? dropAt : null;
    endStripDrag();
    if (at) { moveToolWindow(id, at.dock, { slot: at.slot, index: at.index }); showToolWindow(id, { focus: false }); }
  };
  const up = ev => finish(ev);
  const esc = ev => { if (ev.key === "Escape") { ev.stopPropagation(); finish(null); } };
  window.addEventListener("pointermove", move, true);
  window.addEventListener("pointerup", up, true);
  window.addEventListener("keydown", esc, true);
}
document.addEventListener("click", e => { if (suppressClick) { e.stopPropagation(); e.preventDefault(); } }, true);
// Where would it land? Strips first (precise), then the window's edge zones.
function trackDrop(x, y) {
  const inside = r => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
  for (const [nav, sep, side, low] of [["#strip", "#stripSep", "left", "bottom/primary"], ["#rstrip", "#rstripSep", "right", "bottom/secondary"]]) {
    const n = $(nav); if (!inside(n.getBoundingClientRect())) continue;
    const sp = n.querySelector(".spacer").getBoundingClientRect(), s = $(sep).getBoundingClientRect();
    markDrop(y > sp.top + sp.height / 2 ? low : y < s.top + s.height / 2 ? side + "/primary" : side + "/secondary", y);
    zoneMark.className = "tw-zone"; return;
  }
  dropMark.remove();
  document.querySelectorAll(".grp.drop").forEach(g => g.classList.remove("drop"));
  const main = $("#main").getBoundingClientRect();
  const l = $("#strip").getBoundingClientRect().right, rgt = $("#rstrip").getBoundingClientRect().left;
  let dock = null;
  if (inside(main)) {
    const fx = (x - l) / (rgt - l), fy = (y - main.top) / main.height;
    const near = [["left", fx / 0.28], ["right", (1 - fx) / 0.28], ["bottom", (1 - fy) / 0.32]].filter(c => c[1] < 1).sort((a, b) => a[1] - b[1]);
    if (near.length) dock = near[0][0];
  }
  if (!dock) { dropAt = null; zoneMark.className = "tw-zone"; return; }
  // The dock's rectangle (where it is, or where it will appear) and where it splits.
  const D = DOCKS[dock], box = $(D.box);
  let r;
  if (!box.classList.contains("hidden")) r = box.getBoundingClientRect();
  else if (dock === "bottom") { const c = $("#center").getBoundingClientRect(), h = Math.min(layout.size.bottom || DEFAULT_SIZE.bottom, c.height - 200); r = { left: c.left, top: c.bottom - h, width: c.width, height: h }; }
  else { const w = Math.min(layout.size[dock] || DEFAULT_SIZE[dock], (rgt - l) * 0.45); r = { left: dock === "left" ? l : rgt - w, top: main.top, width: w, height: main.height }; }
  const [a, b] = dockSlots(dock);
  const busy = k => area[k] && area[k] !== dragTw;
  const ratio = Math.max(0.1, Math.min(0.9, +layout.ratio[dock] || 0.5));
  const at = (k, other) => busy(other) ? (k === a ? ratio : 1 - ratio) : 0.5;
  let rect, slot;
  if (D.row) {
    const cut = r.left + r.width * at(a, b);
    slot = x < cut ? "primary" : "secondary";
    rect = slot === "primary" ? [r.left, r.top, cut - r.left, r.height] : [cut, r.top, r.left + r.width - cut, r.height];
  } else {
    const cut = r.top + r.height * at(a, b);
    slot = y < cut ? "primary" : "secondary";
    rect = slot === "primary" ? [r.left, r.top, r.width, cut - r.top] : [r.left, cut, r.width, r.top + r.height - cut];
  }
  dropAt = { dock, slot, index: null };
  zoneMark.className = "tw-zone on";
  zoneMark.innerHTML = ""; zoneMark.append(el("span", "", SLOTS[pkey(dock, slot)].label));
  Object.assign(zoneMark.style, { left: rect[0] + "px", top: rect[1] + "px", width: rect[2] + "px", height: rect[3] + "px" });
}
function endStripDrag() {
  dragTw = null; dropAt = null;
  dropMark.remove();
  ghost && ghost.remove(); zoneMark && zoneMark.remove(); ghost = zoneMark = null;
  document.querySelectorAll(".sb.dragging").forEach(b => b.classList.remove("dragging"));
  document.querySelectorAll(".grp.drop").forEach(g => g.classList.remove("drop"));
  document.body.classList.remove("tw-dragging");
  if (stripDirty) { stripDirty = false; renderStrip(); }
}
function markDrop(pk, y) {
  const grp = $(SLOTS[pk].strip);
  const btns = [...grp.querySelectorAll(".sb[data-id]")].filter(b => b.dataset.id !== dragTw);
  let index = btns.findIndex(b => { const r = b.getBoundingClientRect(); return y < r.top + r.height / 2; });
  if (index < 0) index = btns.length;
  const before = btns[index];
  if (before) grp.insertBefore(dropMark, before); else grp.append(dropMark);
  document.querySelectorAll(".grp.drop").forEach(g => g !== grp && g.classList.remove("drop"));
  grp.classList.add("drop");
  dropAt = { dock: SLOTS[pk].dock, slot: SLOTS[pk].slot, index };
}
// The splitter between a dock's two slots (double click: back to half and half), and which slot was used last (⇧Esc).
function setupDocks() {
  for (const d of DOCK_IDS) {
    const D = DOCKS[d], handle = $(D.inner);
    handle.addEventListener("mousedown", e => {
      e.preventDefault();
      document.body.classList.add("dragging");
      const move = ev => {
        const r = $(D.box).getBoundingClientRect();
        const total = D.row ? r.width : r.height, pos = D.row ? ev.clientX - r.left : ev.clientY - r.top;
        const min = D.row ? 180 : 72;
        layout.ratio[d] = total > 2 * min ? Math.max(min, Math.min(total - min, pos)) / total : 0.5;
        applyDock(d); relayoutSoon();
      };
      const up = () => { document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up);
        document.body.classList.remove("dragging"); saveLayout(); relayout(); };
      document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
    });
    handle.addEventListener("dblclick", () => { layout.ratio[d] = 0.5; saveLayout(); applyDock(d); relayoutSoon(); });
  }
  for (const k of PK) {
    const b = $(SLOTS[k].box);
    b.addEventListener("pointerdown", () => { activePk = k; }, true);
    b.addEventListener("focusin", () => { activePk = k; });
  }
}

// Built-in tool windows of the core (git.js, problems.js, structure.js, run.js add theirs).
registerToolWindow({
  id: "project", title: "Progetto", icon: "project", side: "left", slot: "top", order: 10, key: "⌘1",
  mount(box) {
    const t = el("div", "tree"); t.id = "tree"; t.tabIndex = 0;
    t.addEventListener("scroll", paintTreeSoon);
    t.addEventListener("keydown", treeKeys);
    box.append(t);
    new ResizeObserver(paintTreeSoon).observe(t);
    paintTree();
  },
  focus() { $("#tree").focus({ preventScroll: true }); },
  actions: () => [
    { icon: "plus", title: "Nuovo… / aggiungi cartella", action: (e, b) => { const r = b.getBoundingClientRect(); menu({ clientX: r.left, clientY: r.bottom + 2 }, [
      { label: "Nuovo file…", icon: "newFile", key: "⌘N", action: () => { const d = selectedDir(); d && createEntry(d, false); } },
      { label: "Nuova cartella…", icon: "newFolder", action: () => { const d = selectedDir(); d && createEntry(d, true); } },
      null,
      { label: "Aggiungi cartella al workspace…", icon: "folder", action: addFolder },
      { label: "Aggiungi progetto dalla lista…", icon: "project", action: () => showPalette("projects") },
    ]); } },
    { icon: "locate", title: "Mostra il file aperto nell'albero (⌥F1)", action: () => S.active && !S.active.virtual && revealInTree(S.active.path) },
    { icon: "expandAll", title: "Espandi tutto", action: expandAll },
    { icon: "collapseAll", title: "Comprimi tutto", action: collapseAll },
    { icon: "settings", title: "Opzioni dell'albero", action: (e, b) => { const r = b.getBoundingClientRect(); menu({ clientX: r.left, clientY: r.bottom + 2 }, [
      { label: "Aggiungi cartella al workspace…", action: addFolder },
      { label: "Ricarica l'albero", icon: "refresh", action: () => { treeCache.clear(); renderTree(); S.roots.forEach(loadFiles); refreshGitAll(); } },
      null,
      ...S.roots.map(r => ({ label: `Rimuovi «${r.name}» dal workspace`, action: () => removeRoot(r) })),
    ]); } },
  ],
});
registerToolWindow({
  id: "agents", title: "Agenti", icon: "agents", side: "left", slot: "more", order: 80,
  mount(box) { const l = el("div", "list"); l.id = "agentsList"; box.append(l); renderAgents(); },
  badge: () => { const n = S.agents.filter(a => ["running", "waitingConfirmation"].includes(a.status)).length; return n ? { text: String(n), kind: "info" } : null; },
});
registerToolWindow({
  id: "find", title: "Cerca", icon: "find", side: "bottom", slot: "more", order: 85, key: "⌘⇧F",
  mount: mountFind,
});
registerToolWindow({
  id: "terminal", title: "Terminale", icon: "terminal", side: "bottom", slot: "bottom", order: 20, key: "⌥F12",
  mount(box) { termBody = el("div", "term-body"); box.append(termBody); },
  onShow(opts) {
    if (!S.panels.length && !(opts && opts.noAutoShell)) newShell();
    else if (S.panel && S.panel.fit) setTimeout(() => { try { S.panel.fit.fit(); } catch {} }, 20);
    renderPanelTabs();
  },
  focus() { if (S.panel && S.panel.term && S.panel.kind === "shell") S.panel.term.focus(); },
});

// ---------- Status bar: breadcrumb (bottom left) and file info ----------
let crumbTimer;
function crumb(text, iconHtml, onClick, cls = "") {
  const s = el("span", "crumb " + cls);
  if (iconHtml) { const i = el("span", "ic"); i.innerHTML = iconHtml; s.append(i); }
  s.append(el("span", "nm", text));
  if (onClick) s.onclick = e => onClick(e, s);
  return s;
}
function renderCrumbs() {
  const c = $("#crumbs"); c.innerHTML = "";
  const t = S.active;
  const sep = () => { const s = el("span", "sep"); s.innerHTML = icon("chevronRight"); return s; };
  if (!t) { const r = cur(); if (r) c.append(crumb(r.name, fileIcon(r.name, true, false, true), () => revealInTree(r.path))); return; }
  if (t.virtual) { c.append(crumb(t.title, t.icon ? icon(t.icon) : fileIcon(t.title, false))); return; }
  const r = rootOf(t.path);
  const rel = r ? relative(t.path, r) : t.path.replace(/^\//, "");
  const parts = rel.split("/");
  let acc = r ? r.path : "";
  if (r) c.append(crumb(r.name, fileIcon(r.name, true, false, true), () => revealInTree(r.path), "root"));
  parts.forEach((p, i) => {
    acc = acc + "/" + p;
    const last = i === parts.length - 1;
    if (c.childNodes.length) c.append(sep());
    const path = acc;
    if (last) {
      const g = typeof gitClass === "function" ? gitClass(path) : "";
      c.append(crumb(p, fileIcon(p, false), (e, s) => symbolMenu(s), "file " + g));
    } else c.append(crumb(p, null, () => revealInTree(path), "dir"));
  });
  const sym = el("span", "crumb-sym"); c.append(sym);
  renderCrumbSymbol();
}
async function renderCrumbSymbol() {
  const box = document.querySelector("#crumbs .crumb-sym"); if (!box || !S.active || typeof symbolChainAt !== "function") return;
  const pos = editor.getPosition(); if (!pos) return;
  const chain = await symbolChainAt(S.active.model, pos.lineNumber);
  box.innerHTML = "";
  for (const s of chain) {
    const sp = el("span", "sep"); sp.innerHTML = icon("chevronRight"); box.append(sp);
    box.append(crumb(s.name, symbolIcon(s.kind), (e, el_) => symbolMenu(el_), "sym"));
  }
}
async function symbolMenu(anchor) {
  if (!S.active || typeof getSymbols !== "function") return;
  const syms = await getSymbols(S.active.model);
  const flatS = []; const walk = (list, d) => list.forEach(s => { flatS.push({ s, d }); walk(s.children || [], d + 1); }); walk(syms, 0);
  const r = anchor.getBoundingClientRect();
  if (!flatS.length) { menu({ clientX: r.left, clientY: r.top }, [{ label: "Nessun simbolo in questo file", disabled: true }], { above: true }); return; }
  menu({ clientX: r.left, clientY: r.top }, flatS.slice(0, 300).map(({ s, d }) => ({ label: " ".repeat(d) + s.name, iconHtml: symbolIcon(s.kind),
    action: () => { editor.revealLineInCenter(s.line); editor.setPosition({ lineNumber: s.line, column: s.col || 1 }); editor.focus(); } })), { above: true });
}

// ---------- UI wiring ----------
function buildChrome() {
  $("#projectBtn").innerHTML = `<span id="projBadge" class="pbadge"></span><span id="projectName">Aggiungi un progetto</span>${icon("chevronDown", "caret")}`;
  $("#branchBtn").innerHTML = `${icon("branch")}<span id="branchName">—</span><span id="branchSync"></span>${icon("chevronDown", "caret")}`;
  $("#updateBtn").innerHTML = icon("update");
  $("#commitBtn").innerHTML = icon("check");
  $("#pushBtn").innerHTML = icon("push");
  $("#historyBtn").innerHTML = icon("history");
  $("#searchBtn").innerHTML = `${icon("search")}<span>Cerca ovunque</span><kbd>⇧⇧</kbd>`;
  $("#agentsBtn").innerHTML = `${icon("agents")}<span id="agentsCount">0 agenti</span>`;
  $("#askBtn").innerHTML = `${icon("elio")}<span>Elio</span>`;
}
function renderWelcome() {
  const w = $("#welcome .start"); if (!w) return;
  w.innerHTML = "";
  if (!S.roots.length) {
    const add = el("button", "btn go", "Aggiungi una cartella…"); add.onclick = addFolder;
    const list = el("button", "btn", "Dai miei progetti…"); list.onclick = () => showPalette("projects");
    w.append(add, list);
  }
}
on("projectChanged", renderWelcome);
function projectMenu(e) {
  const r = $("#projectBtn").getBoundingClientRect();
  const c = cur();
  menu({ clientX: r.left, clientY: r.bottom + 4 }, [
    ...S.roots.map(x => ({ label: x.name, iconHtml: fileIcon(x.name, true, false, true), key: tilde(x.path), checked: c && c.path === x.path,
      action: () => { S.selected = x.path; onCurrentChanged(); revealInTree(x.path); } })),
    S.roots.length && null,
    { label: "Aggiungi cartella al workspace…", icon: "plus", action: addFolder },
    { label: "Aggiungi progetto dalla lista…", icon: "project", action: () => showPalette("projects") },
    c && null,
    c && { label: `Rimuovi «${c.name}» dal workspace`, icon: "close", action: () => removeRoot(c) },
  ]);
}
function wireUI() {
  $("#projectBtn").onclick = projectMenu;
  $("#branchBtn").onclick = () => showBranchesPopup();
  $("#updateBtn").onclick = () => updateProject();
  $("#commitBtn").onclick = () => commitDialog();
  $("#pushBtn").onclick = () => pushNow();
  $("#historyBtn").onclick = () => toggleToolWindow("git");
  $("#searchBtn").onclick = () => showPalette("all");
  $("#askBtn").onclick = () => askElioSelection();
  $("#agentsBtn").onclick = () => toggleToolWindow("agents");
  $("#stAgents").onclick = () => showToolWindow("agents");
  $("#stPos").onclick = () => S.active && showPalette("line");
  $("#stBranch").onclick = () => showBranchesPopup();
  $("#stProblems").onclick = () => toggleToolWindow("problems");
  $("#stElio").onclick = () => askElioSelection();
  document.addEventListener("mousedown", e => {
    if (!e.target.closest(".ctxm")) closeMenus();
    if (!e.target.closest(".popup") && !e.target.closest(".ctxm") && !e.target.closest("#dialog")) closePopup();
  });
  window.addEventListener("resize", relayoutSoon);
}
function setupSplitters() {
  const drag = (handle, dock, onMove) => handle.addEventListener("mousedown", e => {
    e.preventDefault();
    document.body.classList.add("dragging");
    const move = ev => { setDockSize(dock, onMove(ev)); if (dock === "bottom") relayoutSoon(); };
    const up = () => { document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up);
      document.body.classList.remove("dragging");
      saveLayout(); relayout(); };
    document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
  });
  drag($("#vsplit"), "left", e => e.clientX - $("#strip").offsetWidth);
  drag($("#rvsplit"), "right", e => window.innerWidth - e.clientX - $("#rstrip").offsetWidth);
  drag($("#hsplit"), "bottom", e => window.innerHeight - e.clientY - $("#status").offsetHeight);
  applySizes();
}
// Dock sizes: side docks leave the editor at least ~360px, the bottom one leaves it 200px.
function setDockSize(dock, px) {
  if (dock === "bottom") {
    const h = Math.round(Math.max(90, Math.min(window.innerHeight - 200, px)));
    $("#panel").style.height = h + "px"; layout.size.bottom = h;
    return;
  }
  const other = dock === "left" ? "right" : "left";
  const otherW = dockSlots(other).some(k => area[k]) ? $(DOCKS[other].box).offsetWidth : 0;
  const w = Math.round(Math.max(180, Math.min(window.innerWidth - otherW - 80 - 360, px)));
  $(DOCKS[dock].box).style.width = w + "px"; layout.size[dock] = w;
}
function applySizes() {
  $("#side").style.width = (layout.size.left || DEFAULT_SIZE.left) + "px";
  $("#rside").style.width = (layout.size.right || DEFAULT_SIZE.right) + "px";
  $("#panel").style.height = (layout.size.bottom || DEFAULT_SIZE.bottom) + "px";
}

// ---------- Menus (with submenus), popups, dialogs ----------
function normItem(it) {
  if (it === null) return { separator: true };
  if (!it) return null;
  if (Array.isArray(it)) return { label: it[0], action: it[1], key: it[2] };
  return it;
}
function closeMenus(fromLevel = 0) { document.querySelectorAll(".ctxm").forEach(m => { if (+m.dataset.level >= fromLevel) m.remove(); }); }
// Context menu at the pointer. Items: {label, action, key, icon, iconHtml, danger, disabled, checked, separator, items (submenu)}
// or the short form [label, action, key]; null = separator, false/undefined = skipped.
function menu(e, items, opts = {}) {
  closeMenus();
  if (e && e.preventDefault && e.type === "contextmenu") e.preventDefault();
  openMenuAt(e.clientX, e.clientY, items, 0, opts);
}
function openMenuAt(x, y, items, level, opts = {}) {
  const list = items.map(normItem).filter(Boolean);
  while (list.length && list[0].separator) list.shift();
  while (list.length && list[list.length - 1].separator) list.pop();
  const m = el("div", "ctxm"); m.dataset.level = level;
  let prevSep = false;
  for (const it of list) {
    if (it.separator) { if (!prevSep) m.append(el("div", "sep")); prevSep = true; continue; }
    prevSep = false;
    const row = el("div", "mi" + (it.disabled ? " disabled" : "") + (it.danger ? " danger" : ""));
    const ic = el("span", "mic");
    if (it.iconHtml) ic.innerHTML = it.iconHtml; else if (it.icon) ic.innerHTML = icon(it.icon); else if (it.checked) ic.innerHTML = icon("check");
    row.append(ic, el("span", "ml", it.label));
    if (it.key) row.append(el("span", "k", it.key));
    if (it.items) { const ch = el("span", "chev"); ch.innerHTML = icon("chevronRight"); row.append(ch); }
    row.onmouseenter = () => {
      closeMenus(level + 1);
      m.querySelectorAll(".mi.open").forEach(r => r.classList.remove("open"));
      if (it.items && !it.disabled) {
        row.classList.add("open");
        const r = row.getBoundingClientRect();
        const sub = typeof it.items === "function" ? it.items() : it.items;
        Promise.resolve(sub).then(s => { if (row.classList.contains("open")) openMenuAt(r.right - 2, r.top - 4, s, level + 1, { side: r.left }); });
      }
    };
    row.onclick = ev => {
      ev.stopPropagation();
      if (it.disabled || it.items) return;
      closeMenus(); if (!opts.keepPopup) closePopup();
      try { it.action && it.action(); } catch (err) { console.error(err); }
    };
    m.append(row);
  }
  if (!list.length) m.append(el("div", "mi disabled", "—"));
  document.body.append(m);
  const w = m.offsetWidth, h = m.offsetHeight;
  let left = x, top = opts.above ? y - h - 4 : y;
  if (left + w > innerWidth - 6) left = opts.side != null ? opts.side - w + 2 : innerWidth - w - 6;
  if (top + h > innerHeight - 6) top = Math.max(6, innerHeight - h - 6);
  m.style.left = Math.max(6, left) + "px"; m.style.top = Math.max(6, top) + "px";
  return m;
}
// Anchored popup panel (git branches…): closes on Escape or a click outside.
function openPopup(anchor, cls = "") {
  closePopup();
  const p = el("div", "popup " + cls);
  document.body.append(p);
  const r = anchor.getBoundingClientRect();
  p.style.left = Math.max(6, Math.min(r.left, innerWidth - 480)) + "px";
  p.style.top = (r.bottom + 4) + "px";
  return p;
}
function closePopup() { document.querySelectorAll(".popup").forEach(p => { p.remove(); }); }
function copy(text) { navigator.clipboard.writeText(text).then(() => toast("Copiato", "ok")).catch(() => {}); }
let dialogDone = null;
function openDialog(cls = "") {
  closeDialog();
  const body = $("#dlgBody"); body.innerHTML = ""; body.className = "dlg " + cls;
  $("#dialog").classList.remove("hidden");
  return body;
}
function closeDialog() {
  if ($("#dialog").classList.contains("hidden")) return;
  $("#dialog").classList.add("hidden");
  const d = dialogDone; dialogDone = null; if (d) d();
}
function prompt_(title, value, placeholder) {
  return new Promise(resolve => {
    const body = openDialog();
    body.append(el("h3", "", title));
    const input = el("input"); input.type = "text"; input.value = value || ""; input.placeholder = placeholder || "";
    const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn go", "OK");
    btns.append(no, ok); body.append(input, btns);
    input.focus(); input.select();
    let settled = false;
    const done = v => { if (settled) return; settled = true; dialogDone = null; $("#dialog").classList.add("hidden"); resolve(v); if (editor && S.active) editor.focus(); };
    dialogDone = () => done(null);
    no.onclick = () => done(null); ok.onclick = () => done(input.value.trim());
    input.onkeydown = e => { if (e.key === "Enter") done(input.value.trim()); if (e.key === "Escape") done(null); };
  });
}
function confirm_(title, note, action, opts = {}) {
  return new Promise(resolve => {
    const body = openDialog();
    body.append(el("h3", "", title)); if (note) body.append(el("div", "note", note));
    const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn " + (opts.danger ? "danger-go" : "go"), action || "OK");
    btns.append(no, ok); body.append(btns);
    (opts.danger ? no : ok).focus();
    let settled = false;
    const done = v => { if (settled) return; settled = true; dialogDone = null; $("#dialog").classList.add("hidden"); resolve(v); };
    dialogDone = () => done(false);
    no.onclick = () => done(false); ok.onclick = () => done(true);
    body.onkeydown = e => { if (e.key === "Escape") done(false); if (e.key === "Enter" && !opts.danger) done(true); };
  });
}
$("#dialog").addEventListener("mousedown", e => { if (e.target.id === "dialog") closeDialog(); });

// ---------- Native menu → page ----------
on("ideAction", d => {
  const a = d && d.action;
  const acts = {
    addFolder, commit: () => commitDialog(), push: () => pushNow(), update: () => updateProject(), newBranch: () => newBranch(),
    branches: () => showBranchesPopup(), checkoutRevision: () => checkoutRevision(), fetch: () => fetchNow(cur(), false),
    gitLog: () => showToolWindow("git", { tab: "log" }), commitPanel: () => showToolWindow("commit"), newFile: () => newEntryMenu(),
  };
  if (acts[a]) acts[a]();
  else if (TW.has(a)) showToolWindow(a);
  else toast(`Azione non disponibile: ${a}`, "error");
});

// ---------- Public API (connections.js and future modules) ----------
window.IDE = {
  ready: false,
  call: (op, args) => api(op, args || {}),
  on: (name, fn) => on(name, fn),
  toast: (text, kind) => toast(text, kind || "info"),
  openTerminal(o = {}) {
    // `command`: array = exact argv (ssh -p 22 user@host), string = shell line.
    const argv = Array.isArray(o.command) ? o.command.map(String) : undefined;
    const line = typeof o.command === "string" ? o.command : undefined;
    shellCount++;
    const id = "sh" + shellCount + "x";
    const tw = TW.get("terminal"); ensureMounted(tw);
    const pane = el("div", "pane"); const box = el("div", "term"); pane.append(box);
    const p = { id, kind: "shell", title: o.title || (argv ? argv[0] : line ? line.split(" ")[0] : "Terminale"), el: pane, cwd: o.cwd || (cur() && cur().path) || "" };
    addPanel(p); showPanel(p);
    attachPty(p, box, { cwd: p.cwd, command: line, argv }).then(() => p.term.focus());
    return id;
  },
  openEditorTab: o => openVirtualTab(o || {}),
  registerToolWindow: def => { registerToolWindow(Object.assign({ external: true }, def)); },
  showToolWindow: (id, opts) => showToolWindow(id, opts || {}),
  // A window id (hidden if on screen), a slot ("right/secondary") or a whole dock ("bottom").
  hideToolWindow: what => hideToolWindow(what),
  // dock: "left" | "right" | "bottom"; opts: { slot: "primary" | "secondary", index, show } (the user can move windows too).
  moveToolWindow: (id, dock, opts) => moveToolWindow(id, dock, opts || {}),
  toolWindowDock: id => { const tw = TW.get(id); return tw ? tw.side : null; },
  toolWindowSlot: id => { const tw = TW.get(id); return tw ? tw.slot : null; },
  refreshToolWindow: id => { renderStrip(); refreshHead(id); },
  currentProject: () => { const r = cur(); return r ? { name: r.name, path: r.path } : null; },
  projects: () => S.roots.map(r => ({ name: r.name, path: r.path })),
  activeFile: () => {
    const t = S.active; if (!t || t.virtual) return null;
    const r = rootOf(t.path);
    return { path: t.path, project: r ? { name: r.name, path: r.path } : null };
  },
  confirm: (text, opts = {}) => confirm_(text, opts.note || "", opts.action || (opts.danger ? "Conferma" : "OK"), { danger: !!opts.danger }),
  prompt: (text, def) => prompt_(text, def || "", ""),
  contextMenu: (event, items) => menu(event, items || []),
  openFile: (path, opts) => openFile(path, opts || {}),
  icons: { define: (id, svg) => defineIcon(id, svg), html: (id) => icon(id) },
};
