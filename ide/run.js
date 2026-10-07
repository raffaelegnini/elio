"use strict";
// Run: the project's scripts (package.json, composer.json, Makefile, DDEV/Magento, SwiftPM) plus run configurations the
// user saves per project (Swift keeps them in Application Support). Each run is a terminal tab with stop / rerun.

const R = { root: null, detected: [], saved: [], sessions: [], session: null, last: store.get("runLast", {}) };
const rw = {};

registerToolWindow({
  id: "run", title: "Esegui", icon: "run", side: "bottom", slot: "bottom", order: 10, key: "⌘4",
  mount(box) {
    box.classList.add("run-pane");
    rw.configs = el("div", "run-configs");
    rw.sessions = el("div", "run-sessions");
    rw.empty = el("div", "empty", "Scegli uno script a sinistra per eseguirlo.");
    rw.sessions.append(rw.empty);
    box.append(rw.configs, rw.sessions);
    loadRunConfigs();
  },
  onShow() { if (R.root !== cur()) loadRunConfigs(); renderRunTabs(); fitRun(); },
  actions: () => [
    { icon: "plus", title: "Nuova configurazione…", action: () => editRunConfig() },
    { icon: "refresh", title: "Rileva di nuovo gli script", action: () => loadRunConfigs() },
    R.session && { separator: true },
    R.session && { icon: "rerun", title: "Riesegui", action: () => rerun(R.session) },
    R.session && !R.session.dead && { icon: "stop", title: "Ferma", action: () => stopRun(R.session) },
  ],
});
// Only when visible: fitting a hidden xterm would shrink it to one row.
function fitRun() { if (R.session && R.session.fit) setTimeout(() => { if (R.session && R.session.el && R.session.el.offsetWidth) { try { R.session.fit.fit(); } catch {} } }, 20); }
on("layout", fitRun);
on("projectChanged", () => { if (rw.configs && TW.get("run").visible) loadRunConfigs(); renderRunWidget(); });

