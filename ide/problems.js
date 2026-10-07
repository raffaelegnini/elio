"use strict";
// Problems: Monaco's own validators (JS/TS/JSON/CSS) plus on-save checks run by Swift (php -l, node --check, python,
// ruby, bash/zsh -n, swiftc -parse, xmllint, YAML) and the project's analyzers (PHPStan, ESLint, tsc) once the user
// trusts the folder. Squiggles in the editor, red/yellow in tree and tabs, a list in the Problems tool window.

const P = {
  byFile: new Map(),   // path → { lint: [], deep: [], tsc: [] }
  seq: new Map(),
  trust: new Map(),    // root path → bool (cache of Swift's ide-trusted.json)
  askedTrust: new Set(),
  errFiles: new Set(), warnFiles: new Set(), errDirs: new Set(),
  onlyCurrent: store.get("problemsOnlyCurrent", false),
};
const SEV = { error: 8, warning: 4, info: 2 };

async function runChecks(tab, opts = {}) {
  if (!tab || tab.virtual) return;
  const path = tab.path, r = rootOf(path);
  const seq = (P.seq.get(path) || 0) + 1; P.seq.set(path, seq);
  let res;
  try { res = await api("check", { path }); } catch { return; }
  if (P.seq.get(path) !== seq) return;
  setProblems(path, "lint", res.problems || []);
  if (!opts.deep || !r) return;
  let deep;
  try { deep = await api("checkDeep", { path, root: r.path }); } catch { return; }
  if (P.seq.get(path) !== seq) return;
  if (deep.untrusted) { offerTrust(r, deep.tools || []); return; }
  if (deep.tool) setProblems(path, "deep", deep.problems || []);
}
function setProblems(path, kind, list) {
  const entry = P.byFile.get(path) || { lint: [], deep: [], tsc: [] };
  entry[kind] = list.map(p => ({ ...p, kind }));
  P.byFile.set(path, entry);
  applyMarkers(path);
  problemsChanged();
}
function applyMarkers(path) {
  const model = monaco.editor.getModel(monaco.Uri.file(path));
  if (!model) return;
  const entry = P.byFile.get(path) || {};
  for (const kind of ["lint", "deep", "tsc"]) {
    const list = entry[kind] || [];
    monaco.editor.setModelMarkers(model, "elio-" + kind, list.map(p => {
      const line = Math.min(Math.max(1, p.line), model.getLineCount());
      const endLine = p.endLine ? Math.min(p.endLine, model.getLineCount()) : line;
      const startCol = Math.max(1, p.col || model.getLineFirstNonWhitespaceColumn(line) || 1);
      const endCol = p.endCol || model.getLineMaxColumn(endLine);
      return { severity: SEV[p.severity] || 8, message: p.message, source: p.source, startLineNumber: line, startColumn: startCol,
        endLineNumber: endLine, endColumn: Math.max(endCol, startCol + 1) };
    }));
  }
}
// Everything known, by file: our checks plus Monaco's validators on open models.
function allProblems() {
  const map = new Map();
  const push = (path, p) => { if (!map.has(path)) map.set(path, []); map.get(path).push(p); };
  for (const [path, e] of P.byFile) for (const kind of ["lint", "deep", "tsc"]) for (const p of e[kind] || []) push(path, p);
  if (window.monaco) {
    for (const m of monaco.editor.getModelMarkers({})) {
      if (m.owner.startsWith("elio-") || m.resource.scheme !== "file") continue;
      const list = map.get(m.resource.path) || [];
      // node --check repeats Monaco's own JS syntax errors: keep one.
      const dup = list.findIndex(p => p.source === "node" && p.line === m.startLineNumber);
      if (dup >= 0) list.splice(dup, 1);
      push(m.resource.path, { line: m.startLineNumber, col: m.startColumn, message: m.message, source: m.source || m.owner,
        severity: m.severity >= 8 ? "error" : m.severity >= 4 ? "warning" : "info" });
    }
  }
  for (const [k, v] of map) { if (!v.length) map.delete(k); else v.sort((a, b) => (SEV[b.severity] || 0) - (SEV[a.severity] || 0) || a.line - b.line); }
  return map;
}
let probT;
function problemsChanged() {
  clearTimeout(probT);
  probT = setTimeout(() => {
    const all = allProblems();
    P.errFiles.clear(); P.warnFiles.clear(); P.errDirs.clear();
    let errors = 0, warnings = 0;
    for (const [path, list] of all) {
      const e = list.filter(p => p.severity === "error").length, w = list.filter(p => p.severity === "warning").length;
      errors += e; warnings += w;
      if (e) { P.errFiles.add(path); let d = dirname(path); const r = rootOf(path); while (r && d.length >= r.path.length) { P.errDirs.add(d); d = dirname(d); } }
      else if (w) P.warnFiles.add(path);
    }
    const st = $("#stProblems"); st.innerHTML = "";
    if (errors) { const s = el("span", "perr"); s.innerHTML = icon("error"); s.append(String(errors)); st.append(s); }
    if (warnings) { const s = el("span", "pwarn"); s.innerHTML = icon("warning"); s.append(String(warnings)); st.append(s); }
    st.title = errors || warnings ? `${errors} errori, ${warnings} avvisi (⌘6)` : "Nessun problema";
    P.counts = { errors, warnings };
    paintTreeSoon(); renderTabs(); renderStrip();
    if (TW.get("problems").visible) renderProblems(all);
  }, 250);
}
function problemClass(path, isDir) {
  if (P.errFiles.has(path)) return "p-err";
  if (isDir && P.errDirs.has(path)) return "p-err";
  if (P.warnFiles.has(path)) return "p-warn";
  return "";
}

