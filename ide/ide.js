"use strict";
// Elio IDE: Monaco + xterm.js, bridged to Swift (files, git, search, shells, agents).

// ---------- Bridge ----------
const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.elio;
const api = (op, args = {}) => native ? native.postMessage({ op, args }) : Promise.reject(new Error("fuori da Elio"));
const listeners = {};
window.__elio = { event(e) { (listeners[e.name] || []).forEach(f => { try { f(e.data); } catch (err) { console.error(err); } }); } };
const on = (name, f) => (listeners[name] = listeners[name] || []).push(f);

const $ = s => document.querySelector(s);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const basename = p => p.split("/").pop();
const dirname = p => p.slice(0, p.lastIndexOf("/"));
const store = {
  get(k, d) { try { const v = localStorage.getItem("ide." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem("ide." + k, JSON.stringify(v)); } catch {} },
};
function toast(text, ms = 2600) {
  const t = $("#toast"); t.textContent = text; t.classList.remove("hidden");
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.add("hidden"), ms);
}
function status(text) { $("#stMsg").textContent = text || ""; }

// ---------- State ----------
const S = {
  project: null,            // { name, path }
  projects: [],
  files: null,              // relative paths, for go-to-file
  git: { repo: false, branch: "", files: [] },
  gitMap: new Map(),        // relative path → status letter (M, A, U, D)
  tabs: [],                 // { path, model, view, dirty, mtime, head, saving, agentEdit }
  active: null,             // tab
  closed: [],               // reopen closed tab
  recent: [],               // absolute paths
  expanded: new Set(),
  selected: null,
  agents: [],
  panels: [],               // bottom panel tabs: { id, kind: 'shell'|'agent'|'search', title, el, term, ... }
  panel: null,
  nav: [], navIndex: -1,    // cursor history (⌘[ / ⌘])
};

// ---------- Monaco ----------
require.config({ paths: { vs: "vendor/monaco/vs" } });
window.MonacoEnvironment = { getWorkerUrl: () => "vendor/monaco/vs/base/worker/workerMain.js" };
let editor, diffEditor;

const LANG = { php: "php", js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "javascript", ts: "typescript", tsx: "typescript",
  vue: "html", html: "html", htm: "html", twig: "twig", css: "css", scss: "scss", less: "less", json: "json", md: "markdown",
  yml: "yaml", yaml: "yaml", xml: "xml", plist: "xml", svg: "xml", sql: "sql", sh: "shell", zsh: "shell", bash: "shell", py: "python",
  swift: "swift", dart: "dart", kt: "kotlin", kts: "kotlin", java: "java", go: "go", rs: "rust", rb: "ruby", c: "c", h: "c",
  m: "objective-c", cpp: "cpp", cs: "csharp", ini: "ini", env: "ini", toml: "ini", conf: "ini", graphql: "graphql", dockerfile: "dockerfile",
  lua: "lua", r: "r", scala: "scala", txt: "plaintext", lock: "json" };
function langOf(path) {
  const name = basename(path).toLowerCase();
  if (name === "dockerfile") return "dockerfile";
  if (name.endsWith(".blade.php")) return "html";
  if (name.startsWith(".env")) return "ini";
  const ext = name.includes(".") ? name.split(".").pop() : "";
  return LANG[ext] || "plaintext";
}
const ICON = { php: ["🐘", "#8892BF"], js: ["JS", "#E5C07B"], ts: ["TS", "#4F9EE8"], tsx: ["TS", "#4F9EE8"], jsx: ["JS", "#E5C07B"],
  vue: ["V", "#42B883"], css: ["#", "#6CA0DC"], scss: ["#", "#CF649A"], json: ["{}", "#E5A24F"], md: ["M", "#8C8F96"], html: ["<>", "#E06C75"],
  swift: ["S", "#F05138"], dart: ["D", "#40C4FF"], py: ["Py", "#5A9FD4"], yml: ["Y", "#CB4B16"], yaml: ["Y", "#CB4B16"], sh: ["$", "#6AAB73"],
  sql: ["DB", "#E5A24F"], env: ["⚙", "#8C8F96"], lock: ["🔒", "#8C8F96"], png: ["▣", "#B39DF0"], jpg: ["▣", "#B39DF0"], svg: ["▣", "#B39DF0"] };
function fileIcon(name, dir, open) {
  if (dir) return [open ? "▾" : "▸", "#8C8F96"];
  const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
  return ICON[ext] || ["·", "#6F737A"];
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
  setupKeys();
  editor.onDidChangeCursorPosition(e => {
    $("#stPos").textContent = `${e.position.lineNumber}:${e.position.column}`;
    rememberNav();
  });
  editor.onDidChangeModelContent(() => onEdit());
  editor.onDidBlurEditorText(() => saveActive());
  boot();
});

// ---------- Boot ----------
async function boot() {
  wireUI();
  setupSplitters();
  try { S.projects = await api("projects"); } catch (e) { S.projects = []; }
  const last = store.get("project", null);
  const proj = last && S.projects.find(p => p.path === last) || (last ? { name: basename(last), path: last } : null);
  if (proj) await openProject(proj);
  api("ready");
  // No project yet and none asked by Elio in the next moment: let the user pick one.
  setTimeout(() => { if (!S.project) renderWelcomeProjects(); }, 600);
  refreshAgents();
  setInterval(refreshGit, 15000);
}

function renderWelcomeProjects() { showPalette("projects"); }

// ---------- Projects ----------
async function openProject(p, restore = true) {
  if (S.project && S.project.path === p.path) return;
  if (S.project) saveSession();
  S.project = { name: p.name || basename(p.path), path: p.path };
  store.set("project", p.path);
  $("#projectName").textContent = S.project.name;
  api("title", { title: `${S.project.name} — Elio IDE` });
  S.tabs.forEach(t => t.model.dispose());
  S.tabs = []; S.active = null; S.files = null;
  S.expanded = new Set(store.get("expanded." + p.path, []));
  S.recent = store.get("recent." + p.path, []);
  api("watch", { root: p.path });
  await renderTree();
  await refreshGit();
  loadFiles();
  if (restore) {
    const session = store.get("session." + p.path, null);
    if (session) {
      for (const path of session.tabs || []) await openFile(path, { background: true });
      if (session.active) await openFile(session.active);
    }
  }
  renderTabs(); showEditor();
  hidePalette();
  // The first terminal opens in the project.
  if (!S.panels.some(p => p.kind === "shell")) newShell(p.path);
}
function saveSession() {
  if (!S.project) return;
  store.set("session." + S.project.path, { tabs: S.tabs.map(t => t.path), active: S.active && S.active.path });
  store.set("expanded." + S.project.path, [...S.expanded]);
  store.set("recent." + S.project.path, S.recent.slice(0, 50));
}
window.addEventListener("beforeunload", saveSession);
async function loadFiles() {
  if (!S.project) return;
  try { S.files = await api("files", { root: S.project.path }); } catch { S.files = []; }
}