async function loadRunConfigs() {
  const r = cur(); R.root = r;
  renderRunWidget();
  if (!r) { R.detected = []; R.saved = []; renderRunConfigs(); return; }
  const [d, s] = await Promise.all([api("runScripts", { root: r.path }).catch(() => []), api("runConfigs.get", { root: r.path }).catch(() => [])]);
  if (R.root !== r) return;
  R.detected = d || []; R.saved = s || [];
  renderRunConfigs(); renderRunWidget();
}
function renderRunConfigs() {
  if (!rw.configs) return;
  const box = rw.configs; box.innerHTML = "";
  if (!R.root) { box.append(el("div", "empty", "Nessun progetto.")); return; }
  const groups = [["Le mie configurazioni", R.saved.map(c => ({ ...c, saved: true }))]];
  const byGroup = new Map();
  for (const c of R.detected) { if (!byGroup.has(c.group)) byGroup.set(c.group, []); byGroup.get(c.group).push(c); }
  groups.push(...byGroup.entries());
  for (const [title, list] of groups) {
    if (!list.length && title !== "Le mie configurazioni") continue;
    const h = el("div", "run-group", title); box.append(h);
    if (!list.length) { const e = el("div", "run-hint", "Nessuna. "); const a = el("span", "link", "Creane una"); a.onclick = () => editRunConfig(); e.append(a); box.append(e); continue; }
    for (const c of list) {
      const row = el("div", "run-row");
      const play = el("button", "tb-ico play"); play.innerHTML = icon("run"); play.title = "Esegui";
      play.onclick = e => { e.stopPropagation(); runConfig(c); };
      row.append(play, el("span", "nm", c.name), el("span", "cmd", c.command));
      row.title = `${c.command}\n${tilde(c.cwd || R.root.path)}`;
      row.ondblclick = () => runConfig(c);
      row.oncontextmenu = e => { e.preventDefault(); menu(e, [
        { label: "Esegui", icon: "run", action: () => runConfig(c) },
        c.saved && { label: "Modifica…", icon: "edit", action: () => editRunConfig(c) },
        !c.saved && { label: "Salva come configurazione…", icon: "plus", action: () => editRunConfig({ name: c.name, command: c.command, cwd: c.cwd }, true) },
        { label: "Copia il comando", icon: "copy", action: () => copy(c.command) },
        c.saved && null,
        c.saved && { label: "Elimina", icon: "trash", danger: true, action: () => deleteRunConfig(c) },
      ]); };
      box.append(row);
    }
  }
}
async function saveRunConfigs() {
  try { await api("runConfigs.set", { root: R.root.path, configs: R.saved.map(({ name, command, cwd }) => ({ name, command, cwd })) }); }
  catch (e) { toast("Non riesco a salvare: " + e.message, "error"); }
  renderRunConfigs(); renderRunWidget();
}
function editRunConfig(c = null, asNew = false) {
  const r = cur(); if (!r) { toast("Aggiungi prima un progetto"); return; }
  if (R.root !== r) loadRunConfigs();
  const body = openDialog();
  body.append(el("h3", "", c && !asNew ? "Modifica configurazione" : "Nuova configurazione"));
  const field = (label, value, ph) => { const l = el("label", "field"); l.append(el("span", "", label)); const i = el("input"); i.type = "text"; i.value = value || ""; i.placeholder = ph; l.append(i); body.append(l); return i; };
  const name = field("Nome", c && c.name, "es. Cache flush");
  const cmd = field("Comando", c && c.command, "es. ddev exec bin/magento cache:flush");
  const cwd = field("Cartella", (c && c.cwd) || r.path, r.path);
  const btns = el("div", "row-btn"); const no = el("button", "btn", "Annulla"), ok = el("button", "btn go", "Salva"), go = el("button", "btn", "Salva ed esegui");
  btns.append(no, go, ok); body.append(btns); name.focus();
  const commit = async run => {
    if (!cmd.value.trim()) { cmd.focus(); return; }
    const conf = { name: name.value.trim() || cmd.value.trim().split(" ").slice(0, 3).join(" "), command: cmd.value.trim(), cwd: cwd.value.trim() || r.path };
    closeDialog();
    if (c && c.saved && !asNew) { const i = R.saved.findIndex(x => x.name === c.name && x.command === c.command); if (i >= 0) R.saved[i] = conf; else R.saved.push(conf); }
    else R.saved.push(conf);
    await saveRunConfigs();
    if (run) runConfig(conf);
  };
  no.onclick = closeDialog; ok.onclick = () => commit(false); go.onclick = () => commit(true);
  body.onkeydown = e => { if (e.key === "Enter" && e.metaKey) commit(true); };
}
async function deleteRunConfig(c) {
  if (!(await confirm_(`Elimino la configurazione «${c.name}»?`, c.command, "Elimina", { danger: true }))) return;
  R.saved = R.saved.filter(x => !(x.name === c.name && x.command === c.command));
  saveRunConfigs();
}