// ---------- Trust (project tools run the project's own code) ----------
async function isTrusted(r) {
  if (P.trust.has(r.path)) return P.trust.get(r.path);
  let v = false; try { v = !!(await api("trust.get", { root: r.path })); } catch {}
  P.trust.set(r.path, v);
  return v;
}
function offerTrust(r, tools) {
  if (P.askedTrust.has(r.path) || document.querySelector(`.trust-banner[data-root="${CSS.escape(r.path)}"]`)) return;
  P.askedTrust.add(r.path);
  const b = el("div", "trust-banner"); b.dataset.root = r.path;
  const ic = el("span", "ico"); ic.innerHTML = icon("lock");
  const names = tools && tools.length ? tools.join(", ") : "eslint, phpstan…";
  b.append(ic, el("span", "t", `Ti fidi di «${r.name}»? Permetti di eseguire i suoi strumenti (${names}). Usano codice e configurazioni del progetto.`));
  const yes = el("button", "btn go small", "Fidati"), no = el("button", "btn small", "Non ora");
  yes.onclick = async () => {
    b.remove();
    try { await api("trust.set", { root: r.path, trusted: true }); P.trust.set(r.path, true); } catch (e) { toast(e.message, "error"); return; }
    toast(`${r.name}: strumenti del progetto abilitati`, "ok");
    S.tabs.filter(t => !t.virtual && rootOf(t.path) === r).forEach(t => runChecks(t, { deep: true }));
  };
  no.onclick = () => b.remove();
  b.append(yes, no);
  $("#center").insertBefore(b, $("#editorWrap"));
}
async function untrustProject(r) {
  try { await api("trust.set", { root: r.path, trusted: false }); P.trust.set(r.path, false); P.askedTrust.delete(r.path); toast(`${r.name}: fiducia revocata`); } catch (e) { toast(e.message, "error"); }
}

// ---------- tsc (whole project, on demand) ----------
async function runTsc(r = cur()) {
  if (!r) return;
  status("tsc --noEmit in corso…");
  let res;
  try { res = await api("tsc", { root: r.path }); } catch (e) { status(""); toast(e.message, "error"); return; }
  status("");
  if (res.untrusted) { P.askedTrust.delete(r.path); offerTrust(r, ["tsc"]); return; }
  if (res.error) { toast(res.error, "error"); return; }
  for (const [path, e] of P.byFile) if (path.startsWith(r.path + "/") && e.tsc && e.tsc.length) { e.tsc = []; applyMarkers(path); }
  let n = 0;
  for (const [path, list] of Object.entries(res.files || {})) { setProblems(path, "tsc", list); n += list.length; }
  toast(n ? `tsc: ${n} problemi` : "tsc: nessun errore", n ? "error" : "ok");
  showToolWindow("problems");
  problemsChanged();
}