// ---------- Tree ----------
const treeCache = new Map();
async function listDir(path, force) {
  if (!force && treeCache.has(path)) return treeCache.get(path);
  let items = [];
  try { items = await api("list", { path }); } catch {}
  treeCache.set(path, items);
  return items;
}
async function renderTree() {
  const root = $("#tree");
  if (!S.project) { root.innerHTML = `<div class="empty">Nessun progetto aperto.</div>`; return; }
  const frag = document.createDocumentFragment();
  const top = el("div", "row"); top.style.paddingLeft = "8px";
  top.append(el("span", "tw", "▾"), Object.assign(el("span", "ic", "▣"), { style: "color:#FFD360" }), el("span", "nm", S.project.name));
  top.querySelector(".nm").style.fontWeight = "600";
  frag.append(top);
  await renderDir(S.project.path, 1, frag);
  root.innerHTML = ""; root.append(frag);
}
async function renderDir(path, depth, into) {
  for (const it of await listDir(path)) {
    const row = el("div", "row" + (it.dim ? " dim" : ""));
    row.style.paddingLeft = (8 + depth * 14) + "px";
    const open = it.dir && S.expanded.has(it.path);
    const [ic, color] = fileIcon(it.name, it.dir, open);
    const tw = el("span", "tw", it.dir ? (open ? "▾" : "▸") : "");
    const icon = el("span", "ic", it.dir ? "" : ic); icon.style.color = color;
    if (it.dir) icon.textContent = "📁";
    row.append(tw, icon, el("span", "nm", it.name));
    const rel = relative(it.path);
    const g = it.dir ? dirGit(rel) : S.gitMap.get(rel);
    if (g) row.classList.add("g-" + g);
    if (S.selected === it.path) row.classList.add("sel");
    row.dataset.path = it.path;
    row.onclick = async () => {
      S.selected = it.path;
      if (it.dir) { S.expanded.has(it.path) ? S.expanded.delete(it.path) : S.expanded.add(it.path); await renderTree(); }
      else openFile(it.path);
      document.querySelectorAll("#tree .row.sel").forEach(r => r.classList.remove("sel")); row.classList.add("sel");
    };
    row.oncontextmenu = e => { e.preventDefault(); treeMenu(e, it); };
    into.append(row);
    if (open) await renderDir(it.path, depth + 1, into);
  }
}
function relative(p) { return S.project && p.startsWith(S.project.path + "/") ? p.slice(S.project.path.length + 1) : p; }
function dirGit(rel) {
  for (const [p, c] of S.gitMap) if (p.startsWith(rel + "/") && c !== "D") return c === "U" ? "U" : "M";
  return null;
}
async function revealInTree(path) {
  if (!S.project || !path.startsWith(S.project.path)) return;
  let d = dirname(path);
  while (d.length > S.project.path.length) { S.expanded.add(d); d = dirname(d); }
  S.selected = path;
  setSide("project");
  await renderTree();
  const row = [...document.querySelectorAll("#tree .row")].find(r => r.dataset.path === path);
  if (row) row.scrollIntoView({ block: "center" });
}
function treeMenu(e, it) {
  const dir = it.dir ? it.path : dirname(it.path);
  menu(e, [
    ["Nuovo file…", () => createEntry(dir, false), "⌘N"],
    ["Nuova cartella…", () => createEntry(dir, true)],
    null,
    !it.dir && ["Apri", () => openFile(it.path)],
    ["Rinomina…", () => renameEntry(it)],
    ["Sposta nel Cestino", () => trashEntry(it)],
    null,
    ["Copia percorso", () => copy(it.path)],
    ["Copia percorso relativo", () => copy(relative(it.path))],
    ["Mostra nel Finder", () => api("reveal", { path: it.path })],
    ["Apri in PhpStorm", () => api("openExternal", { path: it.path, app: "PhpStorm" })],
    ["Apri terminale qui", () => newShell(dir)],
    ["Cerca in questa cartella…", () => openSearch("", relative(dir))],
    null,
    ["Chiedi a Elio su questo…", () => askElio(`Riguardo a ${it.path}: `)],
  ]);
}
async function createEntry(dir, isDir) {
  const name = await prompt_(isDir ? "Nuova cartella" : "Nuovo file", "", isDir ? "nome-cartella" : "NomeFile.php");
  if (!name) return;
  const path = dir + "/" + name;
  try {
    await api("create", { path, dir: isDir });
    treeCache.delete(dir); S.expanded.add(dir);
    await renderTree();
    if (!isDir) openFile(path);
  } catch (e) { toast("Non riesco a crearlo: " + e.message); }
}
async function renameEntry(it) {
  const name = await prompt_("Rinomina", it.name, it.name);
  if (!name || name === it.name) return;
  const to = dirname(it.path) + "/" + name;
  try {
    await api("rename", { from: it.path, to });
    treeCache.delete(dirname(it.path));
    const tab = S.tabs.find(t => t.path === it.path);
    if (tab) { tab.path = to; renderTabs(); }
    await renderTree();
  } catch (e) { toast("Non riesco a rinominarlo: " + e.message); }
}
async function trashEntry(it) {
  if (!(await confirm_(`Sposto nel Cestino ${it.name}?`, "Lo puoi recuperare dal Cestino.", "Sposta"))) return;
  try {
    await api("trash", { path: it.path });
    treeCache.delete(dirname(it.path));
    S.tabs.filter(t => t.path === it.path || t.path.startsWith(it.path + "/")).forEach(closeTab);
    await renderTree();
  } catch (e) { toast("Non riesco: " + e.message); }
}

