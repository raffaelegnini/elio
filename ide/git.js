"use strict";
// Git: status colors (tree, tabs, breadcrumb), gutter markers, the toolbar branch widget and its popup, the Commit
// tool window, push / update project, branch operations, blame. One repository per workspace root (roots may differ).

const G = {
  repos: new Map(),      // root path → status from Swift (repo, top, branch, upstream, ahead, behind, files, ignored, state)
  kind: new Map(),       // absolute path → M | A | D | R | C | U
  dirs: new Map(),       // absolute folder → strongest kind inside
  ignored: new Set(),    // absolute paths (folders without trailing slash)
  branches: new Map(),   // root path → last branches payload
  checked: new Map(),    // commit panel: absolute path → included
  console: [],           // git commands run by the IDE (Git tool window → Console)
  blameOn: false,
};
const KIND_RANK = { C: 4, M: 3, A: 3, D: 3, R: 3, U: 1 };
const KIND_LABEL = { M: "modificato", A: "aggiunto", D: "eliminato", R: "rinominato", C: "in conflitto", U: "non versionato" };

// ---------- Calls ----------
// Commit / push / pull run the repo's hooks and credentials: Swift refuses them in folders not yet trusted, we ask once.
async function gitCall(root, cmd, args = [], opts = {}) {
  let r = await api("git", { root, cmd, args, opts });
  if (r && r.untrusted && !opts.background) {
    const name = (S.roots.find(x => x.path === root) || { name: basename(root) }).name;
    if (await confirm_(`Ti fidi di «${name}»?`, "Commit, push, pull, fetch, checkout, add, reset, merge e rebase usano la configurazione git del progetto (hook, remoti, driver), che può eseguire programmi.", "Fidati ed esegui")) {
      await api("trust.set", { root, trusted: true });
      if (typeof P !== "undefined") P.trust.set(root, true);
      r = await api("git", { root, cmd, args, opts });
    }
  }
  return r;
}
// Ref names come from the repository (a cloned repo may carry a ref named "--upload-pack=…"): never treat them as options.
// Swift enforces the same rules; this check fails early with a clear message.
const GIT_FLAGS = new Set(["--rebase", "--no-rebase", "--autostash", "--no-edit", "-m", "-d", "-D", "-b", "--track", "--delete", "-u", "-q",
  "--soft", "--mixed", "--hard", "--keep", "--name-status", "-M", "-n", "-1", "--force-with-lease", "--", "--end-of-options", "--abbrev-ref"]);
