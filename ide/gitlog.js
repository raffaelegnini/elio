"use strict";
// Git tool window: the commit graph ("storia dei commit") with lanes and merge curves, commit details and actions,
// and a Console of the git commands the IDE ran. Rows are virtualized; history loads 300 commits at a time.

const GL_ROW = 26, GL_LANE = 14, GL_PAGE = 300;
const LANE_COLORS = ["#5FA8E8", "#E5A04F", "#79C47A", "#E36FA2", "#B193EA", "#4FC1B5", "#D9C55A", "#E2795C", "#8DA6EC", "#B8CD62"];
const L = {
  root: null, pinnedRoot: null, commits: [], rows: [], lanes: [], laneColors: [], colorSeq: 0, done: false, loading: false, seq: 0,
  filters: { text: "", author: "", branch: "", path: "" }, selected: null, head: "", tab: "log", remotes: [], maxLanes: 1,
};
const gl = {};

registerToolWindow({
  id: "git", title: "Git", icon: "git", side: "bottom", slot: "bottom", order: 40, key: "⌘9",
  mount: mountGitLog,
  isTab: o => ((o && o.tab) || "log") === L.tab,
  onShow(opts = {}) {
    if (opts.tab) setGitTab(opts.tab);
    if (opts.root) L.pinnedRoot = opts.root;
    let reload = !L.commits.length || (cur() && L.root !== (L.pinnedRoot || cur()));
    if (opts.path !== undefined || opts.branch !== undefined) {
      L.filters.path = opts.path || ""; L.filters.branch = opts.branch || "";
      if (opts.path) L.pinnedRoot = rootOf(opts.path);
      reload = true;
    }
    if (reload) reloadLog(); else paintLog();
    if (opts.select) selectCommit(opts.select, true);
    renderGitHead();
  },
  actions: () => L.tab === "log" ? [
    { icon: "refresh", title: "Aggiorna", action: () => reloadLog() },
    { icon: "update", title: "Fetch", action: () => fetchNow(L.root, false).then(reloadLog) },
  ] : [{ icon: "trash", title: "Svuota la console", action: () => { G.console.length = 0; renderConsole(); } }],
});
registerToolWindow({ id: "history", title: "Storia dei commit", icon: "history", slot: "top", order: 30, proxy: "git", proxyOpts: { tab: "log" }, key: "⌘9" });

function renderGitHead() {
  const tw = TW.get("git"); const h = tw.headEl; h.innerHTML = "";
  for (const [id, label] of [["log", "Log"], ["console", "Console"]]) {
    const t = el("div", "ptab" + (L.tab === id ? " on" : ""), label);
    t.onclick = () => { setGitTab(id); refreshHead("git"); renderStrip(); };
    h.append(t);
  }
}
function setGitTab(id) {
  L.tab = id;
  gl.log.classList.toggle("hidden", id !== "log");
  gl.console.classList.toggle("hidden", id !== "console");
  if (id === "console") renderConsole();
  renderGitHead();
}