// ---------- Tabs & editor ----------
async function openFile(path, opts = {}) {
  let tab = S.tabs.find(t => t.path === path);
  if (!tab) {
    let r;
    try { r = await api("read", { path }); } catch (e) { toast(e.message || String(e)); return; }
    if (r.binary) { api("openExternal", { path }); return; }
    const uri = monaco.Uri.file(path);
    const model = monaco.editor.getModel(uri) || monaco.editor.createModel(r.content, langOf(path), uri);
    model.updateOptions({ tabSize: guessIndent(r.content) });
    tab = { path, model, view: null, dirty: false, mtime: r.mtime, head: null };
    model._tab = tab;
    S.tabs.push(tab);
    loadHead(tab);
  }
  if (!opts.background) {
    activate(tab);
    if (opts.line) {
      editor.revealLineInCenter(opts.line);
      editor.setPosition({ lineNumber: opts.line, column: opts.col || 1 });
      if (opts.highlight) flashLine(opts.line);
    }
    editor.focus();
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
  if (tab.view) editor.restoreViewState(tab.view);
  S.recent = [tab.path, ...S.recent.filter(p => p !== tab.path)].slice(0, 50);
  $("#stLang").textContent = tab.model.getLanguageId();
  $("#stIndent").textContent = `${tab.model.getOptions().tabSize} spazi`;
  renderCrumbs(); showEditor(); decorate(tab);
  if (tab.agentEdit) { tab.agentEdit = false; }
}
function showEditor() { $("#welcome").classList.toggle("hidden", !!S.active); }
function renderTabs() {
  const bar = $("#tabs"); bar.innerHTML = "";
  for (const t of S.tabs) {
    const g = S.gitMap.get(relative(t.path));
    const tab = el("div", "tab" + (t === S.active ? " on" : "") + (t.dirty ? " dirty" : "") + (g ? " g-" + g : ""));
    const [ic, color] = fileIcon(basename(t.path), false);
    const icon = el("span", "", ic); icon.style.color = color; icon.style.fontSize = "10.5px";
    tab.append(icon, el("span", "nm", basename(t.path)));
    if (t.agentEdit) tab.append(el("span", "badge", "AGENTE"));
    const x = el("span", "x", "✕"); x.onclick = e => { e.stopPropagation(); closeTab(t); };
    tab.append(x);
    tab.onclick = () => { activate(t); renderTabs(); editor.focus(); };
    tab.onauxclick = e => { if (e.button === 1) closeTab(t); };
    tab.oncontextmenu = e => { e.preventDefault(); menu(e, [
      ["Chiudi", () => closeTab(t), "⌘W"], ["Chiudi le altre", () => S.tabs.filter(o => o !== t).forEach(closeTab)],
      ["Chiudi tutte", () => [...S.tabs].forEach(closeTab)], null,
      ["Mostra nell'albero", () => revealInTree(t.path)], ["Copia percorso", () => copy(t.path)],
      ["Mostra le modifiche (diff)", () => showDiff(t.path)],
    ]); };
    bar.append(tab);
    if (t === S.active) setTimeout(() => tab.scrollIntoView({ inline: "nearest" }), 0);
  }
  saveSession();
}
function renderCrumbs() {
  const c = $("#crumbs"); c.innerHTML = "";
  if (!S.active) return;
  const parts = relative(S.active.path).split("/");
  parts.forEach((p, i) => { if (i) c.append(el("span", "sep", "›")); c.append(el("span", "", p)); });
}
async function closeTab(t) {
  if (t.dirty) await save(t);
  const i = S.tabs.indexOf(t);
  if (i < 0) return;
  S.tabs.splice(i, 1);
  S.closed.push(t.path);
  t.model.dispose();
  if (S.active === t) {
    S.active = null;
    const next = S.tabs[i] || S.tabs[i - 1];
    if (next) activate(next); else { editor.setModel(null); renderCrumbs(); showEditor(); }
  }
  renderTabs();
}

// ---------- Saving (autosave like PHPStorm) ----------
let saveTimer;
function onEdit() {
  const t = S.active;
  if (!t || t.suppress) return;
  if (!t.dirty) { t.dirty = true; renderTabs(); }
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => save(t), 1200);
  clearTimeout(t._decor); t._decor = setTimeout(() => decorate(t), 400);
}
function saveActive() { if (S.active && S.active.dirty) save(S.active); }
async function saveAll() { for (const t of S.tabs) if (t.dirty) await save(t); toast("Tutto salvato"); }
async function save(t) {
  if (!t.dirty || t.saving) return;
  t.saving = true; $("#stSave").textContent = "Salvo…"; $("#stSave").classList.add("saving");
  try {
    const r = await api("write", { path: t.path, content: t.model.getValue() });
    t.mtime = r.mtime; t.dirty = false;
    $("#stSave").textContent = "Salvato"; refreshGitSoon();
  } catch (e) { toast("Salvataggio non riuscito: " + e.message); $("#stSave").textContent = "Errore di salvataggio"; }
  t.saving = false; $("#stSave").classList.remove("saving");
  renderTabs();
}

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
  for (const t of S.tabs) {
    if (!paths.includes(t.path)) continue;
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
      if (t === S.active) { status(`${basename(t.path)} aggiornato su disco`); decorate(t); }
      renderTabs();
    }
  }
  if (treeDirty) renderTree();
  refreshGitSoon();
  if (paths.some(p => !S.files || !S.files.includes(relative(p)))) loadFiles();
}
function showBanner(t, r) {
  const b = $("#banner"); b.classList.remove("hidden"); b.innerHTML = "";
  b.append(el("span", "", `${basename(t.path)} è cambiato su disco mentre lo stavi modificando.`));
  const reload = el("button", "", "Ricarica dal disco"), keep = el("button", "", "Tieni la mia versione");
  reload.onclick = () => { t.suppress = true; t.model.setValue(r.content); t.suppress = false; t.dirty = false; t.mtime = r.mtime; b.classList.add("hidden"); renderTabs(); };
  keep.onclick = () => { b.classList.add("hidden"); save(t); };
  b.append(reload, keep);
}