// ---------- Sessions ----------
async function runConfig(c) {
  showToolWindow("run", { focus: false });
  const r = R.root || cur();
  R.last[r ? r.path : ""] = { name: c.name, command: c.command, cwd: c.cwd };
  store.set("runLast", R.last);
  renderRunWidget();
  let s = R.sessions.find(x => x.name === c.name && x.command === c.command);
  if (s) { rerun(s); showRun(s); return; }
  rw.empty.remove();
  const pane = el("div", "pane"); const box = el("div", "term"); pane.append(box);
  rw.sessions.append(pane);
  s = { id: "run" + Date.now(), name: c.name, command: c.command, cwd: c.cwd || (r && r.path) || "", el: pane, box, status: "running" };
  s.onExit = code => {
    s.status = code === 0 ? "ok" : "fail";
    s.term.write(`\r\n\x1b[${code === 0 ? "32" : "31"}m[processo terminato con codice ${code}]\x1b[0m\r\n`);
    renderRunTabs(); refreshHead("run"); renderRunWidget();
  };
  R.sessions.push(s);
  showRun(s);
  await attachPty(s, box, { cwd: s.cwd, command: s.command });
  s.term.write(`\x1b[90m$ ${s.command}\x1b[0m\r\n`);
  renderRunTabs(); refreshHead("run");
}
function showRun(s) {
  R.session = s;
  R.sessions.forEach(x => x.el.classList.toggle("on", x === s));
  renderRunTabs(); refreshHead("run"); fitRun();
}
function stopRun(s) { if (s.pty && !s.dead) api("ptyKill", { id: s.pty }); }
async function rerun(s) {
  if (s.pty && !s.dead) { api("ptyKill", { id: s.pty }); await new Promise(r => setTimeout(r, 250)); }
  s.status = "running";
  s.term.clear();
  s.term.write(`\x1b[90m$ ${s.command}\x1b[0m\r\n`);
  try { await s.start(); } catch (e) { s.term.write(`\x1b[31m${e.message}\x1b[0m\r\n`); }
  renderRunTabs(); refreshHead("run"); renderRunWidget();
}
function closeRun(s) {
  stopRun(s);
  s.term && s.term.dispose();
  s.el.remove();
  R.sessions = R.sessions.filter(x => x !== s);
  if (R.session === s) { R.session = null; const n = R.sessions[R.sessions.length - 1]; if (n) showRun(n); else rw.sessions.append(rw.empty); }
  renderRunTabs(); refreshHead("run");
}
function renderRunTabs() {
  const tw = TW.get("run"); const h = tw.headEl; h.innerHTML = "";
  for (const s of R.sessions) {
    const t = el("div", "ptab" + (s === R.session ? " on" : ""));
    t.append(el("span", "st " + (s.status === "running" && !s.dead ? "running" : s.status === "ok" ? "done" : "failed")), el("span", "", s.name));
    const x = el("span", "x"); x.innerHTML = icon("close"); x.onclick = e => { e.stopPropagation(); closeRun(s); };
    t.append(x);
    t.onclick = () => showRun(s);
    h.append(t);
  }
}

// ---------- Toolbar widget: last configuration + play ----------
function renderRunWidget() {
  const box = $("#runWidget"); if (!box) return;
  box.innerHTML = "";
  const r = cur();
  const last = r && R.last[r.path];
  const running = R.sessions.find(s => last && s.command === last.command && !s.dead && s.status === "running");
  const name = el("button", "tb-btn rw-name");
  name.innerHTML = icon("run", "dim");
  name.append(el("span", "", last ? last.name : "Esegui…"));
  name.insertAdjacentHTML("beforeend", icon("chevronDown", "caret"));
  name.title = "Configurazioni di esecuzione (⌘4)";
  name.onclick = async () => {
    if (R.root !== cur()) await loadRunConfigs();
    const rect = name.getBoundingClientRect();
    const items = [...R.saved, ...R.detected].slice(0, 40).map(c => ({ label: c.name, key: c.group || "", icon: "run", action: () => runConfig(c) }));
    menu({ clientX: rect.left, clientY: rect.bottom + 4 }, [
      ...items, items.length && null,
      { label: "Nuova configurazione…", icon: "plus", action: () => editRunConfig() },
      { label: "Apri la finestra Esegui", icon: "run", action: () => showToolWindow("run") },
    ]);
  };
  box.append(name);
  const play = el("button", "tb-ico play"); play.innerHTML = icon(running ? "rerun" : "run");
  play.title = last ? (running ? "Riesegui " : "Esegui ") + last.name : "Esegui…";
  play.disabled = !last;
  play.onclick = () => last && runConfig(last);
  box.append(play);
  if (running) { const st = el("button", "tb-ico stop"); st.innerHTML = icon("stop"); st.title = "Ferma"; st.onclick = () => stopRun(running); box.append(st); }
}
onBoot(() => renderRunWidget());