function validRef(name) {
  return typeof name === "string" && name.length > 0 && !name.startsWith("-") && !name.split("/").some(c => c.startsWith("-") || c === "") &&
    !/[\x00-\x1f\x7f ~^:?*\[\\]/.test(name) && !name.includes("..") && !name.endsWith(".lock");
}
function unsafeGitArgs(args) {
  let after = false;
  for (const a of args.slice(1)) {
    if (/[\x00-\x09\x0b-\x1f]/.test(a) || /^(-c|--config|--config-env|--upload-pack|--receive-pack|--exec|--output)(=|$)/i.test(a) || /core\.(sshcommand|pager|editor|hookspath)/i.test(a)) return a;
    if (after) continue;
    if (a === "--" || a === "--end-of-options") { after = true; continue; }
    if (a.startsWith("-") && !GIT_FLAGS.has(a) && !a.startsWith("--format=") && !/^-\d+$/.test(a)) return a;
  }
  return null;
}
async function gitRaw(root, args, opts = {}) {
  let r;
  const bad = unsafeGitArgs(args);
  if (bad) { r = { ok: false, output: `Argomento git rifiutato: ${bad}` }; logGit(root, "git " + args.join(" "), r); return r; }
  try { r = await gitCall(root, "raw", args, opts); } catch (e) { r = { ok: false, output: e.message || String(e) }; }
  logGit(root, "git " + args.join(" "), r);
  return r;
}
function logGit(root, line, r) {
  G.console.push({ at: Date.now(), root, line, ok: !!(r && r.ok), output: (r && r.output) || "" });
  if (G.console.length > 400) G.console.splice(0, G.console.length - 400);
  emitLocal("gitConsole", {});
}
function repoOf(r) { const st = r && G.repos.get(r.path); return st && st.repo ? st : null; }
// Roots that are distinct repositories (two roots inside one repo count once).
function distinctRepos() {
  const seen = new Set(), out = [];
  for (const r of S.roots) { const st = repoOf(r); if (st && !seen.has(st.top)) { seen.add(st.top); out.push({ root: r, st }); } }
  return out;
}

// ---------- Status ----------
const gitSeq = new Map(), gitSoonT = new Map();
async function refreshGit(r) {
  if (!r) return;
  const seq = (gitSeq.get(r.path) || 0) + 1; gitSeq.set(r.path, seq);
  let st; try { st = await gitCall(r.path, "status"); } catch { return; }
  if (gitSeq.get(r.path) !== seq || !S.roots.includes(r)) return;
  const prev = G.repos.get(r.path);
  G.repos.set(r.path, st);
  rebuildGitMaps();
  applyGitColors();
  // HEAD moved (checkout, pull, commit outside the IDE): gutter markers compare against the new HEAD.
  if (prev && st.repo && (prev.oid !== st.oid || prev.branch !== st.branch)) {
    S.tabs.filter(t => !t.virtual && rootOf(t.path) === r).forEach(loadHead);
    emitLocal("headMoved", { root: r.path });
  }
  // First status of a root: views that started before git info arrived (the log at launch) can load now.
  if (!prev && st.repo) emitLocal("repoReady", { root: r.path });
}
async function refreshGitAll() { await Promise.all(S.roots.map(refreshGit)); }
function refreshGitSoon(r) {
  for (const x of r ? [r] : S.roots) {
    clearTimeout(gitSoonT.get(x.path));
    gitSoonT.set(x.path, setTimeout(() => refreshGit(x), 500));
  }
}
function forgetRepo(path) { G.repos.delete(path); rebuildGitMaps(); applyGitColors(); }
on("gitChanged", d => { const r = S.roots.find(x => x.path === d.root); if (r) refreshGitSoon(r); });
function rebuildGitMaps() {
  G.kind.clear(); G.dirs.clear(); G.ignored.clear();
  for (const st of G.repos.values()) {
    if (!st.repo) continue;
    for (const f of st.files || []) {
      G.kind.set(f.path, f.kind);
      let d = dirname(f.path);
      while (d.length >= st.top.length && d.length > 1) {
        const prev = G.dirs.get(d);
        const next = !prev || KIND_RANK[f.kind] > KIND_RANK[prev] ? (f.kind === "C" ? "C" : f.kind === "U" ? "U" : "M") : prev;
        if (prev === next) break; // ancestors already carry it
        G.dirs.set(d, next);
        d = dirname(d);
      }
    }
    for (const p of st.ignored || []) G.ignored.add(p);
  }
}
function isIgnored(p) {
  let x = p;
  for (let i = 0; i < 60 && x.length > 1; i++) { if (G.ignored.has(x)) return true; x = dirname(x); }
  return false;
}
// CSS class for a path's git state (g-M blue, g-A green, g-U red-brown, g-C conflict, g-D deleted, g-I ignored; folders g-dM…).
function gitClass(path, isDir) {
  const k = G.kind.get(path);
  if (k) return "g-" + k;
  if (isDir) { const d = G.dirs.get(path); if (d) return "g-d" + d; }
  if (G.ignored.size && isIgnored(path)) return "g-I";
  return "";
}
function repoBadge(rootPath) {
  const st = G.repos.get(rootPath);
  if (!st || !st.repo || S.roots.length < 2) return null;
  const b = el("span", "rbranch"); b.innerHTML = icon("branch"); b.append(st.branch);
  return b;
}
let colorsQueued = false;
function applyGitColors() {
  if (colorsQueued) return;
  colorsQueued = true;
  requestAnimationFrame(() => {
    colorsQueued = false;
    paintTree(); renderTabs(); renderCrumbs(); renderGitWidget(); renderStrip();
    if (TW.get("commit") && TW.get("commit").visible) renderCommitPanel();
  });
}
function renderGitWidget() {
  const r = cur(), st = repoOf(r);
  const name = $("#branchName"), sync = $("#branchSync");
  if (!name) return;
  sync.innerHTML = "";
  if (!r) { name.textContent = "—"; $("#stBranch").textContent = ""; return; }
  if (!st) { name.textContent = G.repos.has(r.path) ? "Nessun repository" : "…"; $("#stBranch").textContent = ""; }
  else {
    const states = { merging: "Merge in corso", rebasing: "Rebase in corso", "cherry-picking": "Cherry-pick in corso", reverting: "Revert in corso" };
    name.textContent = st.branch + (st.state ? ` · ${states[st.state] || st.state}` : "");
    if (st.ahead) { const a = el("span", "ahead"); a.innerHTML = icon("arrowUp"); a.append(String(st.ahead)); a.title = `${st.ahead} commit da inviare`; sync.append(a); }
    if (st.behind) { const b = el("span", "behind"); b.innerHTML = icon("arrowDown"); b.append(String(st.behind)); b.title = `${st.behind} commit da ricevere`; sync.append(b); }
    $("#stBranch").innerHTML = icon("branch"); $("#stBranch").append(st.branch);
  }
  $("#branchBtn").classList.toggle("state", !!(st && st.state));
  for (const id of ["#updateBtn", "#commitBtn", "#pushBtn"]) $(id).disabled = !st;
  const n = st ? (st.files || []).length : 0;
  $("#commitBtn").title = `Commit… (⌘K)${n ? ` · ${n} modifiche` : ""}`;
}

// ---------- Gutter markers vs HEAD (live while typing) ----------
async function loadHead(tab) {
  const r = rootOf(tab.path); if (!r) return;
  try {
    const res = await gitCall(r.path, "show", [relative(tab.path, r)]);
    tab.head = res.exists ? res.content : null;
    tab.isNew = !res.exists;
    if (tab === S.active) decorate(tab);
  } catch {}
}
function decorate(tab) {
  if (tab !== S.active || !editor || tab.virtual) return;
  const lines = tab.model.getLinesContent();
  const decos = [];
  if (tab.isNew && G.kind.has(tab.path)) {
    decos.push({ range: new monaco.Range(1, 1, lines.length, 1), options: { isWholeLine: true, linesDecorationsClassName: "gm-add" } });
  } else if (tab.head != null) {
    for (const ch of lineDiff(tab.head.split("\n"), lines)) {
      const cls = ch.type === "add" ? "gm-add" : ch.type === "mod" ? "gm-mod" : "gm-del";
      const start = Math.max(1, ch.start), end = Math.max(start, ch.end);
      decos.push({ range: new monaco.Range(start, 1, end, 1), options: { isWholeLine: true, linesDecorationsClassName: cls,
        overviewRuler: { color: ch.type === "add" ? "#6AAB73" : ch.type === "mod" ? "#6897BB" : "#868A91", position: 1 } } });
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

// ---------- Diffs ----------
async function showDiff(path) {
  const r = rootOf(path); if (!r) return;
  const tab = S.tabs.find(t => t.path === path);
  let current = "";
  if (!tab && G.kind.get(path) !== "D") { try { current = (await api("read", { path })).content || ""; } catch {} }
  const res = await gitCall(r.path, "show", [relative(path, r)]);
  openDiff({ title: `${relative(path, r)}  ·  HEAD ↔ locale`, original: res.content || "", modified: current, model: tab ? tab.model : null, path });
}
async function diffWithRevision(path, rev, label) {
  const r = rootOf(path); if (!r) return;
  const tab = S.tabs.find(t => t.path === path);
  let current = "";
  if (!tab) { try { current = (await api("read", { path })).content || ""; } catch {} }
  const res = await gitCall(r.path, "show", [relative(path, r), rev]);
  if (!res.exists) toast(`${basename(path)} non esiste in ${label || rev}`);
  openDiff({ title: `${relative(path, r)}  ·  ${label || rev} ↔ locale`, original: res.content || "", modified: current, model: tab ? tab.model : null, path });
}
function compareWithBranch(path) {
  const r = rootOf(path); if (!r) return;
  loadBranches(r).then(b => {
    pickPalette(`Confronta ${basename(path)} con…`, [...(b.local || []), ...(b.remote || []), ...(b.tags || [])].map(x => ({
      label: x.name, sub: x.ref.startsWith("refs/tags/") ? "tag" : x.ref.startsWith("refs/remotes/") ? "remoto" : "locale",
      icon: x.ref.startsWith("refs/tags/") ? "tag" : "branch", run: () => diffWithRevision(path, x.name, x.name) })));
  });
}
function showFileHistory(path) { showToolWindow("git", { tab: "log", path }); }

// ---------- Branches popup (toolbar widget, like PhpStorm's) ----------
async function loadBranches(r) {
  try { const b = await gitCall(r.path, "branches"); G.branches.set(r.path, b); return b; }
  catch { return G.branches.get(r.path) || {}; }
}
const popExpanded = new Set(["recent", "local"]);
async function showBranchesPopup() {
  const r = cur(), st = repoOf(r);
  if (!r) { toast("Aggiungi prima un progetto"); return; }
  if (!st) { toast(`${r.name} non è un repository git`); return; }
  const p = openPopup($("#branchBtn"), "git-pop");
  const search = el("input", "pop-search"); search.placeholder = "Cerca branch e azioni"; search.spellcheck = false;
  const list = el("div", "pop-list");
  const foot = el("div", "pop-foot", `${r.name} · ${tilde(st.top)}`);
  p.append(search, list, foot);
  let b = G.branches.get(r.path) || { local: [], remote: [], tags: [], recent: [] };
  let sel = 0;
  const draw = () => {
    const q = search.value.trim().toLowerCase();
    list.innerHTML = "";
    const rows = [];
    const act = (ic, label, key, f) => ({ type: "action", ic, label, key, run: f });
    const actions = [
      act("update", "Update Project…", "⌘T", () => updateProject(r)), act("check", "Commit…", "⌘K", () => commitDialog()),
      act("push", "Push…", "⌘⇧K", () => pushNow(r)), null,
      act("branchNew", "Nuovo branch…", "⌥⌘N", () => newBranch(r)), act("tag", "Checkout tag o revisione…", "", () => checkoutRevision(r)),
    ];
    for (const a of actions) {
      if (!a) { if (!q) rows.push({ type: "sep" }); continue; }
      if (!q || a.label.toLowerCase().includes(q)) rows.push(a);
    }
    const section = (id, title, items, group) => {
      if (!items.length) return;
      const open = q || popExpanded.has(id);
      rows.push({ type: "head", id, label: title, open, depth: 0 });
      if (!open) return;
      if (!group) { items.forEach(x => rows.push({ type: "branch", b: x, label: x.name, depth: 1 })); return; }
      // Folders by "/" prefix (hotfix/…, feature/…, origin/…).
      const tree = {};
      for (const x of items) {
        const parts = x.name.split("/");
        let node = tree;
        for (let i = 0; i < parts.length - 1; i++) node = (node[parts[i] + "/"] = node[parts[i] + "/"] || {});
        (node.__ = node.__ || []).push({ x, leaf: parts[parts.length - 1] });
      }
      const walk = (node, depth, prefix) => {
        for (const k of Object.keys(node).filter(k => k !== "__").sort()) {
          const fid = id + ":" + prefix + k;
          const fopen = q || popExpanded.has(fid);
          rows.push({ type: "folder", id: fid, label: k.slice(0, -1), open: fopen, depth });
          if (fopen) walk(node[k], depth + 1, prefix + k);
        }
        for (const { x, leaf } of node.__ || []) rows.push({ type: "branch", b: x, label: leaf, depth });
      };
      walk(tree, 1, "");
    };
    const match = x => !q || x.name.toLowerCase().includes(q);
    const local = (b.local || []).filter(match), remote = (b.remote || []).filter(match), tags = (b.tags || []).filter(match);
    const recent = (b.recent || []).map(n => (b.local || []).find(x => x.name === n)).filter(Boolean).filter(match);
    if (!q) section("recent", "Recenti", recent, false);
    section("local", "Locali", local, true);
    section("remote", "Remoti", remote, true);
    section("tags", "Tag", tags.slice(0, 200), false);
    if (q && !rows.some(x => x.type === "branch" || x.type === "action")) list.append(el("div", "empty", "Nessun risultato."));
    const selectable = rows.map((x, i) => x.type !== "sep" ? i : -1).filter(i => i >= 0);
    if (!selectable.includes(sel)) sel = selectable[0] ?? 0;
    rows.forEach((x, i) => {
      if (x.type === "sep") { list.append(el("div", "pop-sep")); return; }
      const row = el("div", "pop-row " + x.type + (i === sel ? " on" : ""));
      row.style.paddingLeft = (10 + (x.depth || 0) * 14) + "px";
      const ic = el("span", "ic");
      if (x.type === "action") ic.innerHTML = icon(x.ic);
      else if (x.type === "head" || x.type === "folder") ic.innerHTML = icon(x.open ? "chevronDown" : "chevronRight");
      else ic.innerHTML = icon(x.b.current ? "tag" : x.b.ref.startsWith("refs/tags/") ? "tag" : "branch");
      if (x.type === "branch" && x.b.current) ic.classList.add("cur");
      row.append(ic);
      const lab = el("span", "lab"); lab.append(q && x.type !== "head" ? highlight(q, x.label) : x.label); row.append(lab);
      if (x.type === "action" && x.key) row.append(el("kbd", "", x.key));
      if (x.type === "branch") {
        const info = el("span", "info");
        const track = x.b.track || "";
        const ah = /ahead (\d+)/.exec(track), be = /behind (\d+)/.exec(track);
        if (ah) { const a = el("span", "ahead"); a.innerHTML = icon("arrowUp"); a.append(ah[1]); info.append(a); }
        if (be) { const c = el("span", "behind"); c.innerHTML = icon("arrowDown"); c.append(be[1]); info.append(c); }
        if (x.b.upstream) info.append(el("span", "up", x.b.upstream));
        if (track === "gone") info.append(el("span", "up", "remoto eliminato"));
        row.append(info);
        const chev = el("span", "chev"); chev.innerHTML = icon("chevronRight"); row.append(chev);
        row.title = `${x.b.name} · ${x.b.hash}${x.b.subject ? " · " + x.b.subject : ""}`;
      }
      row.onmouseenter = () => { if (sel !== i) { sel = i; list.querySelectorAll(".pop-row.on").forEach(o => o.classList.remove("on")); row.classList.add("on"); } };
      row.onclick = () => activateRow(x, row);
      list.append(row);
    });
    const on_ = list.querySelector(".pop-row.on"); if (on_) on_.scrollIntoView({ block: "nearest" });
    p._rows = rows;
  };
  const activateRow = (x, row) => {
    if (x.type === "action") { closePopup(); x.run(); }
    else if (x.type === "head" || x.type === "folder") { popExpanded.has(x.id) ? popExpanded.delete(x.id) : popExpanded.add(x.id); draw(); }
    else if (x.type === "branch") {
      const rr = row.getBoundingClientRect();
      closeMenus();
      openMenuAt(rr.right - 4, rr.top - 4, branchActions(r, x.b, b), 0, { keepPopup: false, side: rr.left });
    }
  };
  search.oninput = () => { sel = 0; draw(); };
  search.onkeydown = e => {
    const rows = p._rows || [];
    const step = d => { let i = sel; do { i += d; } while (rows[i] && rows[i].type === "sep"); if (rows[i]) { sel = i; draw(); } };
    if (e.key === "ArrowDown") { e.preventDefault(); step(1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); step(-1); }
    else if (e.key === "Enter" || e.key === "ArrowRight") {
      e.preventDefault();
      const x = rows[sel]; const row = list.querySelector(".pop-row.on");
      if (x && row && (e.key === "Enter" || x.type === "branch")) activateRow(x, row);
    } else if (e.key === "ArrowLeft") { const x = rows[sel]; if (x && x.open) { popExpanded.delete(x.id); draw(); } }
  };
  draw();
  search.focus();
  b = await loadBranches(r);
  if (document.body.contains(p)) draw();
  // Fresh remote state in the background, then redraw.
  fetchNow(r, true).then(async () => { b = await loadBranches(r); if (document.body.contains(p)) draw(); });
}
// The "›" submenu of a branch row.
function branchActions(r, x, all) {
  if (!validRef(x.name)) return [{ label: "Nome del ref non sicuro: ignorato", disabled: true }];
  const current = all.current || (repoOf(r) || {}).branch;
  const isLocal = x.ref.startsWith("refs/heads/"), isRemote = x.ref.startsWith("refs/remotes/"), isTag = x.ref.startsWith("refs/tags/");
  const n = x.name, same = isLocal && n === current;
  const remoteName = isRemote ? n.split("/")[0] : "", remoteBranch = isRemote ? n.split("/").slice(1).join("/") : "";
  return [
    !same && { label: "Checkout", action: () => checkoutRef(r, x, all) },
    { label: `Nuovo branch da «${n}»…`, icon: "branchNew", action: () => newBranch(r, n) },
    isLocal && !same && { label: `Checkout e rebase su «${current}»`, action: async () => {
      if (!(await confirm_(`Checkout di ${n} e rebase su ${current}?`, "I commit di " + n + " vengono riscritti sopra " + current + ".", "Rebase"))) return;
      afterGitOp(r, await gitRaw(r.path, ["rebase", current, n]), "Rebase fatto");
    } },
    null,
    !same && { label: `Confronta con «${current}»`, icon: "diff", action: () => compareRefs(r, n, current) },
    { label: "Mostra diff con la working tree", icon: "diff", action: () => diffWithWorkingTree(r, n) },
    { label: "Mostra nel log", icon: "history", action: () => showToolWindow("git", { tab: "log", branch: n }) },
    null,
    !same && { label: `Rebase di «${current}» su «${n}»`, action: async () => {
      if (!(await confirm_(`Rebase di ${current} su ${n}?`, "I tuoi commit locali vengono riscritti sopra " + n + ".", "Rebase"))) return;
      afterGitOp(r, await gitRaw(r.path, ["rebase", n]), "Rebase fatto");
    } },
    !same && { label: `Merge di «${n}» in «${current}»`, icon: "merge", action: async () => afterGitOp(r, await gitRaw(r.path, ["merge", "--no-edit", n]), "Merge fatto") },
    isRemote && { label: `Pull in «${current}» con rebase`, action: async () => afterGitOp(r, await gitRaw(r.path, ["pull", "--rebase", "--autostash", remoteName, remoteBranch], { timeout: 180 }), "Pull fatto") },
    isRemote && { label: `Pull in «${current}» con merge`, action: async () => afterGitOp(r, await gitRaw(r.path, ["pull", "--no-rebase", "--autostash", remoteName, remoteBranch], { timeout: 180 }), "Pull fatto") },
    isLocal && null,
    isLocal && { label: "Push…", icon: "push", action: () => same ? pushNow(r) : pushBranch(r, n, all) },
    isLocal && { label: "Rinomina…", icon: "edit", action: async () => {
      const to = await prompt_(`Rinomina ${n}`, n); if (!to || to === n) return;
      if (!validRef(to)) { toast("Nome di branch non valido", "error"); return; }
      afterGitOp(r, await gitRaw(r.path, ["branch", "-m", n, to]), `Rinominato in ${to}`);
    } },
    null,
    !same && { label: isTag ? "Elimina il tag" : isRemote ? "Elimina il branch remoto…" : "Elimina", icon: "trash", danger: true, action: () => deleteRef(r, x) },
  ];
}
async function checkoutRef(r, x, all) {
  await saveAllQuiet();
  let args;
  if (x.ref.startsWith("refs/remotes/")) {
    const local = x.name.split("/").slice(1).join("/");
    args = (all.local || []).some(l => l.name === local) ? ["checkout", local] : ["checkout", "--track", x.name];
  } else if (x.ref.startsWith("refs/tags/")) {
    if (!(await confirm_(`Checkout del tag ${x.name}?`, "Sarai in «detached HEAD»: per lavorarci crea un branch.", "Checkout"))) return;
    args = ["checkout", x.name];
  } else args = ["checkout", x.name];
  await checkoutArgs(r, args);
}
// Checkout that, if local changes are in the way, offers PhpStorm's "smart checkout" (stash → checkout → unstash).
async function checkoutArgs(r, args) {
  let res = await gitRaw(r.path, args);
  if (!res.ok && /would be overwritten|commit your changes or stash/i.test(res.output)) {
    if (await confirm_("Le modifiche locali bloccano il checkout", "Le metto da parte (stash), faccio il checkout e le rimetto (smart checkout)?", "Smart checkout")) {
      const s = await gitRaw(r.path, ["stash", "push", "-u", "-m", "elio: smart checkout"]);
      if (!s.ok) { toast(s.output, "error"); return; }
      res = await gitRaw(r.path, args);
      const pop = await gitRaw(r.path, ["stash", "pop"]);
      if (!pop.ok) toast("Checkout fatto, ma lo stash ha conflitti: risolvili e poi «git stash drop».", "error");
    } else return;
  }
  afterGitOp(r, res, `Checkout: ${args[args.length - 1]}`);
}
async function deleteRef(r, x) {
  if (x.ref.startsWith("refs/tags/")) {
    if (!(await confirm_(`Elimino il tag ${x.name}?`, "Solo in locale.", "Elimina", { danger: true }))) return;
    return afterGitOp(r, await gitRaw(r.path, ["tag", "-d", x.name]), "Tag eliminato");
  }
  if (x.ref.startsWith("refs/remotes/")) {
    const [remote, ...rest] = x.name.split("/");
    if (!(await confirm_(`Elimino ${rest.join("/")} dal remoto ${remote}?`, "Il branch sparisce dal server per tutti.", "Elimina dal remoto", { danger: true }))) return;
    return afterGitOp(r, await gitRaw(r.path, ["push", remote, "--delete", rest.join("/")], { timeout: 120 }), "Branch remoto eliminato");
  }
  if (!(await confirm_(`Elimino il branch ${x.name}?`, "Solo il branch locale.", "Elimina", { danger: true }))) return;
  let res = await gitRaw(r.path, ["branch", "-d", x.name]);
  if (!res.ok && /not fully merged/i.test(res.output)) {
    if (!(await confirm_(`${x.name} ha commit non uniti altrove`, "Eliminandolo li perdi (restano recuperabili solo dal reflog). Elimino comunque?", "Elimina comunque", { danger: true }))) return;
    res = await gitRaw(r.path, ["branch", "-D", x.name]);
  }
  afterGitOp(r, res, "Branch eliminato");
}
async function pushBranch(r, name, all) {
  const remotes = all.remotes || ["origin"];
  if (!(await confirm_(`Push di ${name} su ${remotes[0]}?`, "Senza force.", "Push"))) return;
  afterGitOp(r, await gitRaw(r.path, ["push", "-u", remotes[0], name], { timeout: 180 }), "Push fatto");
}
// After a branch operation: report, refresh git state, the tree and the open files' HEAD.
function afterGitOp(r, res, okText) {
  if (res.ok) toast(okText, "ok"); else toast((res.output || "Operazione non riuscita").slice(0, 600), "error");
  treeCache.clear();
  renderTree();
  refreshGit(r);
  S.tabs.filter(t => !t.virtual && rootOf(t.path) === r).forEach(loadHead);
  emitLocal("headMoved", { root: r.path });
  return res;
}
async function compareRefs(r, a, b) {
  const [ina, inb] = await Promise.all([
    gitRaw(r.path, ["log", "--format=%h%x1f%s%x1f%an%x1f%ar", `${b}..${a}`, "-n", "300"]),
    gitRaw(r.path, ["log", "--format=%h%x1f%s%x1f%an%x1f%ar", `${a}..${b}`, "-n", "300"]),
  ]);
  const body = openDialog("wide");
  body.append(el("h3", "", `Confronto ${a} ↔ ${b}`));
  const sect = (title, res) => {
    const lines = (res.output || "").split("\n").filter(Boolean);
    body.append(el("div", "sect-title", `${title} (${lines.length})`));
    const box = el("div", "files");
    if (!lines.length) box.append(el("div", "empty", "Nessun commit."));
    for (const l of lines) {
      const [h, s, au, when] = l.split("\u001f");
      const row = el("div", "commit-line"); row.append(el("span", "h", h), el("span", "s", s), el("span", "a", au), el("span", "w", when));
      row.onclick = () => { closeDialog(); showToolWindow("git", { tab: "log", select: h }); };
      box.append(row);
    }
    body.append(box);
  };
  sect(`In ${a} ma non in ${b}`, ina);
  sect(`In ${b} ma non in ${a}`, inb);
  const btns = el("div", "row-btn"); const ok = el("button", "btn go", "Chiudi"); ok.onclick = closeDialog; btns.append(ok); body.append(btns);
}
async function diffWithWorkingTree(r, ref) {
  const res = await gitRaw(r.path, ["diff", "--name-status", "-M", ref]);
  const st = repoOf(r);
  const lines = (res.output || "").split("\n").filter(Boolean);
  const body = openDialog("wide");
  body.append(el("h3", "", `Differenze tra ${ref} e la working tree (${lines.length})`));
  const box = el("div", "files tall");
  if (!lines.length) box.append(el("div", "empty", "Nessuna differenza."));
  for (const l of lines) {
    const parts = l.split("\t"); const code = parts[0][0]; const p = parts[parts.length - 1];
    const abs = (st ? st.top : r.path) + "/" + p;
    const row = el("div", "chg"); const ic = el("span", "ic"); ic.innerHTML = fileIcon(basename(p), false);
    row.append(el("span", "code " + code, code), ic, el("span", "p", basename(p)), el("span", "dir", dirname(p)));
    row.onclick = () => { closeDialog(); diffWithRevision(abs, ref, ref); };
    box.append(row);
  }
  body.append(box);
  const btns = el("div", "row-btn"); const ok = el("button", "btn go", "Chiudi"); ok.onclick = closeDialog; btns.append(ok); body.append(btns);
}

// ---------- Palette helpers (branches, revisions, generic pick) ----------
function pickPalette(title, items) {
  showPalette("pick");
  $("#palTitle").textContent = title;
  pal.pick = items;
  updatePalette();
}
async function loadBranchesForPalette() { const r = cur(); if (!r) return; await loadBranches(r); updatePalette(); }
async function loadTagsForPalette() { const r = cur(); if (!r) return; await loadBranches(r); updatePalette(); }
function branchPaletteItems(q, mode) {
  const r = cur(); if (!r) return [];
  const b = G.branches.get(r.path) || {};
  const out = [];
  if (mode === "revision") {
    if (q && validRef(q)) out.push({ kind: "commit", label: `Checkout di «${q}»`, sub: "hash, tag o espressione (HEAD~2)", q: "", run: async () => {
      if (!(await confirm_(`Checkout di ${q}?`, "Sarai in «detached HEAD»: per lavorarci crea un branch.", "Checkout"))) return;
      await saveAllQuiet(); checkoutArgs(r, ["checkout", q]);
    } });
    for (const t of (b.tags || []).filter(t => fuzzy(q, t.name) > 0).slice(0, 80))
      out.push({ kind: "tag", label: t.name, sub: t.hash, q, run: () => checkoutRef(r, t, b) });
    return out;
  }
  for (const x of [...(b.local || []), ...(b.remote || [])].filter(x => validRef(x.name) && fuzzy(q, x.name) > 0).slice(0, 120))
    out.push({ kind: "branch", label: x.name, sub: x.current ? "attuale" : x.ref.startsWith("refs/remotes/") ? "remoto" : x.upstream, q,
      run: () => x.current ? null : checkoutRef(r, x, b) });
  return out;
}

// ---------- New branch / checkout revision / update / fetch ----------
async function newBranch(r = cur(), from = null) {
  const st = repoOf(r); if (!st) { toast("Non è un repository git"); return; }
  if (from && !validRef(from)) { toast("Nome del ref non sicuro", "error"); return; }
  const body = openDialog();
  body.append(el("h3", "", from ? `Nuovo branch da ${from}` : `Nuovo branch da ${st.branch}`));
  const input = el("input"); input.type = "text"; input.placeholder = "es. feature/DNA-123-checkout";
  const lab = el("label", "check"); const cb = el("input"); cb.type = "checkbox"; cb.checked = true; lab.append(cb, " Fai il checkout del branch");
  const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn go", "Crea");
  btns.append(no, ok); body.append(input, lab, btns); input.focus();
  const go = async () => {
    const name = input.value.trim().replace(/\s+/g, "-"); if (!name) { input.focus(); return; }
    if (!validRef(name)) { toast("Nome di branch non valido", "error"); input.focus(); return; }
    closeDialog();
    await saveAllQuiet();
    const args = cb.checked ? ["checkout", "-b", name] : ["branch", name];
    if (from) args.push(from);
    afterGitOp(r, await gitRaw(r.path, args), cb.checked ? `Su ${name}` : `Creato ${name}`);
  };
  no.onclick = closeDialog; ok.onclick = go;
  input.onkeydown = e => { if (e.key === "Enter") go(); if (e.key === "Escape") closeDialog(); };
}
function checkoutRevision() { showPalette("revision"); }
async function updateProject(r = cur()) {
  const repos = distinctRepos();
  if (!repoOf(r) && !repos.length) { toast("Non è un repository git"); return; }
  const body = openDialog();
  body.append(el("h3", "", "Update Project"));
  const mode = store.get("updateMode", "merge");
  const opt = (v, label, note) => { const l = el("label", "radio"); const i = el("input"); i.type = "radio"; i.name = "upd"; i.value = v; i.checked = mode === v;
    l.append(i, el("b", "", label), el("span", "note", note)); return l; };
  body.append(opt("merge", "Merge", "unisce i commit in arrivo (git pull --no-rebase)"), opt("rebase", "Rebase", "rimette i tuoi commit locali sopra quelli in arrivo (git pull --rebase)"));
  let allCb = null;
  if (repos.length > 1) { const l = el("label", "check"); allCb = el("input"); allCb.type = "checkbox"; allCb.checked = true; l.append(allCb, ` Tutti i repository del workspace (${repos.length})`); body.append(l); }
  body.append(el("div", "note", "Le modifiche locali vengono messe da parte e rimesse (autostash)."));
  const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn go", "OK");
  btns.append(no, ok); body.append(btns); ok.focus();
  no.onclick = closeDialog;
  ok.onclick = async () => {
    const m = body.querySelector("input[name=upd]:checked").value;
    store.set("updateMode", m);
    closeDialog();
    await saveAllQuiet();
    const targets = allCb && allCb.checked ? repos.map(x => x.root) : [r];
    for (const t of targets) {
      status(`Aggiorno ${t.name}…`);
      const res = await gitCall(t.path, "pull", m === "rebase" ? ["--rebase"] : ["--merge"]);
      logGit(t.path, `git pull ${m === "rebase" ? "--rebase" : "--no-rebase"} --autostash`, res);
      afterGitOp(t, res, /Already up to date|Already up-to-date|Current branch .* is up to date/i.test(res.output) ? `${t.name}: già aggiornato` : `${t.name} aggiornato`);
    }
    status("");
  };
}
async function fetchNow(r, background) {
  if (!r || !repoOf(r)) return;
  const res = await gitCall(r.path, "fetch", [], { background: !!background });
  if (!background) { logGit(r.path, "git fetch --all --prune", res); toast(res.ok ? "Fetch fatto" : (res.output || "Fetch non riuscito").slice(0, 400), res.ok ? "ok" : "error"); }
  refreshGit(r);
}
// Periodic fetch (5 min): ahead/behind arrows stay true without pulling anything.
setInterval(() => { for (const { root } of distinctRepos()) fetchNow(root, true); }, 5 * 60 * 1000);
setInterval(() => { if (document.visibilityState !== "hidden") refreshGitAll(); }, 30000);

// ---------- Push ----------
async function pushNow(r = cur()) {
  const st = repoOf(r); if (!st) { toast("Non è un repository git"); return; }
  await saveAllQuiet();
  const info = await gitCall(r.path, "pushInfo");
  const body = openDialog("wide");
  const target = info.upstream || `${(info.remotes || ["origin"])[0]}/${info.branch} (nuovo)`;
  body.append(el("h3", "", `Push di ${info.branch} → ${target}`));
  const box = el("div", "files");
  if (!(info.commits || []).length) box.append(el("div", "empty", "Niente da inviare: il remoto ha già tutti i tuoi commit."));
  for (const c of info.commits || []) {
    const row = el("div", "commit-line"); row.append(el("span", "h", c.hash), el("span", "s", c.subject), el("span", "a", c.author), el("span", "w", c.when));
    box.append(row);
  }
  body.append(el("div", "sect-title", `${(info.commits || []).length} commit`), box);
  let remoteSel = null;
  if (!info.upstream) {
    const l = el("label", "check"); remoteSel = el("select");
    (info.remotes || []).forEach(x => remoteSel.append(Object.assign(el("option", "", x), { value: x })));
    l.append("Remoto: ", remoteSel, el("span", "note", " (imposta anche l'upstream)"));
    body.append(l);
  }
  const fl = el("label", "check"); const force = el("input"); force.type = "checkbox"; fl.append(force, " Force push (--force-with-lease)");
  body.append(fl);
  const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn go", "Push");
  btns.append(no, ok); body.append(btns);
  ok.disabled = !(info.commits || []).length && info.upstream;
  force.onchange = () => { ok.disabled = !force.checked && !(info.commits || []).length && !!info.upstream; ok.className = "btn " + (force.checked ? "danger-go" : "go"); };
  ok.focus();
  no.onclick = closeDialog;
  ok.onclick = async () => {
    const f = force.checked, remote = remoteSel ? remoteSel.value : null;
    closeDialog();
    if (f && !(await confirm_(`Force push di ${info.branch}?`, "Riscrive la storia sul server: chi ha già scaricato questi commit dovrà riallinearsi.", "Force push", { danger: true }))) return;
    const args = [];
    if (f) args.push("--force-with-lease");
    if (remote) args.push("-u", remote, info.branch);
    status("Push in corso…");
    const res = await gitCall(r.path, "push", args);
    logGit(r.path, "git push " + args.join(" "), res);
    status("");
    toast(res.ok ? "Push fatto" : "Push non riuscito: " + (res.output || "").slice(0, 400), res.ok ? "ok" : "error");
    refreshGit(r);
  };
}

// ---------- Commit tool window ----------
registerToolWindow({
  id: "commit", title: "Commit", icon: "commit", side: "left", slot: "top", order: 20, key: "⌘0",
  mount: mountCommitPanel,
  onShow() { refreshGitAll(); renderCommitPanel(); },
  focus() { const m = document.querySelector(".cm-msg"); if (m) m.focus(); },
  badge: () => { let n = 0; for (const { st } of distinctRepos()) n += (st.files || []).length; return n ? { text: n > 99 ? "99+" : String(n), kind: "info" } : null; },
  actions: () => [
    { icon: "refresh", title: "Aggiorna", action: () => refreshGitAll() },
    { icon: "rollback", title: "Rollback dei file selezionati…", action: () => rollbackChecked() },
    { icon: "diff", title: "Mostra diff del file selezionato", action: () => G.cmSel && showDiff(G.cmSel) },
    { icon: "expandAll", title: "Seleziona tutte le modifiche", action: () => { for (const { st } of distinctRepos()) (st.files || []).forEach(f => G.checked.set(f.path, f.kind !== "U")); renderCommitPanel(); } },
  ],
});
const cm = {};
function mountCommitPanel(box) {
  box.classList.add("commit-pane");
  cm.list = el("div", "cm-list");
  const bottom = el("div", "cm-bottom");
  const amendL = el("label", "check"); cm.amend = el("input"); cm.amend.type = "checkbox"; amendL.append(cm.amend, " Modifica l'ultimo commit (amend)");
  cm.msg = el("textarea", "cm-msg"); cm.msg.placeholder = "Messaggio del commit"; cm.msg.rows = 4; cm.msg.spellcheck = true;
  const btns = el("div", "cm-btns");
  cm.commit = el("button", "btn go", "Commit"); cm.push = el("button", "btn", "Commit e push…");
  cm.info = el("span", "cm-info");
  btns.append(cm.commit, cm.push, cm.info);
  bottom.append(amendL, cm.msg, btns);
  box.append(cm.list, bottom);
  cm.msg.oninput = () => { const k = draftKey(); if (k) store.set(k, cm.msg.value); };
  cm.msg.onkeydown = e => { if (e.key === "Enter" && e.metaKey) { e.preventDefault(); doCommit(e.shiftKey || e.altKey); } };
  cm.amend.onchange = async () => {
    const r = cur();
    if (cm.amend.checked && !cm.msg.value.trim() && r) {
      const res = await gitRaw(r.path, ["log", "-1", "--format=%B"]);
      if (res.ok) cm.msg.value = res.output.trim();
    }
    updateCommitInfo();
  };
  cm.commit.onclick = () => doCommit(false);
  cm.push.onclick = () => doCommit(true);
  on("projectChanged", () => { const k = draftKey(); if (k && TW.get("commit").visible && document.activeElement !== cm.msg) cm.msg.value = store.get(k, ""); });
  cm.msg.value = store.get(draftKey() || "-", "");
}
function draftKey() { const st = repoOf(cur()); return st ? "commitDraft." + st.top : null; }
function renderCommitPanel() {
  if (!cm.list) return;
  const list = cm.list; const keep = list.scrollTop;
  list.innerHTML = "";
  const repos = distinctRepos();
  if (!repos.length) { list.append(el("div", "empty", S.roots.length ? "Nessun repository git nel workspace." : "Nessun progetto.")); updateCommitInfo(); return; }
  for (const { root, st } of repos) {
    const files = st.files || [];
    for (const f of files) if (!G.checked.has(f.path)) G.checked.set(f.path, f.kind !== "U");
    if (repos.length > 1) {
      const h = el("div", "cm-repo"); h.innerHTML = icon("git"); h.append(el("b", "", root.name), el("span", "", st.branch));
      list.append(h);
    }
    const tracked = files.filter(f => f.kind !== "U"), untracked = files.filter(f => f.kind === "U");
    group(list, root, st, "Modifiche", tracked, true);
    group(list, root, st, "File non versionati", untracked, false);
    if (!files.length) list.append(el("div", "empty", "Nessuna modifica. Il branch è pulito."));
  }
  list.scrollTop = keep;
  updateCommitInfo();
}
function group(list, root, st, title, files, openDefault) {
  if (!files.length) return;
  const key = "cmGroup." + title;
  const open = store.get(key, openDefault || files.length < 50);
  const head = el("div", "cm-group");
  const tw = el("span", "tw"); tw.innerHTML = icon(open ? "chevronDown" : "chevronRight");
  const cb = el("input"); cb.type = "checkbox";
  const n = files.filter(f => G.checked.get(f.path)).length;
  cb.checked = n === files.length; cb.indeterminate = n > 0 && n < files.length;
  cb.onclick = e => { e.stopPropagation(); files.forEach(f => G.checked.set(f.path, cb.checked)); renderCommitPanel(); };
  head.append(tw, cb, el("span", "t", title), el("span", "n", `${files.length} file`));
  head.onclick = () => { store.set(key, !open); renderCommitPanel(); };
  list.append(head);
  if (!open) return;
  for (const f of files.slice(0, 3000)) {
    const row = el("div", "cm-file g-" + f.kind + (G.cmSel === f.path ? " sel" : ""));
    const c = el("input"); c.type = "checkbox"; c.checked = !!G.checked.get(f.path);
    c.onclick = e => { e.stopPropagation(); G.checked.set(f.path, c.checked); renderCommitPanel(); };
    const ic = el("span", "ic"); ic.innerHTML = fileIcon(basename(f.path), false);
    const rel = f.path.startsWith(root.path + "/") ? relative(f.path, root) : f.path.slice(st.top.length + 1);
    row.append(c, ic, el("span", "p", basename(f.path)), el("span", "dir", dirname(rel)));
    if (f.from) row.append(el("span", "dir", `← ${basename(f.from)}`));
    row.title = `${rel} · ${KIND_LABEL[f.kind] || f.kind}`;
    row.onclick = () => { G.cmSel = f.path; renderCommitPanel(); if (f.kind !== "U") showDiff(f.path); else openFile(f.path); };
    row.ondblclick = () => f.kind !== "D" && openFile(f.path);
    row.oncontextmenu = e => { e.preventDefault(); G.cmSel = f.path; menu(e, [
      f.kind !== "U" && { label: "Mostra diff", icon: "diff", action: () => showDiff(f.path) },
      f.kind !== "D" && { label: "Apri", action: () => openFile(f.path) },
      f.kind !== "D" && { label: "Mostra nell'albero", icon: "locate", action: () => revealInTree(f.path) },
      null,
      f.kind === "U" && { label: "Aggiungi a Git", icon: "plus", action: async () => { await gitRaw(root.path, ["add", "--", f.path]); refreshGit(root); } },
      f.kind === "U" && { label: "Aggiungi a .gitignore", action: () => addToGitignore(root, f.path) },
      f.kind !== "U" && { label: "Rollback…", icon: "rollback", action: () => rollback(root, [f.path]) },
      f.kind === "U" && { label: "Sposta nel Cestino", icon: "trash", danger: true, action: () => trashEntry({ name: basename(f.path), path: f.path }) },
      null,
      { label: "Storia del file", icon: "history", action: () => showFileHistory(f.path) },
      { label: "Copia percorso", icon: "copy", action: () => copy(f.path) },
    ]); };
    list.append(row);
  }
}
function updateCommitInfo() {
  if (!cm.info) return;
  let n = 0; for (const { st } of distinctRepos()) n += (st.files || []).filter(f => G.checked.get(f.path)).length;
  cm.info.textContent = n ? `${n} file` : cm.amend && cm.amend.checked ? "solo messaggio" : "";
  const k = draftKey(); if (k && document.activeElement !== cm.msg && !cm.msg.value) cm.msg.value = store.get(k, "");
}
async function commitDialog() {
  if (!distinctRepos().length) { await refreshGitAll(); if (!distinctRepos().length) { toast("Nessun repository git nel workspace."); return; } }
  await saveAllQuiet();
  showToolWindow("commit");
  await refreshGitAll();
  renderCommitPanel();
  setTimeout(() => { cm.msg.focus(); }, 30);
}
async function doCommit(withPush) {
  const message = cm.msg.value.trim();
  if (!message) { cm.msg.focus(); toast("Scrivi il messaggio del commit"); return; }
  await saveAllQuiet();
  const amend = cm.amend.checked;
  const done = [];
  for (const { root, st } of distinctRepos()) {
    const files = st.files || [];
    const chosen = files.filter(f => G.checked.get(f.path));
    if (!chosen.length && !(amend && root === cur())) continue;
    const opts = { message, amend, paths: chosen.filter(f => f.kind !== "U").map(f => f.path),
      untracked: chosen.filter(f => f.kind === "U").map(f => f.path), all: chosen.length === files.length && files.length > 0 };
    if (opts.untracked.length) opts.paths = opts.paths.concat(opts.untracked);
    cm.commit.disabled = cm.push.disabled = true;
    const res = await gitCall(root.path, "commit", [], opts);
    cm.commit.disabled = cm.push.disabled = false;
    logGit(root.path, `git commit${amend ? " --amend" : ""} (${chosen.length} file)`, res);
    if (!res.ok) { toast(`Commit non riuscito su ${root.name}: ` + (res.output || "").slice(0, 500), "error"); return; }
    done.push(root);
    chosen.forEach(f => G.checked.delete(f.path));
  }
  if (!done.length) { toast("Scegli almeno un file"); return; }
  cm.msg.value = ""; cm.amend.checked = false;
  done.forEach(r => { const st = repoOf(r); if (st) store.set("commitDraft." + st.top, ""); });
  toast(done.length > 1 ? `Commit fatto in ${done.length} repository` : "Commit fatto", "ok");
  for (const r of done) { await refreshGit(r); S.tabs.filter(t => !t.virtual && rootOf(t.path) === r).forEach(loadHead); }
  emitLocal("headMoved", {});
  if (withPush) await pushNow(done[0]);
}
async function rollback(root, paths) {
  const names = paths.map(p => basename(p));
  if (!(await confirm_(`Rollback di ${paths.length === 1 ? names[0] : paths.length + " file"}?`,
    (paths.length > 1 ? names.slice(0, 8).join(", ") + (paths.length > 8 ? "…" : "") + ". " : "") + "Tornano come nell'ultimo commit. Non si può annullare.", "Rollback", { danger: true }))) return;
  const added = paths.filter(p => G.kind.get(p) === "A");
  const res = await gitCall(root.path, "rollback", paths, { added });
  logGit(root.path, "git checkout HEAD -- " + names.join(" "), res);
  if (!res.ok) toast(res.output, "error"); else toast("Rollback fatto", "ok");
  refreshGit(root);
}
async function rollbackChecked() {
  for (const { root, st } of distinctRepos()) {
    const chosen = (st.files || []).filter(f => G.checked.get(f.path) && f.kind !== "U").map(f => f.path);
    if (chosen.length) await rollback(root, chosen);
  }
}
async function addToGitignore(root, path) {
  const st = repoOf(root); if (!st) return;
  const file = st.top + "/.gitignore";
  let text = ""; try { text = (await api("read", { path: file })).content || ""; } catch {}
  const line = "/" + path.slice(st.top.length + 1);
  try { await api("write", { path: file, content: text + (text && !text.endsWith("\n") ? "\n" : "") + line + "\n" }); toast(`${line} aggiunto a .gitignore`, "ok"); refreshGit(root); }
  catch (e) { toast(e.message, "error"); }
}
// Git submenu of the project tree's context menu.
function gitTreeItems(it) {
  const r = rootOf(it.path), st = repoOf(r);
  if (!st) return null;
  const k = G.kind.get(it.path), dk = it.dir ? G.dirs.get(it.path) : null;
  return [
    k === "U" && { label: "Aggiungi a Git", icon: "plus", action: async () => { await gitRaw(r.path, ["add", "--", it.path]); refreshGit(r); } },
    k === "U" && { label: "Aggiungi a .gitignore", action: () => addToGitignore(r, it.path) },
    !it.dir && k && k !== "U" && { label: "Mostra diff", icon: "diff", action: () => showDiff(it.path) },
    ((k && k !== "U") || (dk && dk !== "U")) && { label: "Rollback…", icon: "rollback", danger: true, action: () => rollback(r, it.dir ? (st.files || []).filter(f => f.kind !== "U" && f.path.startsWith(it.path + "/")).map(f => f.path) : [it.path]) },
    null,
    { label: "Storia " + (it.dir ? "della cartella" : "del file"), icon: "history", action: () => showFileHistory(it.path) },
    !it.dir && { label: "Confronta con branch…", icon: "diff", action: () => compareWithBranch(it.path) },
    !it.dir && { label: "Annota (blame)", icon: "annotate", action: async () => { await openFile(it.path); if (!G.blameOn) toggleBlame(); } },
  ];
}

// ---------- Blame ("Annota con Git blame") ----------
let blameStyle = null;
const blameRules = new Set();
function toggleBlame() {
  G.blameOn = !G.blameOn;
  blameRefresh();
  toast(G.blameOn ? "Blame attivo: clic sull'annotazione per vedere il commit" : "Blame disattivato");
}
async function blameRefresh() {
  if (!editor) return;
  const t = S.active;
  for (const x of S.tabs) if (x !== t && x.blameIds && x.model && !x.model.isDisposed()) { x.model.deltaDecorations(x.blameIds, []); x.blameIds = null; }
  if (!G.blameOn || !t || t.virtual) {
    if (t && t.blameIds) { t.blameIds = editor.deltaDecorations(t.blameIds, []); }
    editor.updateOptions({ lineDecorationsWidth: 10 });
    return;
  }
  const r = rootOf(t.path); if (!r) return;
  const res = await gitCall(r.path, "blame", [t.path]);
  if (S.active !== t || !G.blameOn) return;
  if (!res.ok) { toast("Blame non disponibile: " + (res.output || "file non versionato").slice(0, 200), "error"); G.blameOn = false; return; }
  if (!blameStyle) { blameStyle = el("style"); document.head.append(blameStyle); }
  const rules = [];
  for (const [h, c] of Object.entries(res.commits)) {
    if (blameRules.has(h)) continue;
    blameRules.add(h);
    const who = (c.author || "").split(" ")[0].slice(0, 12);
    const label = h.startsWith("0000000") ? "non committato" : `${fmtDate(c.at || 0)}  ${who}`;
    rules.push(`.bl-${h.slice(0, 12)}::after{content:${JSON.stringify(label)}}`);
  }
  if (rules.length) blameStyle.append(document.createTextNode(rules.join("\n")));
  t.blame = res;
  const decos = res.lines.map((h, i) => ({ range: new monaco.Range(i + 1, 1, i + 1, 1),
    options: { linesDecorationsClassName: `bl bl-${h.slice(0, 12)}${i > 0 && res.lines[i - 1] === h ? " cont" : ""}` } }));
  editor.updateOptions({ lineDecorationsWidth: 170 });
  t.blameIds = editor.deltaDecorations(t.blameIds || [], decos);
}
onBoot(() => {
  editor.onMouseDown(e => {
    if (!G.blameOn || !S.active || !S.active.blame || !e.target.position) return;
    if (e.target.type !== monaco.editor.MouseTargetType.GUTTER_LINE_DECORATIONS) return;
    const h = S.active.blame.lines[e.target.position.lineNumber - 1];
    if (h && !h.startsWith("0000000")) showToolWindow("git", { tab: "log", select: h, root: rootOf(S.active.path) });
  });
  editor.onMouseMove(e => {
    if (!G.blameOn || !S.active || !S.active.blame || !e.target.position || e.target.type !== monaco.editor.MouseTargetType.GUTTER_LINE_DECORATIONS) return;
    const h = S.active.blame.lines[e.target.position.lineNumber - 1]; const c = h && S.active.blame.commits[h];
    if (c) status(`${h.slice(0, 8)} · ${c.author} · ${fmtDate(c.at || 0, true)} · ${c.summary || ""}`);
  });
  on("saved", () => { if (G.blameOn) blameRefresh(); });
  refreshGitAll().then(() => { for (const { root } of distinctRepos()) fetchNow(root, true); });
});