// ---------- Git ----------
let gitTimer;
function refreshGitSoon() { clearTimeout(gitTimer); gitTimer = setTimeout(refreshGit, 500); }
async function refreshGit() {
  if (!S.project) return;
  let g; try { g = await api("git", { root: S.project.path, cmd: "status" }); } catch { return; }
  S.git = g; S.gitMap = new Map();
  for (const f of g.files || []) {
    const c = f.code.includes("?") ? "U" : f.code.includes("D") ? "D" : f.code.includes("A") ? "A" : "M";
    S.gitMap.set(f.path, c);
  }
  const branch = g.repo ? g.branch + (g.ahead ? ` ↑${g.ahead}` : "") + (g.behind ? ` ↓${g.behind}` : "") : "nessun repository";
  $("#branchName").textContent = g.repo ? g.branch : "—";
  $("#stBranch").textContent = "⎇ " + branch;
  $("#changesCount").textContent = g.files && g.files.length ? g.files.length : "";
  renderChanges(); renderTabs();
  document.querySelectorAll("#tree .row").forEach(r => {
    if (!r.dataset.path) return;
    r.classList.remove("g-M", "g-A", "g-U", "g-D");
    const rel = relative(r.dataset.path);
    const c = S.gitMap.get(rel) || dirGit(rel);
    if (c) r.classList.add("g-" + c);
  });
}
function renderChanges() {
  const box = $("#changes"); box.innerHTML = "";
  if (!S.git.repo) { box.innerHTML = `<div class="empty">Non è un repository git.</div>`; return; }
  const head = el("div", "sect"); head.append(el("span", "", `Modifiche (${(S.git.files || []).length})`));
  const commitB = el("button", "", "Commit…"); commitB.onclick = () => commitDialog(); head.append(commitB);
  box.append(head);
  if (!(S.git.files || []).length) box.append(el("div", "empty", "Nessuna modifica. Il branch è pulito."));
  for (const f of S.git.files || []) {
    const c = S.gitMap.get(f.path);
    const row = el("div", "chg");
    const code = el("span", "code " + c, c === "U" ? "?" : c);
    row.append(code, el("span", "p", basename(f.path)), el("span", "dir", dirname(f.path)));
    row.onclick = () => c === "D" ? null : showDiff(S.project.path + "/" + f.path);
    row.ondblclick = () => openFile(S.project.path + "/" + f.path);
    row.oncontextmenu = e => { e.preventDefault(); menu(e, [
      ["Mostra diff", () => showDiff(S.project.path + "/" + f.path)], ["Apri", () => openFile(S.project.path + "/" + f.path)],
      null, ["Annulla le modifiche (rollback)…", () => rollback(f.path)],
    ]); };
    box.append(row);
  }
  const logHead = el("div", "sect"); logHead.append(el("span", "", "Ultimi commit"));
  box.append(logHead);
  api("git", { root: S.project.path, cmd: "log" }).then(r => {
    for (const c of (r.commits || []).slice(0, 15)) {
      const row = el("div", "chg"); row.title = `${c.hash} · ${c.author} · ${c.when}`;
      const h = el("span", "code", c.hash.slice(0, 4)); h.style.color = "var(--faint)"; h.style.width = "34px";
      row.append(h, el("span", "p", c.subject), el("span", "dir", c.when));
      box.append(row);
    }
  }).catch(() => {});
}
async function rollback(rel) {
  if (!(await confirm_(`Annullo le modifiche a ${basename(rel)}?`, "Il file torna com'è nell'ultimo commit. Non si può annullare.", "Rollback"))) return;
  const r = await api("git", { root: S.project.path, cmd: "rollback", args: [rel] });
  if (!r.ok) toast(r.output); else refreshGit();
}
async function loadHead(tab) {
  if (!S.project || !tab.path.startsWith(S.project.path)) return;
  try {
    const r = await api("git", { root: S.project.path, cmd: "show", args: [relative(tab.path)] });
    tab.head = r.exists ? r.content : null;
    tab.isNew = !r.exists;
    if (tab === S.active) decorate(tab);
  } catch {}
}
// Gutter markers vs HEAD (green added, blue modified, red deleted), like PHPStorm.
function decorate(tab) {
  if (tab !== S.active || !editor) return;
  const lines = tab.model.getLinesContent();
  const decos = [];
  if (tab.isNew && S.gitMap.has(relative(tab.path))) {
    decos.push({ range: new monaco.Range(1, 1, lines.length, 1), options: { isWholeLine: true, linesDecorationsClassName: "gm-add" } });
  } else if (tab.head != null) {
    for (const ch of lineDiff(tab.head.split("\n"), lines)) {
      const cls = ch.type === "add" ? "gm-add" : ch.type === "mod" ? "gm-mod" : "gm-del";
      const start = Math.max(1, ch.start), end = Math.max(start, ch.end);
      decos.push({ range: new monaco.Range(start, 1, end, 1), options: { isWholeLine: true, linesDecorationsClassName: cls,
        overviewRuler: { color: ch.type === "add" ? "#6AAB73" : ch.type === "mod" ? "#6C9BD2" : "#E06C75", position: 1 } } });
    }
  }
  tab.decos = editor.deltaDecorations(tab.decos || [], decos);
}
// Myers diff on lines → changed ranges in the new text (1-based).
function lineDiff(a, b) {
  if (a.length + b.length > 40000) return [];
  const n = a.length, m = b.length, max = n + m, off = max;
  const v = new Int32Array(2 * max + 2), trace = [];
  let found = false;
  for (let d = 0; d <= max && d <= 3000; d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x = (k === -d || (k !== d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) { x++; y++; }
      v[off + k] = x;
      if (x >= n && y >= m) { found = true; break; }
    }
    if (found) break;
  }
  if (!found) return [];
  // Backtrack into edit ops.
  const ops = [];
  let x = n, y = m;
  for (let d = trace.length - 1; d >= 0 && (x > 0 || y > 0); d--) {
    const vv = trace[d], k = x - y;
    const prevK = (k === -d || (k !== d && vv[off + k - 1] < vv[off + k + 1])) ? k + 1 : k - 1;
    const px = vv[off + prevK], py = px - prevK;
    while (x > px && y > py) { x--; y--; }
    if (d > 0) { if (x === px) ops.push({ t: "ins", y: py }); else ops.push({ t: "del", y }); }
    x = px; y = py;
  }
  ops.reverse();
  // Group into ranges: inserted lines (add), deleted+inserted at same spot (mod), pure deletes (del).
  const ins = new Set(ops.filter(o => o.t === "ins").map(o => o.y));
  const delAt = new Map(); ops.filter(o => o.t === "del").forEach(o => delAt.set(o.y, (delAt.get(o.y) || 0) + 1));
  const out = [];
  let i = 0;
  const sorted = [...ins].sort((p, q) => p - q);
  while (i < sorted.length) {
    let s = sorted[i], e = s;
    while (i + 1 < sorted.length && sorted[i + 1] === e + 1) { i++; e = sorted[i]; }
    let mod = false;
    for (let yy = s; yy <= e + 1; yy++) if (delAt.has(yy)) { mod = true; delAt.delete(yy); }
    out.push({ type: mod ? "mod" : "add", start: s + 1, end: e + 1 });
    i++;
  }
  for (const [yy] of delAt) out.push({ type: "del", start: yy, end: yy });
  return out;
}
async function showDiff(path) {
  if (!S.project) return;
  let current = "";
  const tab = S.tabs.find(t => t.path === path);
  if (tab) current = tab.model.getValue(); else { try { current = (await api("read", { path })).content || ""; } catch {} }
  const r = await api("git", { root: S.project.path, cmd: "show", args: [relative(path)] });
  const orig = monaco.editor.createModel(r.content || "", langOf(path));
  const mod = tab ? tab.model : monaco.editor.createModel(current, langOf(path));
  diffEditor.setModel({ original: orig, modified: mod });
  $("#diffEditor").classList.remove("hidden"); $("#editor").classList.add("hidden");
  $("#welcome").classList.add("hidden");
  const c = $("#crumbs"); c.innerHTML = ""; c.append(el("span", "", `Diff · ${relative(path)} (HEAD ↔ ora)`));
  const back = el("span", "", "  ✕ chiudi diff"); back.style.color = "var(--accent)"; back.onclick = hideDiff; c.append(back);
}
function hideDiff() {
  if ($("#diffEditor").classList.contains("hidden")) return;
  $("#diffEditor").classList.add("hidden"); $("#editor").classList.remove("hidden");
  renderCrumbs(); showEditor();
}
async function commitDialog() {
  if (!S.project || !S.git.repo) { toast("Non è un repository git."); return; }
  await saveAllQuiet(); await refreshGit();
  const files = S.git.files || [];
  if (!files.length) { toast("Niente da committare."); return; }
  const body = $("#dlgBody"); body.innerHTML = "";
  body.append(el("h3", "", `Commit su ${S.git.branch}`));
  const list = el("div", "files");
  for (const f of files) {
    const l = el("label"); const cb = el("input"); cb.type = "checkbox"; cb.checked = true; cb.value = f.path;
    l.append(cb, el("span", "", f.path)); list.append(l);
  }
  const msg = el("textarea"); msg.rows = 4; msg.placeholder = "Messaggio del commit";
  msg.value = store.get("commitDraft." + S.project.path, "");
  const btns = el("div", "row-btn");
  const cancel = el("button", "btn", "Annulla"), commit = el("button", "btn go", "Commit"), push = el("button", "btn", "Commit e push…");
  btns.append(cancel, push, commit);
  body.append(list, msg, btns);
  $("#dialog").classList.remove("hidden"); msg.focus();
  const close = () => { store.set("commitDraft." + S.project.path, msg.value); $("#dialog").classList.add("hidden"); editor.focus(); };
  cancel.onclick = close;
  const run = async withPush => {
    if (!msg.value.trim()) { msg.focus(); return; }
    const paths = [...list.querySelectorAll("input:checked")].map(c => c.value);
    const r = await api("git", { root: S.project.path, cmd: "commit", args: [msg.value.trim(), ...(paths.length === files.length ? [] : paths)] });
    if (!r.ok) { toast("Commit non riuscito: " + r.output.slice(0, 200), 6000); return; }
    store.set("commitDraft." + S.project.path, "");
    $("#dialog").classList.add("hidden");
    toast("Commit fatto");
    if (withPush) await pushNow();
    refreshGit(); S.tabs.forEach(loadHead);
  };
  commit.onclick = () => run(false);
  push.onclick = () => run(true);
  msg.onkeydown = e => { if (e.key === "Enter" && e.metaKey) run(e.shiftKey); if (e.key === "Escape") close(); };
}
async function pushNow() {
  if (!(await confirm_(`Push di ${S.git.branch}?`, "I commit vanno sul server remoto.", "Push"))) return;
  status("Push in corso…");
  const r = await api("git", { root: S.project.path, cmd: "push" });
  status(""); toast(r.ok ? "Push fatto" : "Push non riuscito: " + r.output.slice(0, 240), r.ok ? 2500 : 7000);
  refreshGit();
}
async function saveAllQuiet() { for (const t of S.tabs) if (t.dirty) await save(t); }