// ---------- Problems tool window ----------
registerToolWindow({
  id: "problems", title: "Problemi", icon: "problems", side: "bottom", slot: "bottom", order: 30, key: "⌘6",
  mount(box) { box.classList.add("problems-pane"); const l = el("div", "plist"); l.id = "problemsList"; box.append(l); },
  onShow() { renderProblems(allProblems()); },
  badge: () => P.counts && P.counts.errors ? { text: String(Math.min(P.counts.errors, 99)), kind: "error" } : null,
  actions: () => [
    { icon: "filter", title: P.onlyCurrent ? "Mostra tutti i file" : "Solo il file aperto", on: P.onlyCurrent,
      action: () => { P.onlyCurrent = !P.onlyCurrent; store.set("problemsOnlyCurrent", P.onlyCurrent); refreshHead("problems"); renderProblems(allProblems()); } },
    { icon: "refresh", title: "Ricontrolla i file aperti", action: () => S.tabs.forEach(t => runChecks(t, { deep: true })) },
    { icon: "run", title: "Controlla il progetto con tsc --noEmit", action: () => runTsc() },
  ],
});
function renderProblems(all) {
  const box = $("#problemsList"); if (!box) return;
  box.innerHTML = "";
  let entries = [...all.entries()];
  if (P.onlyCurrent) entries = entries.filter(([p]) => S.active && p === S.active.path);
  entries.sort((a, b) => (P.errFiles.has(b[0]) - P.errFiles.has(a[0])) || a[0].localeCompare(b[0]));
  if (!entries.length) { box.append(el("div", "empty", P.onlyCurrent ? "Nessun problema nel file aperto." : "Nessun problema. I file vengono controllati quando li salvi.")); return; }
  for (const [path, list] of entries) {
    const r = rootOf(path);
    const head = el("div", "pfile");
    const ic = el("span", "ic"); ic.innerHTML = fileIcon(basename(path), false);
    head.append(ic, el("span", "nm", basename(path)), el("span", "dir", r ? (S.roots.length > 1 ? r.name + " › " : "") + dirname(relative(path, r)) : tilde(dirname(path))),
      el("span", "n", `${list.length}`));
    head.onclick = () => openFile(path);
    box.append(head);
    for (const p of list.slice(0, 500)) {
      const row = el("div", "prow " + p.severity);
      const si = el("span", "sev"); si.innerHTML = icon(p.severity === "error" ? "error" : p.severity === "warning" ? "warning" : "info");
      row.append(si, el("span", "msg", p.message), el("span", "src", p.source || ""), el("span", "pos", `${p.line}:${p.col || 1}`));
      row.onclick = () => openFile(path, { line: p.line, col: p.col || 1, highlight: true });
      row.oncontextmenu = e => { e.preventDefault(); menu(e, [
        { label: "Vai al punto", action: () => openFile(path, { line: p.line, col: p.col || 1, highlight: true }) },
        { label: "Copia il messaggio", icon: "copy", action: () => copy(p.message) },
        { label: "Chiedi a Elio di sistemarlo", icon: "elio", action: () => { api("askElio", { text: `Sistema questo problema in ${path} riga ${p.line}: ${p.message}` }); toast("Chiesto a Elio"); } },
      ]); };
      box.append(row);
    }
  }
}
onBoot(() => {
  monaco.editor.onDidChangeMarkers(() => problemsChanged());
  monaco.editor.onDidCreateModel(m => { if (m.uri.scheme === "file" && P.byFile.has(m.uri.path)) setTimeout(() => applyMarkers(m.uri.path), 0); });
  on("tabChanged", () => { if (P.onlyCurrent && TW.get("problems").visible) renderProblems(allProblems()); });
  ACTIONS.push(["Revoca la fiducia al progetto (strumenti)", "", () => cur() && untrustProject(cur())]);
});