function mountGitLog(box) {
  box.classList.add("gitlog-pane");
  gl.log = el("div", "gl");
  gl.console = el("div", "gl-console hidden");
  box.append(gl.log, gl.console);
  // Filters
  const left = el("div", "gl-left");
  const bar = el("div", "gl-filter");
  gl.text = el("input"); gl.text.placeholder = "Testo o hash"; gl.text.spellcheck = false;
  gl.branch = el("select");
  gl.author = el("input"); gl.author.placeholder = "Autore"; gl.author.style.width = "120px";
  gl.rootSel = el("select");
  gl.pathChip = el("span", "chip hidden");
  bar.append(gl.rootSel, gl.text, gl.branch, gl.author, gl.pathChip);
  const head = el("div", "gl-cols"); head.append(el("span", "c-sub", "Commit"), el("span", "c-au", "Autore"), el("span", "c-dt", "Data"));
  gl.scroll = el("div", "gl-scroll"); gl.scroll.tabIndex = 0;
  gl.inner = el("div", "gl-inner"); gl.scroll.append(gl.inner);
  left.append(bar, head, gl.scroll);
  const split = el("div", "gl-split");
  gl.details = el("div", "gl-details");
  gl.details.style.width = store.get("glDetails", 420) + "px";
  gl.log.append(left, split, gl.details);
  gl.details.append(el("div", "empty", "Seleziona un commit."));
  split.onmousedown = e => {
    e.preventDefault();
    const move = ev => { const w = Math.max(240, Math.min(gl.log.clientWidth - 300, gl.log.getBoundingClientRect().right - ev.clientX)); gl.details.style.width = w + "px"; };
    const up = () => { document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up); store.set("glDetails", gl.details.offsetWidth); };
    document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
  };
  let tt;
  const later = () => { clearTimeout(tt); tt = setTimeout(() => { readFilters(); reloadLog(); }, 350); };
  gl.text.oninput = later; gl.author.oninput = later;
  gl.text.onkeydown = e => {
    if (e.key !== "Enter") return;
    const v = gl.text.value.trim();
    if (/^[0-9a-f]{6,40}$/i.test(v)) { selectCommit(v, true); }
  };
  gl.branch.onchange = () => { readFilters(); reloadLog(); };
  gl.rootSel.onchange = () => { L.pinnedRoot = S.roots.find(r => r.path === gl.rootSel.value) || null; L.filters.path = ""; reloadLog(); };
  gl.scroll.addEventListener("scroll", () => { paintLogSoon(); maybeLoadMore(); });
  gl.scroll.addEventListener("keydown", e => {
    const i = L.rows.findIndex(r => r.c.hash === L.selected);
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const n = L.rows[Math.max(0, Math.min(L.rows.length - 1, i + (e.key === "ArrowDown" ? 1 : -1)))];
      if (n) selectCommit(n.c.hash, true);
    }
  });
  new ResizeObserver(paintLogSoon).observe(gl.scroll);
  on("headMoved", () => { if (TW.get("git").visible) reloadLogSoon(); });
  on("gitChanged", () => { if (TW.get("git").visible) reloadLogSoon(); });
  on("projectChanged", () => { if (TW.get("git").visible && !L.pinnedRoot && cur() !== L.root) reloadLog(); });
  // At launch the log is shown before git status arrives ("not a repository" for a moment): reload when it does.
  on("repoReady", ({ root }) => { if (TW.get("git").visible && !L.commits.length && (!L.root || L.root.path === root)) reloadLog(); });
  on("gitConsole", () => { if (L.tab === "console" && TW.get("git").visible) renderConsole(); });
  renderGitHead();
}
function readFilters() {
  L.filters.text = /^[0-9a-f]{6,40}$/i.test(gl.text.value.trim()) ? "" : gl.text.value.trim();
  L.filters.author = gl.author.value.trim();
  L.filters.branch = gl.branch.value;
}
let reloadT;
function reloadLogSoon() { clearTimeout(reloadT); reloadT = setTimeout(reloadLog, 800); }
async function reloadLog() {
  const r = (L.pinnedRoot && S.roots.includes(L.pinnedRoot) ? L.pinnedRoot : null) || cur();
  L.root = r;
  Object.assign(L, { commits: [], rows: [], lanes: [], laneColors: [], colorSeq: 0, done: false, loading: false, maxLanes: 1 });
  L.seq++;
  // Root and branch pickers
  gl.rootSel.innerHTML = "";
  for (const x of S.roots) gl.rootSel.append(Object.assign(el("option", "", x.name), { value: x.path }));
  gl.rootSel.value = r ? r.path : "";
  gl.rootSel.classList.toggle("hidden", S.roots.length < 2);
  gl.pathChip.classList.toggle("hidden", !L.filters.path);
  gl.pathChip.innerHTML = "";
  if (L.filters.path) {
    gl.pathChip.append(el("span", "", basename(L.filters.path)));
    const x = el("span", "x"); x.innerHTML = icon("close"); x.onclick = () => { L.filters.path = ""; reloadLog(); };
    gl.pathChip.append(x);
    gl.pathChip.title = L.filters.path;
  }
  gl.scroll.scrollTop = 0;
  paintLog();
  if (!r || !repoOf(r)) { gl.inner.innerHTML = ""; gl.inner.append(el("div", "empty", r ? `${r.name} non è un repository git.` : "Nessun progetto.")); return; }
  loadBranches(r).then(b => {
    const keep = L.filters.branch;
    gl.branch.innerHTML = "";
    gl.branch.append(Object.assign(el("option", "", "Tutti i branch"), { value: "" }), Object.assign(el("option", "", "HEAD"), { value: "HEAD" }));
    for (const x of [...(b.local || []), ...(b.remote || [])]) gl.branch.append(Object.assign(el("option", "", x.name), { value: x.name }));
    if (keep && ![...gl.branch.options].some(o => o.value === keep)) gl.branch.append(Object.assign(el("option", "", keep), { value: keep }));
    gl.branch.value = keep;
    L.remotes = b.remotes || [];
  });
  await loadMore();
}
async function loadMore() {
  if (L.loading || L.done || !L.root) return;
  L.loading = true;
  const my = L.seq;
  let res;
  try { res = await gitCall(L.root.path, "graph", [], { skip: L.commits.length, limit: GL_PAGE, ...L.filters }); } catch (e) { res = { commits: [], error: e.message }; }
  if (my !== L.seq) return;
  L.loading = false;
  L.head = res.head || L.head;
  const list = res.commits || [];
  if (list.length < GL_PAGE) L.done = true;
  L.commits.push(...list);
  layoutCommits(list);
  paintLog();
  if (res.error && !list.length && !L.commits.length) { gl.inner.innerHTML = ""; gl.inner.append(el("div", "empty", res.error)); }
}
function maybeLoadMore() {
  const s = gl.scroll;
  if (s.scrollTop + s.clientHeight > s.scrollHeight - GL_ROW * 40) loadMore();
}
// Lanes: each lane waits for a commit hash. A commit takes the lane waiting for it (others waiting for it merge in),
// its first parent continues the lane, other parents get a lane each. Segments are drawn per row, top half / bottom half.
function layoutCommits(list) {
  const noGraph = !!(L.filters.text || L.filters.author || L.filters.path);
  const lanes = L.lanes, colors = L.laneColors;
  const nextColor = () => LANE_COLORS[(L.colorSeq++) % LANE_COLORS.length];
  const alloc = () => { let k = lanes.indexOf(null); if (k < 0) { k = lanes.length; lanes.push(null); colors.push(null); } return k; };
  for (const c of list) {
    if (noGraph) { L.rows.push({ c, idx: 0, color: LANE_COLORS[0], segs: [] }); continue; }
    let idx = lanes.indexOf(c.hash);
    const before = lanes.slice(), beforeColors = colors.slice();
    if (idx < 0) { idx = alloc(); colors[idx] = nextColor(); }
    const color = colors[idx];
    const segs = [];
    for (let j = 0; j < before.length; j++) {
      if (!before[j]) continue;
      segs.push(before[j] === c.hash ? [j, 0, idx, 0.5, beforeColors[j]] : [j, 0, j, 1, beforeColors[j]]);
    }
    for (let j = 0; j < lanes.length; j++) if (j !== idx && lanes[j] === c.hash) { lanes[j] = null; colors[j] = null; }
    const ps = c.parents || [];
    if (!ps.length) { lanes[idx] = null; colors[idx] = null; }
    else {
      const k0 = lanes.indexOf(ps[0]);
      if (k0 >= 0 && k0 !== idx) { segs.push([idx, 0.5, k0, 1, color]); lanes[idx] = null; colors[idx] = null; }
      else { lanes[idx] = ps[0]; segs.push([idx, 0.5, idx, 1, color]); }
      for (const p of ps.slice(1)) {
        let k = lanes.indexOf(p);
        if (k < 0) { k = alloc(); lanes[k] = p; colors[k] = nextColor(); }
        segs.push([idx, 0.5, k, 1, colors[k]]);
      }
    }
    while (lanes.length && lanes[lanes.length - 1] === null) { lanes.pop(); colors.pop(); }
    const width = Math.max(idx + 1, ...segs.map(s => Math.max(s[0], s[2]) + 1));
    L.maxLanes = Math.max(L.maxLanes, Math.min(width, 24));
    L.rows.push({ c, idx, color, segs, merge: ps.length > 1 });
  }
}
let glPaintQ = false;
function paintLogSoon() { if (glPaintQ) return; glPaintQ = true; requestAnimationFrame(() => { glPaintQ = false; paintLog(); }); }
function paintLog() {
  if (!gl.inner) return;
  const rows = L.rows;
  gl.inner.style.height = Math.max(rows.length * GL_ROW, 1) + "px";
  if (!rows.length) {
    gl.inner.innerHTML = "";
    gl.inner.append(el("div", "empty", L.loading || !L.done ? "Carico la storia…" : "Nessun commit."));
    return;
  }
  const top = gl.scroll.scrollTop, h = gl.scroll.clientHeight || 400;
  const from = Math.max(0, Math.floor(top / GL_ROW) - 6), to = Math.min(rows.length, Math.ceil((top + h) / GL_ROW) + 6);
  const gw = 10 + L.maxLanes * GL_LANE;
  const frag = document.createDocumentFragment();
  for (let i = from; i < to; i++) frag.append(logRow(rows[i], i, gw));
  if (!L.done) { const more = el("div", "gl-more", L.loading ? "Carico altri commit…" : ""); more.style.top = rows.length * GL_ROW + "px"; frag.append(more); }
  gl.inner.replaceChildren(frag);
}
const laneX = l => 9 + l * GL_LANE;
function logRow(r, i, gw) {
  const c = r.c;
  const row = el("div", "gl-row" + (c.hash === L.selected ? " sel" : "") + (c.hash === L.head ? " head" : ""));
  row.style.top = i * GL_ROW + "px";
  let svg = `<svg class="gl-graph" width="${gw}" height="${GL_ROW}" viewBox="0 0 ${gw} ${GL_ROW}">`;
  for (const [l1, y1, l2, y2, color] of r.segs) {
    if (l1 >= 24 || l2 >= 24) continue;
    const x1 = laneX(l1), x2 = laneX(l2), Y1 = y1 * GL_ROW, Y2 = y2 * GL_ROW, ym = (Y1 + Y2) / 2;
    const d = x1 === x2 ? `M${x1} ${Y1}L${x2} ${Y2}` : `M${x1} ${Y1}C${x1} ${ym} ${x2} ${ym} ${x2} ${Y2}`;
    svg += `<path d="${d}" stroke="${color}" stroke-width="1.6" fill="none"/>`;
  }
  const nx = laneX(Math.min(r.idx, 23));
  svg += c.hash === L.head
    ? `<circle cx="${nx}" cy="${GL_ROW / 2}" r="4.6" fill="#1E1F22" stroke="${r.color}" stroke-width="2.2"/>`
    : `<circle cx="${nx}" cy="${GL_ROW / 2}" r="${r.merge ? 3.2 : 4}" fill="${r.color}"/>`;
  svg += "</svg>";
  const g = el("span", "c-graph"); g.style.width = gw + "px"; g.innerHTML = svg;
  const sub = el("span", "c-sub");
  for (const ref of c.refs || []) sub.append(refBadge(ref));
  sub.append(el("span", "msg", c.subject));
  row.append(g, sub, el("span", "c-au", c.author), el("span", "c-dt", relTime(c.at)));
  row.title = `${c.hash.slice(0, 10)} · ${c.author} · ${fmtDate(c.at, true)}`;
  row.onclick = () => selectCommit(c.hash);
  row.oncontextmenu = e => { e.preventDefault(); selectCommit(c.hash); menu(e, commitActions(c)); };
  return row;
}
function refBadge(ref) {
  let cls = "local", text = ref, ic = "branch";
  if (ref.startsWith("HEAD -> ")) { cls = "head"; text = ref.slice(8); }
  else if (ref === "HEAD") { cls = "head"; text = "HEAD"; ic = "dot"; }
  else if (ref.startsWith("tag: ")) { cls = "tag"; text = ref.slice(5); ic = "tag"; }
  else if (L.remotes.some(rm => ref.startsWith(rm + "/"))) { cls = "remote"; }
  const b = el("span", "ref " + cls); b.innerHTML = icon(ic); b.append(text);
  return b;
}
async function selectCommit(hash, scroll) {
  const r = L.root; if (!r) return;
  const i = L.rows.findIndex(x => x.c.hash.startsWith(hash));
  if (i >= 0) {
    L.selected = L.rows[i].c.hash;
    if (scroll) { const y = i * GL_ROW; if (y < gl.scroll.scrollTop || y > gl.scroll.scrollTop + gl.scroll.clientHeight - GL_ROW) gl.scroll.scrollTop = y - gl.scroll.clientHeight / 2; }
  } else L.selected = hash;
  paintLog();
  gl.scroll.focus({ preventScroll: true });
  const info = await gitCall(r.path, "commitInfo", [], { hash });
  if (L.selected !== hash && !(info.hash || "").startsWith(L.selected)) return;
  if (!info.hash) { gl.details.innerHTML = ""; gl.details.append(el("div", "empty", "Commit non trovato.")); return; }
  L.selected = info.hash; paintLog();
  renderDetails(r, info);
}
function renderDetails(r, info) {
  const d = gl.details; d.innerHTML = "";
  const actions = el("div", "gl-actions");
  const btn = (ic, title, f, cls = "") => { const b = el("button", "tb-ico " + cls); b.innerHTML = icon(ic); b.title = title; b.onclick = f; actions.append(b); };
  const c = { hash: info.hash, parents: info.parents, subject: (info.body || "").split("\n")[0] };
  btn("open", "Checkout di questa revisione", () => checkoutRevisionHash(r, c));
  btn("branchNew", "Nuovo branch qui…", () => newBranch(r, c.hash));
  btn("cherry", "Cherry-pick", () => cherryPick(r, c));
  btn("revert", "Revert del commit", () => revertCommit(r, c));
  btn("reset", "Reset del branch corrente qui…", () => resetTo(r, c));
  btn("copy", "Copia hash", () => copy(c.hash));
  d.append(actions);
  const body = el("div", "gl-body");
  const lines = (info.body || "").split("\n");
  body.append(el("div", "subj", lines[0] || ""));
  if (lines.length > 1) body.append(el("pre", "desc", lines.slice(1).join("\n").trim()));
  const meta = el("div", "meta");
  const hash = el("span", "hash", info.hash.slice(0, 12)); hash.title = "Copia"; hash.onclick = () => copy(info.hash);
  meta.append(hash, el("span", "", ` · ${info.author}`), el("span", "dim", ` <${info.email}>`));
  body.append(meta, el("div", "meta dim", fmtDate(info.at, true) + (info.committer && info.committer !== info.author ? ` · commit di ${info.committer}` : "")));
  if (info.refs) { const refs = el("div", "refs"); info.refs.split(", ").filter(Boolean).forEach(x => refs.append(refBadge(x))); body.append(refs); }
  if (info.parents && info.parents.length) {
    const ps = el("div", "meta dim", info.parents.length > 1 ? "Genitori: " : "Genitore: ");
    info.parents.forEach(p => { const a = el("span", "link", p.slice(0, 8)); a.onclick = () => selectCommit(p, true); ps.append(a, " "); });
    body.append(ps);
  }
  d.append(body);
  d.append(el("div", "sect-title", `${(info.files || []).length} file modificati`));
  const files = el("div", "gl-files");
  for (const f of info.files || []) {
    const row = el("div", "chg");
    const ic = el("span", "ic"); ic.innerHTML = fileIcon(basename(f.path), false);
    row.append(el("span", "code " + f.status, f.status), ic, el("span", "p", basename(f.path)), el("span", "dir", dirname(f.path)));
    row.title = f.from ? `${f.from} → ${f.path}` : f.path;
    row.onclick = () => commitFileDiff(info, f);
    row.ondblclick = () => openFile(info.top + "/" + f.path);
    row.oncontextmenu = e => { e.preventDefault(); menu(e, [
      { label: "Mostra diff", icon: "diff", action: () => commitFileDiff(info, f) },
      f.status !== "D" && { label: "Apri la versione locale", action: () => openFile(info.top + "/" + f.path) },
      { label: "Confronta con la versione locale", icon: "diff", action: () => diffWithRevision(info.top + "/" + f.path, info.hash, info.hash.slice(0, 8)) },
      { label: "Storia del file", icon: "history", action: () => showFileHistory(info.top + "/" + f.path) },
    ]); };
    files.append(row);
  }
  d.append(files);
}
async function commitFileDiff(info, f) {
  const top = info.top;
  const parent = info.parents && info.parents[0];
  const [a, b] = await Promise.all([
    parent && f.status !== "A" ? gitCall(top, "show", [f.from || f.path, parent]) : Promise.resolve({ content: "" }),
    f.status !== "D" ? gitCall(top, "show", [f.path, info.hash]) : Promise.resolve({ content: "" }),
  ]);
  openDiff({ title: `${f.path}  ·  ${parent ? parent.slice(0, 8) : "∅"} ↔ ${info.hash.slice(0, 8)}`, original: a.content || "", modified: b.content || "", path: f.path });
}
function commitActions(c) {
  const r = L.root;
  return [
    { label: "Copia hash", icon: "copy", action: () => copy(c.hash) },
    null,
    { label: "Checkout di questa revisione", action: () => checkoutRevisionHash(r, c) },
    { label: "Nuovo branch qui…", icon: "branchNew", action: () => newBranch(r, c.hash) },
    { label: "Nuovo tag qui…", icon: "tag", action: async () => { const t = await prompt_("Nuovo tag", ""); if (t && !validRef(t)) { toast("Nome di tag non valido", "error"); return; } if (t) afterGitOp(r, await gitRaw(r.path, ["tag", t, c.hash]), `Tag ${t} creato`); } },
    null,
    { label: "Cherry-pick", icon: "cherry", action: () => cherryPick(r, c) },
    { label: "Revert del commit", icon: "revert", action: () => revertCommit(r, c) },
    { label: "Reset del branch corrente qui…", icon: "reset", danger: true, action: () => resetTo(r, c) },
    null,
    { label: "Mostra diff con la working tree", icon: "diff", action: () => diffWithWorkingTree(r, c.hash) },
  ];
}
async function checkoutRevisionHash(r, c) {
  if (!(await confirm_(`Checkout di ${c.hash.slice(0, 8)}?`, "Sarai in «detached HEAD»: per lavorarci crea un branch.", "Checkout"))) return;
  await saveAllQuiet();
  checkoutArgs(r, ["checkout", c.hash]);
}
async function cherryPick(r, c) {
  const st = repoOf(r);
  if (!(await confirm_(`Cherry-pick di ${c.hash.slice(0, 8)} su ${st ? st.branch : "HEAD"}?`, c.subject || "", "Cherry-pick"))) return;
  afterGitOp(r, await gitRaw(r.path, ["cherry-pick", ...((c.parents || []).length > 1 ? ["-m", "1"] : []), c.hash]), "Cherry-pick fatto");
}
async function revertCommit(r, c) {
  if (!(await confirm_(`Revert di ${c.hash.slice(0, 8)}?`, "Crea un nuovo commit che annulla questo.", "Revert"))) return;
  afterGitOp(r, await gitRaw(r.path, ["revert", "--no-edit", ...((c.parents || []).length > 1 ? ["-m", "1"] : []), c.hash]), "Revert fatto");
}
async function resetTo(r, c) {
  const st = repoOf(r);
  const body = openDialog();
  body.append(el("h3", "", `Reset di ${st ? st.branch : "HEAD"} a ${c.hash.slice(0, 8)}`));
  const opt = (v, label, note, checked) => { const l = el("label", "radio"); const i = el("input"); i.type = "radio"; i.name = "rst"; i.value = v; i.checked = !!checked;
    l.append(i, el("b", "", label), el("span", "note", note)); return l; };
  body.append(opt("soft", "Soft", "i commit successivi tornano come modifiche già in stage"),
    opt("mixed", "Mixed", "i commit successivi tornano come modifiche locali", true),
    opt("hard", "Hard", "butta via commit successivi E modifiche locali (non si può annullare)"),
    opt("keep", "Keep", "come hard, ma si ferma se tocca modifiche locali"));
  const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn danger-go", "Reset");
  btns.append(no, ok); body.append(btns);
  no.onclick = closeDialog;
  ok.onclick = async () => {
    const mode = body.querySelector("input[name=rst]:checked").value;
    closeDialog();
    if (mode === "hard" && !(await confirm_("Reset --hard: sicuro?", "Le modifiche locali e i commit dopo questo vanno persi.", "Reset --hard", { danger: true }))) return;
    await saveAllQuiet();
    afterGitOp(r, await gitRaw(r.path, ["reset", "--" + mode, c.hash]), `Reset (${mode}) fatto`);
  };
}

// ---------- Console ----------
function renderConsole() {
  if (!gl.console) return;
  const box = gl.console; box.innerHTML = "";
  if (!G.console.length) { box.append(el("div", "empty", "Qui compaiono i comandi git eseguiti dall'IDE (commit, push, checkout…).")); return; }
  for (const e of G.console.slice(-200)) {
    const r = S.roots.find(x => x.path === e.root);
    const head = el("div", "gc-line " + (e.ok ? "ok" : "fail"));
    head.append(el("span", "t", new Date(e.at).toLocaleTimeString("it-IT")), el("span", "r", r ? r.name : basename(e.root || "")), el("span", "c", e.line));
    box.append(head);
    if (e.output) box.append(el("pre", "gc-out", e.output.slice(0, 4000)));
  }
  box.scrollTop = box.scrollHeight;
}