// ---------- Search everywhere / go to / recent / actions ----------
let pal = { mode: "all", items: [], index: 0 };
const ACTIONS = [
  ["Cerca nel progetto", "⌘⇧F", () => openSearch()], ["Vai a file", "⌘⇧O", () => showPalette("file")],
  ["File recenti", "⌘E", () => showPalette("recent")], ["Vai alla riga", "⌘L", () => showPalette("line")],
  ["Struttura del file", "⌘F12", () => editor.getAction("editor.action.quickOutline")?.run()],
  ["Nuovo terminale", "⌥F12", () => newShell()], ["Commit", "⌘K", () => commitDialog()], ["Push", "⌘⇧K", () => pushNow()],
  ["Pull", "", async () => { const r = await api("git", { root: S.project.path, cmd: "pull" }); toast(r.ok ? "Aggiornato" : r.output.slice(0, 200)); refreshGit(); }],
  ["Cambia branch", "", () => showPalette("branches")], ["Cambia progetto", "", () => showPalette("projects")],
  ["Mostra diff del file", "", () => S.active && showDiff(S.active.path)], ["Riformatta il codice", "⌘⌥L", () => editor.getAction("editor.action.formatDocument")?.run()],
  ["Salva tutto", "⌘S", () => saveAll()], ["Chiudi tutte le tab", "", () => [...S.tabs].forEach(closeTab)],
  ["Mostra nell'albero", "⌥F1", () => S.active && revealInTree(S.active.path)], ["Riapri tab chiusa", "⌘⇧T", () => reopenTab()],
  ["Chiedi a Elio", "⌘⌥E", () => askElioSelection()],
  ["Aggiorna Elio con le modifiche al suo codice", "", () => { api("askElio", { text: "Aggiornati con le modifiche fatte al tuo codice (self_update)." }); toast("Elio prepara l'aggiornamento"); }], ["Delega a un agente", "", () => delegateSelection()],
  ["Apri in PhpStorm", "", () => S.active && api("openExternal", { path: S.active.path, app: "PhpStorm" })],
  ["Mostra nel Finder", "", () => api("reveal", { path: S.active ? S.active.path : S.project.path })],
  ["Mostra/nascondi pannello in basso", "⌘J", () => togglePanel()], ["Mostra/nascondi barra laterale", "⌘1", () => toggleSide()],
  ["Maiuscole / minuscole", "⌘⇧U", () => toggleCase()], ["Duplica riga", "⌘D", () => editor.trigger("k", "editor.action.copyLinesDownAction")],
  ["Cancella riga", "⌘⌫", () => editor.trigger("k", "editor.action.deleteLines")], ["Commenta", "⌘/", () => editor.trigger("k", "editor.action.commentLine")],
  ["Copia percorso del file", "", () => S.active && copy(S.active.path)], ["Copia percorso relativo", "", () => S.active && copy(relative(S.active.path))],
  ["Zoom testo +", "⌘=", () => zoom(1)], ["Zoom testo −", "⌘-", () => zoom(-1)], ["Mappa del codice (minimap)", "", () => editor.updateOptions({ minimap: { enabled: !editor.getOption(monaco.editor.EditorOption.minimap).enabled } })],
  ["A capo automatico", "⌥Z", () => editor.updateOptions({ wordWrap: editor.getOption(monaco.editor.EditorOption.wordWrap) === "on" ? "off" : "on" })],
];
function showPalette(mode, initial = "") {
  pal = { mode, items: [], index: 0 };
  const titles = { all: "Cerca ovunque", file: "Vai a file", recent: "File recenti", action: "Azioni", line: "Vai alla riga",
    projects: "Progetti", branches: "Branch" };
  $("#palTitle").textContent = titles[mode];
  $("#palHint").textContent = mode === "all" ? "file · azioni · ⇧⇧" : mode === "line" ? "riga[:colonna]" : "↑↓ invio";
  $("#palInput").value = initial;
  $("#palInput").placeholder = mode === "line" ? "Es. 120 o 120:8" : "Scrivi per cercare…";
  $("#palette").classList.remove("hidden");
  $("#palInput").focus();
  updatePalette();
  if (mode === "branches") api("git", { root: S.project.path, cmd: "branches" }).then(r => { pal.branches = r.branches || []; updatePalette(); });
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
  const fileItem = rel => ({ kind: "file", label: basename(rel), sub: dirname(rel), run: () => openFile(S.project.path + "/" + rel), q });
  if (pal.mode === "line") {
    items.push({ label: q ? `Vai alla riga ${q}` : "Scrivi un numero di riga", run: () => {
      const [l, c] = q.split(":").map(Number); if (l) { editor.setPosition({ lineNumber: l, column: c || 1 }); editor.revealLineInCenter(l); }
    } });
  } else if (pal.mode === "projects") {
    for (const p of S.projects.map(p => ({ p, s: fuzzy(q, p.name) })).filter(x => x.s > 0).sort((a, b) => b.s - a.s).slice(0, 60))
      items.push({ kind: "proj", label: p.p.name, sub: p.p.path.replace(/^\/Users\/[^/]+/, "~"), run: () => openProject(p.p), q });
  } else if (pal.mode === "branches") {
    for (const b of (pal.branches || []).filter(b => fuzzy(q, b) > 0))
      items.push({ kind: "branch", label: b, sub: b === S.git.branch ? "attuale" : "", run: async () => {
        await saveAllQuiet();
        const r = await api("git", { root: S.project.path, cmd: "checkout", args: [b] });
        toast(r.ok ? `Su ${b}` : r.output.slice(0, 200)); refreshGit();
      }, q });
  } else if (pal.mode === "recent") {
    for (const p of S.recent.filter(p => fuzzy(q, relative(p)) > 0).slice(0, 40)) items.push({ ...fileItem(relative(p)) });
  } else {
    if (pal.mode === "all" || pal.mode === "action") {
      const acts = ACTIONS.map(a => ({ a, s: fuzzy(q, a[0]) })).filter(x => q ? x.s > 0 : pal.mode === "action").sort((a, b) => b.s - a.s)
        .slice(0, pal.mode === "action" ? 40 : 5);
      if (acts.length && pal.mode === "all") items.push({ sect: "Azioni" });
      acts.forEach(x => items.push({ kind: "action", label: x.a[0], kb: x.a[1], run: x.a[2], q }));
    }
    if (pal.mode === "all" || pal.mode === "file") {
      const files = S.files || [];
      let ranked;
      if (!q) ranked = S.recent.map(relative).slice(0, 20).map(f => ({ f, s: 1 }));
      else ranked = files.map(f => ({ f, s: fuzzy(q, f) })).filter(x => x.s > 0).sort((a, b) => b.s - a.s).slice(0, 50);
      if (ranked.length && pal.mode === "all") items.push({ sect: q ? "File" : "Recenti" });
      ranked.forEach(x => items.push(fileItem(x.f)));
      if (!S.files) items.push({ sect: "Indicizzo i file…" });
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
    const [ic, color] = it.kind === "file" ? fileIcon(it.label, false) : it.kind === "action" ? ["›", "#FFD360"] : it.kind === "proj" ? ["▣", "#FFD360"] : ["⎇", "#8C8F96"];
    const icon = el("span", "ic", ic); icon.style.color = color;
    const t = el("span", "t"); t.append(highlight(it.q, it.label));
    row.append(icon, t);
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

// ---------- Find in path ----------
function openSearch(initial, scope) {
  let p = S.panels.find(x => x.kind === "search");
  if (!p) {
    const pane = el("div", "pane");
    const bar = el("div", "search-bar");
    const input = el("input"); input.placeholder = "Cerca nel progetto…  (Invio)";
    const scopeIn = el("input"); scopeIn.placeholder = "cartella (opzionale)"; scopeIn.style.maxWidth = "200px";
    const rx = el("button", "opt", ".*"), cs = el("button", "opt", "Aa"), count = el("span", "count", "");
    rx.title = "Espressione regolare"; cs.title = "Maiuscole/minuscole";
    rx.onclick = () => { rx.classList.toggle("on"); run(); }; cs.onclick = () => { cs.classList.toggle("on"); run(); };
    bar.append(input, scopeIn, rx, cs, count);
    const results = el("div", "results");
    pane.append(bar, results);
    p = { id: "search", kind: "search", title: "Cerca", el: pane, input, scopeIn };
    let seq = 0;
    async function run() {
      const q = input.value; if (!q || !S.project) return;
      const my = ++seq; count.textContent = "cerco…";
      const root = scopeIn.value.trim() ? S.project.path + "/" + scopeIn.value.trim().replace(/^\/+/, "") : S.project.path;
      const r = await api("search", { root, query: q, regex: rx.classList.contains("on"), case: cs.classList.contains("on") });
      if (my !== seq) return;
      results.innerHTML = "";
      count.textContent = `${r.length}${r.length >= 800 ? "+" : ""} risultati`;
      let last = null;
      const base = root === S.project.path ? "" : scopeIn.value.trim().replace(/^\/+|\/+$/g, "") + "/";
      for (const m of r) {
        const rel = base + m.file;
        if (rel !== last) {
          last = rel;
          const head = el("div", "res-file"); head.append(el("span", "", basename(rel)), el("span", "dir", dirname(rel)));
          results.append(head);
        }
        const line = el("div", "res-line"); line.append(el("span", "n", m.line));
        const text = el("span", ""); const t = m.text.trimStart();
        const idx = rx.classList.contains("on") ? -1 : (cs.classList.contains("on") ? t.indexOf(q) : t.toLowerCase().indexOf(q.toLowerCase()));
        if (idx >= 0) { text.append(t.slice(0, idx), el("mark", "", t.slice(idx, idx + q.length)), t.slice(idx + q.length)); } else text.textContent = t;
        line.append(text);
        line.onclick = () => openFile(S.project.path + "/" + rel, { line: m.line, col: m.col, highlight: true });
        results.append(line);
      }
      if (!r.length) results.append(el("div", "empty", "Nessun risultato."));
    }
    input.onkeydown = e => { if (e.key === "Enter") run(); if (e.key === "Escape") editor.focus(); };
    scopeIn.onkeydown = e => { if (e.key === "Enter") run(); };
    p.run = run;
    addPanel(p);
  }
  if (initial != null && initial !== "") p.input.value = initial;
  if (scope != null) p.scopeIn.value = scope;
  showPanel(p);
  setTimeout(() => { p.input.focus(); p.input.select(); if (initial) p.run(); }, 30);
}

// ---------- Bottom panel: terminals, agents, search ----------
const TERM_THEME = { background: "#1E1F22", foreground: "#BCBEC4", cursor: "#CED0D6", selectionBackground: "#214283",
  black: "#1E1F22", red: "#E06C75", green: "#6AAB73", yellow: "#E5C07B", blue: "#6C9BD2", magenta: "#C77DBB", cyan: "#2AACB8", white: "#BCBEC4",
  brightBlack: "#6F737A", brightRed: "#F28B82", brightGreen: "#89CA78", brightYellow: "#FFD360", brightBlue: "#8AB4F8", brightMagenta: "#D7A9E3",
  brightCyan: "#56D4DD", brightWhite: "#FFFFFF" };
function makeTerm(readOnly) {
  // Nerd Font variants first: prompts like powerlevel10k / starship use their icons.
  const term = new Terminal({ fontFamily: "MesloLGS NF, MesloLGS Nerd Font, JetBrainsMono Nerd Font, Hack Nerd Font, FiraCode Nerd Font, JetBrains Mono, SF Mono, Menlo, monospace", fontSize: 12.5, lineHeight: 1.15, theme: TERM_THEME,
    cursorBlink: !readOnly, scrollback: 10000, allowProposedApi: true, macOptionIsMeta: true, disableStdin: readOnly, convertEol: readOnly });
  const fit = new FitAddon.FitAddon(); term.loadAddon(fit);
  try { term.loadAddon(new WebLinksAddon.WebLinksAddon()); } catch {}
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
  p.term.write(`\r\n\x1b[90m[processo terminato (${d.code}) — premi un tasto per riaprire]\x1b[0m\r\n`);
  p.dead = true;
});
let shellCount = 0;
async function newShell(cwd, command) {
  const dir = cwd || (S.project && S.project.path) || "";
  const pane = el("div", "pane"); const box = el("div", "term"); pane.append(box);
  const { term, fit } = makeTerm(false);
  const p = { id: "sh" + (++shellCount), kind: "shell", title: command ? command.split(" ")[0] : `Locale${shellCount > 1 ? " " + shellCount : ""}`,
    el: pane, term, fit, cwd: dir };
  addPanel(p); showPanel(p);
  term.open(box);
  await new Promise(r => setTimeout(r, 30));
  try { fit.fit(); } catch {}
  const start = async () => {
    const r = await api("ptyCreate", { cwd: dir, cols: term.cols, rows: term.rows, command });
    p.pty = r.id; p.dead = false; ptyPanels.set(r.id, p);
  };
  await start();
  term.onData(data => {
    if (p.dead) { term.clear(); start(); return; }
    const bytes = new TextEncoder().encode(data); let bin = ""; bytes.forEach(b => bin += String.fromCharCode(b));
    api("ptyWrite", { id: p.pty, data: btoa(bin) });
  });
  term.onResize(({ cols, rows }) => p.pty && api("ptyResize", { id: p.pty, cols, rows }));
  term.attachCustomKeyEventHandler(e => {
    // ⌘K clears like Terminal; IDE shortcuts keep working from the terminal.
    if (e.type === "keydown" && e.metaKey && e.key === "k") { term.clear(); return false; }
    return !(e.metaKey && ["e", "o", "p", "j", "1", "0", "w", "t"].includes(e.key.toLowerCase()));
  });
  term.focus();
  return p;
}
function addPanel(p) {
  S.panels.push(p);
  $("#panelBody").append(p.el);
  renderPanelTabs();
}
function showPanel(p) {
  S.panel = p;
  $("#panel").classList.remove("collapsed");
  S.panels.forEach(x => x.el.classList.toggle("on", x === p));
  renderPanelTabs();
  if (p.fit) setTimeout(() => { try { p.fit.fit(); } catch {} p.term && p.kind === "shell" && p.term.focus(); }, 20);
  if (p.kind === "agent") setTimeout(() => p.input && p.input.focus(), 20);
}
function closePanel(p) {
  if (p.pty) api("ptyKill", { id: p.pty });
  if (p.term) p.term.dispose();
  p.el.remove();
  S.panels = S.panels.filter(x => x !== p);
  if (S.panel === p) { const next = S.panels[S.panels.length - 1]; if (next) showPanel(next); else S.panel = null; }
  renderPanelTabs();
}
function renderPanelTabs() {
  const bar = $("#panelTabs"); bar.innerHTML = "";
  for (const p of S.panels) {
    const t = el("div", "ptab" + (p === S.panel ? " on" : ""));
    if (p.kind === "agent") { const a = S.agents.find(a => a.id === p.agentId); t.append(el("span", "st " + (a ? a.status : ""))); }
    t.append(el("span", "", p.kind === "shell" ? "▸ " + p.title : p.kind === "search" ? "⌕ Cerca" : p.title));
    const x = el("span", "x", "✕"); x.onclick = e => { e.stopPropagation(); closePanel(p); };
    t.append(x);
    t.onclick = () => showPanel(p);
    bar.append(t);
  }
  const add = el("div", "ptab add", "+ Terminale"); add.onclick = () => newShell(); add.title = "Nuovo terminale (⌥F12)";
  bar.append(add);
}
function togglePanel() { $("#panel").classList.toggle("collapsed"); if (!$("#panel").classList.contains("collapsed") && S.panel && S.panel.fit) setTimeout(() => S.panel.fit.fit(), 20); }

// Agents: each one has its terminal (what it does, live) and you can write to it.
on("agents", list => { S.agents = list || []; renderAgents(); });
on("agentLog", d => { const p = S.panels.find(x => x.kind === "agent" && x.agentId === d.id); if (p) d.entries.forEach(e => writeLog(p, e)); });
on("openAgent", d => openAgent(d.agent));
on("open", async d => {
  if (!d.path) return;
  const proj = S.projects.find(p => d.path === p.path || d.path.startsWith(p.path + "/"));
  if (proj) await openProject(proj, true);
  else if (!S.project || !d.path.startsWith(S.project.path)) await openProject({ name: basename(d.path), path: d.path });
  if (d.path !== (S.project && S.project.path)) {
    try { const r = await api("list", { path: d.path }); if (Array.isArray(r)) return; } catch {}
    openFile(d.path, { line: d.line || 0, highlight: !!d.line });
  }
});
async function refreshAgents() { try { S.agents = await api("agents"); } catch { S.agents = []; } renderAgents(); }
function renderAgents() {
  const running = S.agents.filter(a => ["running", "waitingConfirmation", "paused"].includes(a.status));
  $("#agentsCount").textContent = running.length ? `${running.length} al lavoro` : `${S.agents.length} agenti`;
  $("#stAgents").textContent = running.length ? `◉ ${running.length} agenti al lavoro` : "";
  const box = $("#agentsList"); box.innerHTML = "";
  if (!S.agents.length) { box.append(el("div", "empty", "Nessun agente. Chiedi a Elio di avviarne uno.")); }
  for (const a of S.agents) {
    const row = el("div", "agent");
    const top = el("div", "top"); top.append(el("span", "st " + a.status), el("span", "nm", a.member || a.title));
    row.append(top, el("div", "now", a.now || a.status));
    row.append(el("div", "meta", `${a.project || ""}${a.progress ? ` · passo ${Math.min(a.progress[0] + 1, a.progress[1])}/${a.progress[1]}` : ""}${a.model && !a.model.includes("opus") ? " · " + a.model : ""}`));
    row.onclick = () => openAgent(a.id);
    box.append(row);
  }
  S.panels.filter(p => p.kind === "agent").forEach(updateAgentHead);
  renderPanelTabs();
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
  const h = p.head; h.textContent = "";
  const dot = el("span", ""); dot.style.cssText = `width:8px;height:8px;border-radius:50%;flex:none;background:${a.status === "running" ? "#6AAB73" : a.status === "waitingConfirmation" ? "#E5A24F" : a.status === "failed" ? "#E06C75" : "#FFD360"}`;
  h.append(dot, el("b", "", a.member || a.title), el("span", "now", a.now || ""));
  h.innerHTML = ""; h.append(dot, el("b", "", a.member || a.title), el("span", "now", a.now || ""));
  if (a.progress) { const bar = el("span", "bar"); const i = el("i"); i.style.width = (100 * a.progress[0] / a.progress[1]) + "%"; bar.append(i); h.append(bar); }
  const btn = (label, title, f) => { const b = el("button", "", label); b.title = title; b.onclick = f; h.append(b); };
  if (a.cwd) {
    btn("📂", "Apri la sua cartella", () => openProject({ name: basename(a.cwd), path: a.cwd }));
    btn("▸ shell", "Terminale nella sua cartella", () => newShell(a.cwd));
  }
  if (["running", "waitingConfirmation"].includes(a.status)) btn("⏸", "Pausa", () => api("agentControl", { id: a.id, action: "pause" }));
  if (a.status === "paused") btn("▶", "Riprendi", () => api("agentControl", { id: a.id, action: "resume" }));
  if (["running", "waitingConfirmation", "paused"].includes(a.status)) btn("■", "Ferma", () => api("agentControl", { id: a.id, action: "stop" }));
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
  return { path: S.active.path, from: sel.startLineNumber, to: sel.endLineNumber, text };
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
  if (!q || !S.project) return;
  const ctx = s ? `\nParti da ${s.path}${s.text ? ` (righe ${s.from}-${s.to})` : ""}.` : "";
  api("askElio", { text: `Avvia un agente sul progetto ${S.project.path} per: ${q}${ctx}` });
  toast("Elio avvia l'agente");
}

// ---------- Keyboard (PHPStorm-like) ----------
function setupKeys() {
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
  cmd(K.CtrlCmd | C.KeyJ, togglePanel);
  cmd(K.CtrlCmd | C.KeyL, () => showPalette("line"));
  cmd(K.CtrlCmd | C.KeyE, () => showPalette("recent"));
  cmd(K.CtrlCmd | K.Shift | C.KeyO, () => showPalette("file"));
  cmd(K.CtrlCmd | K.Shift | C.KeyA, () => showPalette("action"));
  cmd(K.CtrlCmd | K.Shift | C.KeyF, () => openSearch(editor.getModel() ? editor.getModel().getValueInRange(editor.getSelection()) : ""));
  cmd(K.CtrlCmd | C.KeyK, () => commitDialog());
  cmd(K.CtrlCmd | K.Shift | C.KeyK, () => pushNow());
  cmd(K.CtrlCmd | C.KeyS, () => saveAll());
  cmd(K.CtrlCmd | C.KeyW, () => S.active && closeTab(S.active));
  cmd(K.CtrlCmd | K.Shift | C.KeyT, reopenTab);
  cmd(K.CtrlCmd | K.Alt | C.KeyE, askElioSelection);
  cmd(K.CtrlCmd | C.BracketLeft, () => navGo(-1));
  cmd(K.CtrlCmd | C.BracketRight, () => navGo(1));
  cmd(K.CtrlCmd | K.Shift | C.BracketLeft, () => cycleTab(-1));
  cmd(K.CtrlCmd | K.Shift | C.BracketRight, () => cycleTab(1));
  cmd(K.Alt | C.F12, () => focusTerminal());
  cmd(K.Alt | C.F1, () => S.active && revealInTree(S.active.path));
  editor.addAction({ id: "elio.ask", label: "Chiedi a Elio", contextMenuGroupId: "0_elio", contextMenuOrder: 1, run: askElioSelection });
  editor.addAction({ id: "elio.delegate", label: "Delega a un agente", contextMenuGroupId: "0_elio", contextMenuOrder: 2, run: delegateSelection });
  editor.addAction({ id: "elio.diff", label: "Mostra le modifiche (diff)", contextMenuGroupId: "0_elio", contextMenuOrder: 3, run: () => S.active && showDiff(S.active.path) });
  editor.addAction({ id: "elio.reveal", label: "Mostra nell'albero", contextMenuGroupId: "0_elio", contextMenuOrder: 4, run: () => S.active && revealInTree(S.active.path) });
}
// Outside the editor (tree, panel, nothing open).
let lastShift = 0;
document.addEventListener("keydown", e => {
  if (e.key === "Shift" && !e.repeat) {
    const now = Date.now();
    if (now - lastShift < 350) { lastShift = 0; e.preventDefault(); showPalette("all"); return; }
    lastShift = now; return;
  }
  lastShift = 0;
  if (!$("#palette").classList.contains("hidden") || !$("#dialog").classList.contains("hidden")) {
    if (e.key === "Escape") { hidePalette(); $("#dialog").classList.add("hidden"); }
    return;
  }
  const inEditor = editor && editor.hasTextFocus();
  const m = e.metaKey, k = e.key.toLowerCase();
  const combos = [
    [m && e.shiftKey && k === "o", () => showPalette("file")], [m && !e.shiftKey && k === "e" && !e.altKey, () => showPalette("recent")],
    [m && e.shiftKey && k === "a", () => showPalette("action")], [m && e.shiftKey && k === "f", () => openSearch()],
    [m && !e.shiftKey && k === "k" && !inTerminal(), () => commitDialog()], [m && k === "1", toggleSide], [m && k === "0", () => setSide("changes")],
    [m && !e.shiftKey && k === "s", saveAll], [m && !e.shiftKey && k === "w", () => S.active ? closeTab(S.active) : api("closeWindow")],
    [m && e.shiftKey && k === "t", reopenTab], [m && !e.shiftKey && k === "j", togglePanel], [e.altKey && e.key === "F12", focusTerminal],
    [m && e.altKey && k === "e", askElioSelection], [m && !e.shiftKey && k === "n" && !inEditor, () => S.project && createEntry(S.selected && !S.selected.includes(".") ? S.selected : S.project.path, false)],
    [m && (k === "=" || k === "+"), () => zoom(1)], [m && k === "-", () => zoom(-1)],
  ];
  // In the editor these are Monaco commands already (setupKeys): don't run them twice.
  const monacoOwned = (inEditor && m && ["o", "e", "a", "f", "k", "s", "w", "t", "j"].includes(k)) || (inEditor && e.altKey && e.key === "F12");
  for (const [cond, f] of combos) if (cond) {
    if (monacoOwned) return;
    e.preventDefault(); f(); return;
  }
}, true);
function inTerminal() { return document.activeElement && document.activeElement.closest && document.activeElement.closest(".term"); }
function focusTerminal() {
  let p = S.panels.find(x => x.kind === "shell" && x === S.panel) || S.panels.find(x => x.kind === "shell");
  if (!p) { newShell(); return; }
  if (S.panel === p && inTerminal()) { editor.focus(); return; }
  showPanel(p); p.term.focus();
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
  if (!S.active || S._navigating) return;
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

// ---------- UI wiring ----------
function setSide(name) {
  document.querySelectorAll("#sideTabs button").forEach(b => b.classList.toggle("on", b.dataset.side === name));
  $("#tree").classList.toggle("on", name === "project"); $("#changes").classList.toggle("on", name === "changes");
  $("#agentsList").classList.toggle("on", name === "agents");
  $("#side").classList.remove("hidden"); $("#vsplit").classList.remove("hidden");
  if (name === "changes") refreshGit();
}
function toggleSide() { const h = $("#side").classList.toggle("hidden"); $("#vsplit").classList.toggle("hidden", h); }
function wireUI() {
  document.querySelectorAll("#sideTabs button").forEach(b => b.onclick = () => setSide(b.dataset.side));
  $("#projectBtn").onclick = () => showPalette("projects");
  $("#branchBtn").onclick = () => S.project && showPalette("branches");
  $("#searchBtn").onclick = () => showPalette("all");
  $("#commitBtn").onclick = () => commitDialog();
  $("#askBtn").onclick = () => askElioSelection();
  $("#agentsBtn").onclick = () => setSide("agents");
  $("#stAgents").onclick = () => setSide("agents");
  document.addEventListener("mousedown", e => { if (!e.target.closest("#ctx")) $("#ctx").classList.add("hidden"); });
  window.addEventListener("resize", () => S.panel && S.panel.fit && S.panel.fit.fit());
}
function setupSplitters() {
  const drag = (handle, onMove) => handle.addEventListener("mousedown", e => {
    e.preventDefault();
    const move = ev => onMove(ev), up = () => { document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up);
      S.panel && S.panel.fit && S.panel.fit.fit(); store.set("layout", { side: $("#side").offsetWidth, panel: $("#panel").offsetHeight }); };
    document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
  });
  drag($("#vsplit"), e => { $("#side").style.width = Math.max(160, Math.min(600, e.clientX)) + "px"; });
  drag($("#hsplit"), e => {
    const h = window.innerHeight - e.clientY - 24;
    $("#panel").classList.remove("collapsed"); $("#panel").style.height = Math.max(80, Math.min(window.innerHeight - 200, h)) + "px";
    S.panel && S.panel.fit && S.panel.fit.fit();
  });
  const l = store.get("layout", null);
  if (l) { $("#side").style.width = l.side + "px"; $("#panel").style.height = l.panel + "px"; }
}
function menu(e, items) {
  const m = $("#ctx"); m.innerHTML = "";
  for (const it of items) {
    if (it === false || it === undefined) continue;
    if (it === null) { m.append(el("div", "sep")); continue; }
    const row = el("div", "mi"); row.append(el("span", "", it[0])); if (it[2]) row.append(el("span", "k", it[2]));
    row.onclick = () => { m.classList.add("hidden"); it[1](); };
    m.append(row);
  }
  m.classList.remove("hidden");
  const w = m.offsetWidth, h = m.offsetHeight;
  m.style.left = Math.min(e.clientX, innerWidth - w - 8) + "px"; m.style.top = Math.min(e.clientY, innerHeight - h - 8) + "px";
}
function copy(text) { navigator.clipboard.writeText(text).then(() => toast("Copiato")).catch(() => {}); }
function prompt_(title, value, placeholder) {
  return new Promise(resolve => {
    const body = $("#dlgBody"); body.innerHTML = "";
    body.append(el("h3", "", title));
    const input = el("input"); input.type = "text"; input.value = value || ""; input.placeholder = placeholder || "";
    const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn go", "OK");
    btns.append(no, ok); body.append(input, btns);
    $("#dialog").classList.remove("hidden"); input.focus(); input.select();
    const done = v => { $("#dialog").classList.add("hidden"); resolve(v); if (editor && S.active) editor.focus(); };
    no.onclick = () => done(null); ok.onclick = () => done(input.value.trim());
    input.onkeydown = e => { if (e.key === "Enter") done(input.value.trim()); if (e.key === "Escape") done(null); };
  });
}
function confirm_(title, note, action) {
  return new Promise(resolve => {
    const body = $("#dlgBody"); body.innerHTML = "";
    body.append(el("h3", "", title)); if (note) body.append(el("div", "note", note));
    const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn go", action || "OK");
    btns.append(no, ok); body.append(btns);
    $("#dialog").classList.remove("hidden"); ok.focus();
    const done = v => { $("#dialog").classList.add("hidden"); resolve(v); };
    no.onclick = () => done(false); ok.onclick = () => done(true);
    body.onkeydown = e => { if (e.key === "Escape") done(false); if (e.key === "Enter") done(true); };
  });
}
