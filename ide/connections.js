"use strict";
// Database and remote connections (SSH/SFTP) for the IDE: see Sources/ElioApp/IDEConnections.swift.
// Tool windows "Database" and "Remoto" (right dock by default), "Risultati" (bottom); the user can move them.
// SQL consoles are Monaco tabs.
(() => {
  const C = {
    list: [], clients: {}, open: new Set(), cache: new Map(), consoles: new Map(), results: [], active: null,
    completion: new Map(), remoteOpen: new Set(), remoteCache: new Map(),
  };
  const h = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const ico = (id, cls) => { const s = h("span", "cx-ico " + (cls || "")); s.innerHTML = window.IDE.icons.html(id); return s; };
  const call = (op, args) => window.IDE.call(op, args || {});
  const toast = (t, k) => window.IDE.toast(t, k);
  const err = e => toast(String((e && e.message) || e), "error");
  const byId = id => C.list.find(c => c.id === id);
  const isDb = c => c.kind !== "ssh";
  const dialect = c => c.kind === "postgres" ? "postgres" : c.kind === "sqlite" ? "sqlite" : "mysql";
  const qi = (c, n) => dialect(c) === "mysql" ? "`" + n.replace(/`/g, "``") + "`" : '"' + n.replace(/"/g, '""') + '"';
  const store = {
    get(k, d) { try { const v = localStorage.getItem("conn." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem("conn." + k, JSON.stringify(v)); } catch {} },
  };

  // ---------- Icons (20×20 grid, stroke = currentColor) ----------
  const ICONS = {
    cxServer: '<rect x="3" y="3.5" width="14" height="5.5" rx="1.2"/><rect x="3" y="11" width="14" height="5.5" rx="1.2"/><path d="M6 6.25h.5M6 13.75h.5"/>',
    cxDb: '<ellipse cx="10" cy="5" rx="6" ry="2.4"/><path d="M4 5v10c0 1.3 2.7 2.4 6 2.4s6-1.1 6-2.4V5M4 10c0 1.3 2.7 2.4 6 2.4s6-1.1 6-2.4"/>',
    cxSchema: '<path d="M3.5 5.5h13M3.5 10h13M3.5 14.5h13"/><path d="M7 3v14"/>',
    cxTable: '<rect x="3" y="4" width="14" height="12" rx="1.5"/><path d="M3 8h14M3 12h14M8 4v12"/>',
    cxView: '<path d="M2.5 10s2.8-5 7.5-5 7.5 5 7.5 5-2.8 5-7.5 5-7.5-5-7.5-5z"/><circle cx="10" cy="10" r="2.2"/>',
    cxColumn: '<rect x="7" y="3" width="6" height="14" rx="1"/>',
    cxKey: '<circle cx="6.5" cy="10" r="3"/><path d="M9.5 10H17M14.5 10v3M17 10v2"/>',
    cxIndex: '<path d="M4 4.5h12M4 8.5h8M4 12.5h12M4 16.5h6"/>',
    cxLink: '<path d="M8.5 11.5l3-3"/><path d="M7 9l-1.8 1.8a2.5 2.5 0 0 0 3.5 3.5L10.5 12.5M13 11l1.8-1.8a2.5 2.5 0 0 0-3.5-3.5L9.5 7.5"/>',
    cxFn: '<path d="M12.5 3.5c-2 0-2.5 1.5-2.8 3.5l-1.4 7c-.3 1.6-1 2.5-2.8 2.5M6.5 8h7"/>',
    cxFolder: '<path d="M2.5 5.5a1 1 0 0 1 1-1h4l1.5 1.5h7.5a1 1 0 0 1 1 1v8.5a1 1 0 0 1-1 1h-13a1 1 0 0 1-1-1z"/>',
    cxFile: '<path d="M5 2.5h6.5L15 6v11.5H5z"/><path d="M11.5 2.5V6H15"/>',
    cxPlay: '<path d="M6 4.2v11.6l9.2-5.8z"/>',
    cxStop: '<rect x="5" y="5" width="10" height="10" rx="1.5"/>',
    cxRefresh: '<path d="M16 10a6 6 0 1 1-1.8-4.3"/><path d="M16 3.5v3.3h-3.3"/>',
    cxPlus: '<path d="M10 4v12M4 10h12"/>',
    cxUpload: '<path d="M10 14V3.5M6 7.5l4-4 4 4M3.5 16.5h13"/>',
    cxDownload: '<path d="M10 3.5V14M6 10l4 4 4-4M3.5 16.5h13"/>',
    cxTerminal: '<rect x="2.5" y="3.5" width="15" height="13" rx="2"/><path d="M6 8l2.6 2L6 12M10.5 12.5H14"/>',
    cxConsole: '<path d="M4 4.5h12M4 8.5h12M4 12.5h7"/><path d="M13 12l3 2.5-3 2.5"/>',
    cxPlug: '<path d="M7 2.5v4M13 2.5v4M5 6.5h10v3a5 5 0 0 1-10 0zM10 14.5v3"/>',
    cxUnplug: '<path d="M7 2.5v4M13 2.5v4M5 6.5h10v3a5 5 0 0 1-10 0zM10 14.5v3M3 3l14 14"/>',
    cxHistory: '<path d="M3.6 10a6.4 6.4 0 1 0 1.9-4.6"/><path d="M3.2 3.4v3.3h3.3"/><path d="M10 6.6V10l2.6 1.6"/>',
    cxEdit: '<path d="M4 16l1-4 8.5-8.5 3 3L8 15z"/>',
    cxTrash: '<path d="M4 5.5h12M8 5.5V3.5h4v2M5.5 5.5l1 11h7l1-11"/>',
    cxCheck: '<path d="M4 10.5l4 4 8-9"/>',
    cxUndo: '<path d="M6 8.5H13a3.5 3.5 0 0 1 0 7H8"/><path d="M8.5 5.5L5.5 8.5l3 3"/>',
    cxExport: '<path d="M10 12.5V3M6.5 6.5L10 3l3.5 3.5M4 10v6.5h12V10"/>',
    cxFilter: '<path d="M3 4h14l-5.5 6.5V16l-3-1.5v-4z"/>',
    cxWarn: '<path d="M10 3l7.5 13h-15z"/><path d="M10 8v4M10 14v.2"/>',
  };

  function boot() {
    const I = window.IDE;
    if (!I || C.booted) return;
    C.booted = true;
    try { for (const [k, v] of Object.entries(ICONS)) I.icons.define(k, v); } catch (e) { console.error(e); }
    I.registerToolWindow({ id: "database", title: "Database", icon: "cxDb", side: "right", order: 60, mount: mountDb, onShow: () => renderDb() });
    I.registerToolWindow({ id: "remote", title: "Remoto", icon: "cxServer", side: "right", order: 61, mount: mountRemote, onShow: () => renderRemote() });
    I.registerToolWindow({ id: "dbResults", title: "Risultati", icon: "cxTable", side: "bottom", order: 60, mount: mountResults });
    I.on("conn.changed", list => { C.list = list || []; renderDb(); renderRemote(); });
    I.on("conn.open", req => handleOpen(req));
    I.on("db.status", s => { const c = byId(s.id); if (c) { c.connected = s.connected; renderDb(); } });
    I.on("ssh.status", s => { const c = byId(s.id); if (c) { c.connected = s.connected; renderRemote(); } });
    call("conn.ready").then(r => {
      C.list = r.connections || []; C.clients = r.clients || {};
      renderDb(); renderRemote();
      (r.pending || []).forEach(handleOpen);
    }).catch(e => console.error(e));
    setupKeys();
    setupCompletion();
  }
  if (window.IDE && window.IDE.ready) boot(); else window.addEventListener("ide-ready", boot);
  // ide.js may define IDE after this file without the event (older builds): try once more.
  setTimeout(() => { if (window.IDE && !C.booted) boot(); }, 1500);

  // The assistant asked: show the right window and connect.
  async function handleOpen(req) {
    const c = byId(req.id) || (await call("conn.list").then(l => { C.list = l; return byId(req.id); }).catch(() => null));
    if (!c) return toast("Connessione non trovata", "error");
    if (req.what === "terminal") return openTerminal(c);
    if (req.what === "files") { window.IDE.showToolWindow("remote"); C.remoteOpen.add(c.id); return renderRemote(); }
    if (req.what === "console") return openConsole(c);
    window.IDE.showToolWindow("database");
    C.open.add("c:" + c.id); renderDb();
  }

  // ---------- Missing clients ----------
  function clientMissing(c) {
    const cl = C.clients[c.kind];
    return cl && !cl.path ? cl.install : null;
  }
  function installBox(c, into) {
    const hint = clientMissing(c);
    if (!hint) return false;
    const box = h("div", "cx-missing");
    box.append(ico("cxWarn"), h("span", "", `Manca il client ${c.kindLabel}.`), h("code", "", hint));
    const b = h("button", "btn go", "Installa");
    b.onclick = () => {
      window.IDE.openTerminal({ title: "Installa client " + c.kindLabel, command: hint });
      setTimeout(() => call("conn.clients").then(r => { C.clients = r; renderDb(); }), 30000);
    };
    box.append(b);
    into.append(box);
    return true;
  }

  // ---------- Database tool window ----------
  let dbPane;
  function mountDb(el) {
    dbPane = el; el.classList.add("cx-pane");
    const bar = h("div", "cx-bar");
    const add = h("button", "cx-btn"); add.title = "Nuova connessione"; add.append(ico("cxPlus"));
    add.onclick = e => window.IDE.contextMenu(e, [
      { label: "MySQL / MariaDB", action: () => editConnection({ kind: "mysql" }) },
      { label: "PostgreSQL", action: () => editConnection({ kind: "postgres" }) },
      { label: "SQLite", action: () => editConnection({ kind: "sqlite" }) },
      { label: "Redis", action: () => editConnection({ kind: "redis" }) },
      { separator: true },
      { label: "Connetti al DB di DDEV", action: connectDdev },
    ]);
    const refresh = h("button", "cx-btn"); refresh.title = "Aggiorna"; refresh.append(ico("cxRefresh"));
    refresh.onclick = () => { C.cache.clear(); C.completion.clear(); call("conn.list").then(l => { C.list = l; renderDb(); }); };
    const consoleBtn = h("button", "cx-btn"); consoleBtn.title = "Nuova console SQL"; consoleBtn.append(ico("cxConsole"));
    consoleBtn.onclick = () => { const c = selectedDb(); c ? openConsole(c) : toast("Seleziona una connessione"); };
    bar.append(h("span", "cx-title", "Database"), h("span", "cx-sp"), consoleBtn, refresh, add);
    el.append(bar, h("div", "cx-tree"));
    renderDb();
  }
  function selectedDb() { return C.selDb ? byId(C.selDb) : C.list.find(isDb); }

  async function connectDdev() {
    const p = window.IDE.currentProject();
    if (!p) return toast("Apri prima un progetto DDEV");
    try {
      const c = await call("conn.ddev", { path: p.path });
      C.list = await call("conn.list");
      if (!c.running) toast("Il progetto DDEV è fermo: avvialo con ddev start", "error");
      C.open.add("c:" + c.id); renderDb();
    } catch (e) { err(e); }
  }

  function row(depth, label, icon, opts = {}) {
    const r = h("div", "cx-row" + (opts.cls ? " " + opts.cls : ""));
    r.style.paddingLeft = (6 + depth * 14) + "px";
    const tw = h("span", "cx-tw"); if (opts.expandable) tw.innerHTML = window.IDE.icons.html(opts.open ? "chevronDown" : "chevronRight");
    r.append(tw, ico(icon, opts.iconCls), h("span", "cx-nm", label));
    if (opts.meta) r.append(h("span", "cx-meta", opts.meta));
    if (opts.toggle) r.onclick = opts.toggle;
    if (opts.dbl) r.ondblclick = opts.dbl;
    if (opts.menu) r.oncontextmenu = e => { e.preventDefault(); window.IDE.contextMenu(e, opts.menu()); };
    return r;
  }

  async function children(key, loader) {
    if (C.cache.has(key)) return C.cache.get(key);
    const v = await loader();
    C.cache.set(key, v);
    return v;
  }

  let dbRender = 0;
  async function renderDb() {
    if (!dbPane) return;
    const tree = dbPane.querySelector(".cx-tree");
    const n = ++dbRender;
    const frag = document.createDocumentFragment();
    const dbs = C.list.filter(isDb);
    if (!dbs.length) {
      const e = h("div", "cx-empty");
      e.append(h("div", "", "Nessun database collegato."));
      const b1 = h("button", "btn", "Nuova connessione"); b1.onclick = () => editConnection({ kind: "mysql" });
      const b2 = h("button", "btn", "DB di DDEV"); b2.onclick = connectDdev;
      e.append(b1, b2); frag.append(e);
    }
    for (const c of dbs) {
      const key = "c:" + c.id, open = C.open.has(key);
      const r = row(0, c.name, "cxDb", {
        expandable: true, open, cls: (c.production ? "prod " : "") + (C.selDb === c.id ? "sel" : ""), iconCls: c.connected ? "on" : "",
        meta: c.destination, toggle: () => { C.selDb = c.id; toggle(key, renderDb); }, dbl: () => openConsole(c),
        menu: () => connMenu(c),
      });
      if (c.color) r.style.setProperty("--cx-color", colorOf(c.color));
      frag.append(r);
      if (open) {
        if (installBox(c, frag)) continue;
        try { await renderDbChildren(c, frag); } catch (e) { frag.append(errRow(e, 1)); }
      }
    }
    if (n !== dbRender) return;
    tree.innerHTML = ""; tree.append(frag);
  }
  const colorOf = c => ({ red: "var(--red)", green: "var(--green)", blue: "var(--blue)", orange: "var(--orange)", purple: "var(--purple)" }[c] || c);
  function errRow(e, depth) { const r = h("div", "cx-err", String((e && e.message) || e)); r.style.paddingLeft = (20 + depth * 14) + "px"; return r; }
  function toggle(key, rerender) { C.open.has(key) ? C.open.delete(key) : C.open.add(key); rerender(); }

  async function renderDbChildren(c, frag) {
    if (c.kind === "redis") return renderRedis(c, frag);
    const dbs = await children(`${c.id}|dbs`, () => call("db.tree", { id: c.id, level: "databases" }));
    const pref = c.database ? dbs.filter(d => d.name === c.database) : [];
    const rest = dbs.filter(d => !pref.includes(d));
    for (const d of pref.concat(rest)) {
      const key = `d:${c.id}|${d.name}`, open = C.open.has(key) || (dbs.length === 1 && !C.open.has("x" + key));
      frag.append(row(1, d.name, "cxSchema", {
        expandable: true, open, cls: pref.includes(d) ? "pref" : "",
        toggle: () => { if (dbs.length === 1) { C.open.has("x" + key) ? C.open.delete("x" + key) : C.open.add("x" + key); renderDb(); } else toggle(key, renderDb); },
        menu: () => [{ label: "Nuova console", action: () => openConsole(c, d.name) }, { label: "Aggiorna", action: () => { dropCache(`${c.id}|`); renderDb(); } }],
      }));
      if (!open) continue;
      if (c.kind === "postgres") {
        const schemas = await children(`${c.id}|s|${d.name}`, () => call("db.tree", { id: c.id, level: "schemas", database: d.name }));
        for (const s of schemas) {
          const sk = `s:${c.id}|${d.name}|${s.name}`, sopen = C.open.has(sk) || (s.name === "public" && !C.open.has("x" + sk));
          frag.append(row(2, s.name, "cxFolder", { expandable: true, open: sopen,
            toggle: () => { if (s.name === "public") { C.open.has("x" + sk) ? C.open.delete("x" + sk) : C.open.add("x" + sk); renderDb(); } else toggle(sk, renderDb); } }));
          if (sopen) await renderObjects(c, d.name, s.name, 3, frag);
        }
      } else {
        await renderObjects(c, d.name, c.kind === "mysql" ? d.name : "", 2, frag);
      }
    }
  }
  function dropCache(prefix) { for (const k of [...C.cache.keys()]) if (k.startsWith(prefix)) C.cache.delete(k); }

  async function renderObjects(c, database, schema, depth, frag) {
    const objs = await children(`${c.id}|o|${database}|${schema}`, () => call("db.tree", { id: c.id, level: "objects", database, schema }));
    const groups = [["table", "tabelle"], ["view", "viste"], ["procedure", "procedure"], ["function", "funzioni"]];
    for (const [type, label] of groups) {
      const items = objs.filter(o => o.type === type);
      if (!items.length) continue;
      const gk = `g:${c.id}|${database}|${schema}|${type}`, gopen = type === "table" ? !C.open.has("x" + gk) : C.open.has(gk);
      frag.append(row(depth, `${label} ${items.length}`, "cxFolder", { expandable: true, open: gopen, cls: "grp",
        toggle: () => { if (type === "table") { C.open.has("x" + gk) ? C.open.delete("x" + gk) : C.open.add("x" + gk); renderDb(); } else toggle(gk, renderDb); } }));
      if (!gopen) continue;
      for (const o of items) {
        const tk = `t:${c.id}|${database}|${schema}|${o.name}`, topen = C.open.has(tk);
        const isTable = type === "table" || type === "view";
        frag.append(row(depth + 1, o.name, type === "view" ? "cxView" : isTable ? "cxTable" : "cxFn", {
          expandable: isTable, open: topen, meta: o.rows != null && o.rows !== "" ? `~${o.rows}` : "",
          toggle: () => isTable && toggle(tk, renderDb),
          dbl: () => isTable && openData(c, database, schema, o.name),
          menu: () => isTable ? tableMenu(c, database, schema, o.name, type) : [],
        }));
        if (topen) {
          try {
            const d = await children(`${c.id}|t|${database}|${schema}|${o.name}`, () => call("db.tree", { id: c.id, level: "table", database, schema, table: o.name }));
            for (const col of d.columns) {
              frag.append(row(depth + 2, col.name, col.key === "PRI" ? "cxKey" : "cxColumn", {
                meta: `${col.type}${col.nullable ? "" : " NOT NULL"}${col.key && col.key !== "PRI" ? " " + col.key : ""}`, iconCls: col.key === "PRI" ? "key" : "" }));
            }
            if (d.indexes.length) {
              frag.append(row(depth + 2, `indici ${d.indexes.length}`, "cxIndex", { cls: "grp" }));
              for (const ix of d.indexes) frag.append(row(depth + 3, ix.name, "cxIndex", { meta: (ix.unique ? "UNIQUE " : "") + ix.columns }));
            }
            if (d.foreignKeys.length) {
              frag.append(row(depth + 2, `chiavi esterne ${d.foreignKeys.length}`, "cxLink", { cls: "grp" }));
              for (const fk of d.foreignKeys) frag.append(row(depth + 3, fk.name, "cxLink", { meta: fk.refTable ? `${fk.column} → ${fk.refTable}.${fk.refColumn}` : fk.column }));
            }
          } catch (e) { frag.append(errRow(e, depth + 2)); }
        }
      }
    }
  }

  function connMenu(c) {
    const items = [
      { label: "Nuova console", action: () => openConsole(c) },
      { label: "Modifica…", action: () => editConnection(c) },
      { label: "Duplica", action: () => editConnection(Object.assign({}, c, { id: undefined, name: c.name + " (copia)" })) },
      { label: c.connected ? "Disconnetti" : "Connetti", action: async () => {
        try {
          if (c.connected) await call("db.disconnect", { id: c.id });
          else { const r = await call("db.connect", { id: c.id }); toast(`Connesso${r.serverVersion ? " · " + r.serverVersion : ""}`, "ok"); }
        } catch (e) { err(e); }
      } },
      { label: "Aggiorna", action: () => { dropCache(c.id + "|"); C.completion.delete(c.id); renderDb(); } },
      { separator: true },
      { label: "Elimina connessione…", danger: true, action: async () => {
        if (await window.IDE.confirm(`Elimino la connessione ${c.name}?`, { danger: true, note: "La password salvata viene tolta dal Portachiavi." })) {
          await call("conn.delete", { id: c.id }).catch(err);
        }
      } },
    ];
    return items;
  }

  function tableMenu(c, database, schema, table, type) {
    const q = (schema && c.kind !== "sqlite" ? qi(c, schema) + "." : "") + qi(c, table);
    return [
      { label: "Apri dati", action: () => openData(c, database, schema, table) },
      { label: "Nuova console", action: () => openConsole(c, database, `SELECT * FROM ${q};\n`) },
      { label: "Copia DDL", action: async () => {
        try { const ddl = await call("db.ddl", { id: c.id, database, schema, table }); await navigator.clipboard.writeText(ddl); toast("DDL copiato", "ok"); } catch (e) { err(e); }
      } },
      { label: "Copia nome", action: () => navigator.clipboard.writeText(table) },
      { label: "Conta righe", action: async () => {
        try {
          const r = await call("db.query", { id: c.id, database: dbArg(c, database), console: "tree", sql: `SELECT COUNT(*) FROM ${q}`, maxRows: 1 });
          const res = r.results[0]; if (res.error) throw new Error(res.error);
          toast(`${table}: ${res.rows[0][0]} righe`, "ok");
        } catch (e) { err(e); }
      } },
      { separator: true },
      ...(type === "view" ? [] : [{ label: "Svuota…", danger: true, action: async () => {
        if (!(await window.IDE.confirm(`Svuoto ${table}?`, { danger: true, note: "TRUNCATE cancella tutte le righe. Non si può annullare." }))) return;
        await runInternal(c, database, `${c.kind === "sqlite" ? "DELETE FROM" : "TRUNCATE TABLE"} ${q}`, true);
      } }]),
      { label: type === "view" ? "Elimina vista…" : "Elimina tabella…", danger: true, action: async () => {
        const typed = await window.IDE.prompt(`Per eliminare ${table} scrivi il suo nome`, "");
        if (typed !== table) { if (typed != null) toast("Il nome non corrisponde: non elimino nulla"); return; }
        await runInternal(c, database, `DROP ${type === "view" ? "VIEW" : "TABLE"} ${q}`, true);
      } },
    ];
  }
  const dbArg = (c, database) => c.kind === "mysql" ? undefined : (c.kind === "postgres" ? database : undefined);

  async function runInternal(c, database, sql, refresh) {
    if (c.production && !(await window.IDE.confirm(`${c.name} è PRODUZIONE. Eseguo?`, { danger: true, note: sql }))) return;
    try {
      const r = await call("db.query", { id: c.id, database: dbArg(c, database), console: "tree", sql });
      const e = r.results.find(x => x.error); if (e) throw new Error(e.error);
      toast("Fatto", "ok");
      if (refresh) { dropCache(c.id + "|"); renderDb(); }
    } catch (e) { err(e); }
  }

  // ---------- Redis keys ----------
  async function renderRedis(c, frag) {
    const pattern = C.redisPattern || "*";
    const f = h("div", "cx-row"); f.style.paddingLeft = "20px";
    const input = h("input", "cx-input"); input.placeholder = "Filtro chiavi (es. cache:*)"; input.value = pattern === "*" ? "" : pattern;
    input.onkeydown = e => { if (e.key === "Enter") { C.redisPattern = input.value || "*"; dropCache(c.id + "|keys"); renderDb(); } };
    f.append(input); frag.append(f);
    const keys = await children(`${c.id}|keys|${pattern}`, () => call("db.tree", { id: c.id, level: "keys", schema: pattern }));
    for (const k of keys) frag.append(row(1, k.name, "cxKey", { dbl: () => openRedisKey(c, k.name),
      menu: () => [{ label: "Apri valore", action: () => openRedisKey(c, k.name) }, { label: "Copia nome", action: () => navigator.clipboard.writeText(k.name) }] }));
    if (keys.length >= 2000) frag.append(errRow("Mostrate le prime 2000 chiavi: restringi il filtro", 1));
  }
  async function openRedisKey(c, key) {
    try {
      const v = await call("db.tree", { id: c.id, level: "key", table: key });
      addResult({ title: key, conn: c, text: `tipo: ${v.type} · ttl: ${v.ttl}\n\n${v.value}` });
    } catch (e) { err(e); }
  }

  // ---------- Connection form ----------
  async function editConnection(base) {
    const c = Object.assign({ kind: "mysql", name: "", host: "", port: null, user: "", database: "", path: "", auth: "agent", keyPath: "",
      sshVia: "", remoteDir: "", production: false, color: "", localRoot: "", remoteRoot: "", forwards: [] }, base);
    const ov = h("div", "cx-overlay");
    const dlg = h("div", "dlg cx-form");
    dlg.append(h("h3", "", (c.id ? "Modifica " : "Nuova connessione ") + kindLabel(c.kind)));
    const grid = h("div", "cx-grid");
    const fields = {};
    const field = (key, label, opts = {}) => {
      const l = h("label", "cx-lbl", label);
      let input;
      if (opts.select) {
        input = h("select", "cx-input");
        for (const [v, t] of opts.select) { const o = h("option", "", t); o.value = v; input.append(o); }
        input.value = c[key] || opts.select[0][0];
      } else if (opts.check) {
        input = h("input"); input.type = "checkbox"; input.checked = !!c[key];
      } else {
        input = h("input", "cx-input"); input.type = opts.type || "text"; input.value = c[key] == null ? "" : c[key];
        if (opts.placeholder) input.placeholder = opts.placeholder;
      }
      input.spellcheck = false; input.autocomplete = "off";
      fields[key] = input;
      grid.append(l, input);
      if (opts.button) { const b = h("button", "btn small", opts.button[0]); b.onclick = opts.button[1]; grid.append(b); } else grid.append(h("span"));
      return input;
    };
    field("name", "Nome", { placeholder: "es. Staging Comitiva" });
    if (c.kind === "sqlite") {
      field("path", "File", { placeholder: "/percorso/database.sqlite" });
    } else {
      field("host", "Host", { placeholder: c.kind === "ssh" ? "1.2.3.4 o server.example.com" : "127.0.0.1" });
      field("port", "Porta", { placeholder: String({ ssh: 22, mysql: 3306, postgres: 5432, redis: 6379 }[c.kind]) });
      field("user", "Utente");
      if (c.kind === "ssh") {
        field("auth", "Autenticazione", { select: [["agent", "Agente SSH / chiavi predefinite"], ["key", "File chiave"], ["password", "Password"]] });
        field("keyPath", "Chiave privata", { placeholder: "~/.ssh/id_ed25519" });
      }
    }
    let pw = null;
    if (c.kind !== "sqlite") {
      pw = field("_password", c.hasPassword ? "Password (salvata)" : "Password", { type: "password", placeholder: c.hasPassword ? "lascia vuoto per non cambiarla" : "" });
    }
    if (c.kind === "mysql" || c.kind === "postgres") field("database", "Database");
    if (c.kind === "redis") field("database", "Numero db", { placeholder: "0" });
    if (isDb(c) && c.kind !== "sqlite") {
      const hosts = C.list.filter(x => x.kind === "ssh");
      field("sshVia", "Tunnel SSH", { select: [["", "Nessuno (connessione diretta)"]].concat(hosts.map(x => [x.id, x.name])) });
    }
    if (c.kind === "ssh") {
      field("remoteDir", "Cartella iniziale", { placeholder: "/var/www/html" });
      field("localRoot", "Deployment: cartella locale", { placeholder: "progetto sul Mac", button: ["Progetto", () => { const p = window.IDE.currentProject(); if (p) fields.localRoot.value = p.path; }] });
      field("remoteRoot", "Deployment: cartella remota", { placeholder: "/var/www/html" });
      field("_forwards", "Inoltri porte", { placeholder: "8080:127.0.0.1:80, 3307:db:3306" });
      fields._forwards.value = (c.forwards || []).map(f => `${f.localPort}:${f.remoteHost}:${f.remotePort}`).join(", ");
    }
    field("color", "Colore", { select: [["", "Nessuno"], ["green", "Verde"], ["blue", "Blu"], ["orange", "Arancio"], ["purple", "Viola"], ["red", "Rosso"]] });
    field("production", "Produzione (conferma ogni scrittura)", { check: true });
    dlg.append(grid);
    const status = h("div", "cx-status");
    const btns = h("div", "row-btn");
    const test = h("button", "btn", "Prova connessione"), cancel = h("button", "btn", "Annulla"), save = h("button", "btn go", "Salva");
    btns.append(test, h("span", "cx-sp"), cancel, save);
    dlg.append(status, btns);
    ov.append(dlg); document.body.append(ov);
    fields.name.focus();
    const collect = () => {
      const o = { kind: c.kind };
      if (c.id) o.id = c.id;
      for (const [k, input] of Object.entries(fields)) {
        if (k.startsWith("_")) continue;
        o[k] = input.type === "checkbox" ? input.checked : input.value.trim();
      }
      o.port = o.port ? parseInt(o.port, 10) : null;
      if (fields._forwards) {
        o.forwards = fields._forwards.value.split(",").map(s => s.trim()).filter(Boolean).map(s => {
          const p = s.split(":"); return p.length === 3 ? { localPort: +p[0], remoteHost: p[1], remotePort: +p[2] } : p.length === 2 ? { localPort: +p[0], remoteHost: "127.0.0.1", remotePort: +p[1] } : null;
        }).filter(Boolean);
      }
      return o;
    };
    const close = () => ov.remove();
    cancel.onclick = close;
    ov.onkeydown = e => { if (e.key === "Escape") close(); };
    test.onclick = async () => {
      status.className = "cx-status"; status.textContent = "Provo…";
      try {
        const r = await call("conn.test", { connection: collect(), password: pw ? pw.value : "" });
        status.className = "cx-status " + (r.ok ? "ok" : "bad"); status.textContent = r.message;
      } catch (e) { status.className = "cx-status bad"; status.textContent = String(e.message || e); }
    };
    save.onclick = async () => {
      try {
        const saved = await call("conn.save", { connection: collect(), password: pw ? pw.value : "" });
        if (pw) pw.value = "";
        C.list = await call("conn.list");
        dropCache(saved.id + "|");
        close();
        if (saved.kind === "ssh") { window.IDE.showToolWindow("remote"); renderRemote(); }
        else { window.IDE.showToolWindow("database"); C.open.add("c:" + saved.id); renderDb(); }
        toast("Connessione salvata", "ok");
      } catch (e) { status.className = "cx-status bad"; status.textContent = String(e.message || e); }
    };
  }
  const kindLabel = k => ({ ssh: "SSH", mysql: "MySQL", postgres: "PostgreSQL", sqlite: "SQLite", redis: "Redis" }[k] || k);

  // ---------- SQL console ----------
  function openConsole(c, database, initial) {
    if (!isDb(c)) return;
    if (clientMissing(c)) { window.IDE.showToolWindow("database"); C.open.add("c:" + c.id); renderDb(); return; }
    const db = database || c.database || "";
    const id = `sql:${c.id}:${db}`;
    let con = C.consoles.get(id);
    const draft = store.get("draft." + id, initial || (c.kind === "redis" ? "PING\n" : (c.kind === "mysql" && db ? `USE ${qi(c, db)};\n` : "") + "SELECT 1;\n"));
    const handle = window.IDE.openEditorTab({
      id, title: `${c.name}${db && db !== c.database ? " · " + db : ""}.${c.kind === "redis" ? "redis" : "sql"}`,
      content: draft, language: c.kind === "redis" ? "plaintext" : "sql",
      onSave: text => { store.set("draft." + id, text); },
    });
    if (!con) {
      con = { id, conn: c, database: db, handle, autocommit: true, running: false };
      C.consoles.set(id, con);
      try { handle.model.onDidChangeContent(() => store.set("draft." + id, handle.getContent())); } catch {}
    } else con.handle = handle;
    if (initial) { const cur = handle.getContent(); if (!cur.includes(initial.trim())) handle.setContent(initial + "\n" + cur); }
    C.activeConsole = con;
    window.IDE.showToolWindow("dbResults", { focus: false });
    renderResultsBar();
    loadCompletion(c, db);
    return con;
  }

  function consoleForModel(model) { for (const con of C.consoles.values()) if (con.handle && con.handle.model === model) return con; return null; }
  function focusedConsole() {
    for (const con of C.consoles.values()) {
      try { const ed = con.handle.editor; if (ed && ed.getModel() === con.handle.model) return con; } catch {}
    }
    return null;
  }

  function setupKeys() {
    window.addEventListener("keydown", e => {
      // ⌘↩ runs the statement (or selection) of the focused SQL console; ⌘⇧↩ runs everything.
      if (e.metaKey && e.key === "Enter") {
        const con = focusedConsole();
        if (!con) return;
        e.preventDefault(); e.stopPropagation();
        runConsole(con, e.shiftKey ? "all" : "auto");
      }
      // ⌥⇧⌘X: upload the current file to its deployment server (PhpStorm's Upload).
      if (e.metaKey && e.altKey && e.shiftKey && (e.code === "KeyX")) {
        e.preventDefault(); e.stopPropagation();
        uploadCurrentFile();
      }
    }, true);
  }

  async function runConsole(con, mode) {
    const c = byId(con.conn.id) || con.conn;
    const ed = con.handle.editor, model = con.handle.model;
    let sql = "";
    const sel = ed && ed.getSelection();
    if (mode !== "all" && sel && !sel.isEmpty()) sql = model.getValueInRange(sel);
    else if (mode === "all" || c.kind === "redis") sql = model.getValue();
    else {
      const text = model.getValue();
      const off = model.getOffsetAt(ed.getPosition());
      const cls = await call("db.classify", { sql: text, kind: c.kind });
      const r = cls.ranges.find(([s, e]) => off >= s && off <= e + 1) || cls.ranges.filter(([s]) => s <= off).pop() || cls.ranges[0];
      if (r) {
        sql = text.slice(r[0], r[1]);
        // Flash the statement being run.
        try {
          const a = model.getPositionAt(r[0]), b = model.getPositionAt(r[1]);
          const dec = ed.deltaDecorations([], [{ range: new monaco.Range(a.lineNumber, a.column, b.lineNumber, b.column), options: { className: "cx-running" } }]);
          setTimeout(() => ed.deltaDecorations(dec, []), 700);
        } catch {}
      }
    }
    if (!sql.trim()) return;
    if (!(await confirmRun(c, sql))) return;
    await execute(con, sql);
  }

  async function confirmRun(c, sql) {
    if (c.kind === "redis") {
      const danger = /^\s*(FLUSHALL|FLUSHDB|DEL|UNLINK|SHUTDOWN|CONFIG\s+SET)\b/im.test(sql);
      if (danger || c.production) return window.IDE.confirm(`Eseguo su ${c.name}${c.production ? " (PRODUZIONE)" : ""}?`, { danger: true, note: sql.slice(0, 600) });
      return true;
    }
    const cls = await call("db.classify", { sql, kind: c.kind });
    if (cls.destructive.length) {
      return window.IDE.confirm(`Istruzione distruttiva su ${c.name}`, { danger: true, note: cls.destructive.join("\n") + "\n\n" + sql.slice(0, 600) });
    }
    if (c.production && !cls.readOnly) {
      return window.IDE.confirm(`${c.name} è PRODUZIONE: eseguo questa modifica?`, { danger: true, note: sql.slice(0, 600) });
    }
    return true;
  }

  async function execute(con, sql, maxRows = 1000) {
    const c = con.conn;
    con.running = true; renderResultsBar();
    const started = Date.now();
    try {
      const r = await call("db.query", { id: c.id, database: con.database || undefined, console: con.id, sql, maxRows });
      con.autocommit = r.autocommit;
      const list = r.results || [];
      if (!list.length) toast("Niente da eseguire");
      // One result tab per statement; replaced on the next run of the same console.
      C.results = C.results.filter(x => x.console !== con.id || x.pinned);
      list.forEach((res, i) => addResult({ title: resTitle(res, i), conn: c, res, console: con.id, sql: res.statement, maxRows }, i === list.length - 1));
      const failed = list.find(x => x.error);
      if (failed) toast(failed.error, "error");
      else if (!list.some(x => x.hasResultSet)) toast(list.map(x => x.affected != null ? `${x.affected} righe` : "OK").join(" · ") + ` · ${Date.now() - started} ms`, "ok");
      if (list.some(x => /^\s*(CREATE|DROP|ALTER|RENAME)/i.test(x.statement))) { dropCache(c.id + "|"); C.completion.delete(c.id); renderDb(); }
    } catch (e) { err(e); }
    con.running = false; renderResultsBar();
  }
  const resTitle = (res, i) => (res.statement || "").replace(/\s+/g, " ").slice(0, 28) || `Risultato ${i + 1}`;

  // ---------- Autocomplete ----------
  async function loadCompletion(c, database) {
    const key = c.id + "|" + database;
    if (C.completion.has(key) || c.kind === "redis") return;
    C.completion.set(key, {});
    try { C.completion.set(key, await call("db.completion", { id: c.id, database, schema: c.kind === "postgres" ? "public" : "" })); }
    catch { C.completion.delete(key); }
  }
  function setupCompletion() {
    const reg = () => {
      if (!window.monaco || !monaco.languages) return setTimeout(reg, 500);
      const KW = ["SELECT", "FROM", "WHERE", "AND", "OR", "ORDER BY", "GROUP BY", "LIMIT", "INSERT INTO", "VALUES", "UPDATE", "SET",
        "DELETE FROM", "JOIN", "LEFT JOIN", "INNER JOIN", "ON", "AS", "COUNT(*)", "DISTINCT", "HAVING", "IN", "LIKE", "IS NULL", "IS NOT NULL",
        "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "SHOW TABLES", "DESCRIBE", "EXPLAIN"];
      monaco.languages.registerCompletionItemProvider("sql", {
        triggerCharacters: [".", " "],
        provideCompletionItems(model, position) {
          const con = consoleForModel(model);
          if (!con) return { suggestions: [] };
          const map = C.completion.get(con.conn.id + "|" + con.database) || {};
          const word = model.getWordUntilPosition(position);
          const range = { startLineNumber: position.lineNumber, endLineNumber: position.lineNumber, startColumn: word.startColumn, endColumn: word.endColumn };
          const before = model.getValueInRange({ startLineNumber: position.lineNumber, startColumn: 1, endLineNumber: position.lineNumber, endColumn: word.startColumn });
          const K = monaco.languages.CompletionItemKind;
          const dot = before.match(/([A-Za-z0-9_`"]+)\.$/);
          if (dot) {
            // alias.column: resolve aliases from "FROM table alias" / "JOIN table alias".
            let t = dot[1].replace(/[`"]/g, "");
            const text = model.getValue();
            const m = new RegExp(`(?:from|join)\\s+[\`"]?([A-Za-z0-9_]+)[\`"]?\\s+(?:as\\s+)?${t}\\b`, "i").exec(text);
            if (m) t = m[1];
            return { suggestions: (map[t] || []).map(col => ({ label: col, kind: K.Field, insertText: col, range, detail: t })) };
          }
          const s = [];
          for (const [t, cols] of Object.entries(map)) {
            s.push({ label: t, kind: K.Struct, insertText: t, range, detail: `${cols.length} colonne` });
          }
          const text = model.getValue();
          for (const [t, cols] of Object.entries(map)) if (new RegExp(`\\b${t}\\b`).test(text)) for (const col of cols) s.push({ label: col, kind: K.Field, insertText: col, range, detail: t, sortText: "0" + col });
          for (const k of KW) s.push({ label: k, kind: K.Keyword, insertText: k, range, sortText: "z" + k });
          return { suggestions: s };
        },
      });
    };
    reg();
  }

  // ---------- Results (bottom tool window) ----------
  let resPane;
  function mountResults(el) {
    resPane = el; el.classList.add("cx-results");
    el.append(h("div", "cx-rbar"), h("div", "cx-rtabs"), h("div", "cx-rbody"));
    renderResultsBar(); renderResults();
  }

  function renderResultsBar() {
    if (!resPane) return;
    const bar = resPane.querySelector(".cx-rbar");
    bar.innerHTML = "";
    const con = C.activeConsole;
    if (!con) { bar.append(h("span", "cx-dim", "Apri una console SQL dal pannello Database (doppio clic su una connessione).")); return; }
    const c = byId(con.conn.id) || con.conn;
    const name = h("span", "cx-conname" + (c.production ? " prod" : ""), c.name + (con.database ? " · " + con.database : ""));
    const btn = (icon, title, fn, cls) => { const b = h("button", "cx-btn " + (cls || "")); b.title = title; b.append(ico(icon)); b.onclick = fn; return b; };
    bar.append(name);
    bar.append(btn("cxPlay", "Esegui (⌘↩)", () => runConsole(con, "auto"), "go"));
    bar.append(btn("cxStop", "Interrompi", () => call("db.cancel", { id: c.id, console: con.id, database: con.database || undefined }).then(() => toast("Interrotta")), con.running ? "" : "dim"));
    if (c.kind !== "redis") {
      const ac = h("label", "cx-ac");
      const box = h("input"); box.type = "checkbox"; box.checked = con.autocommit;
      box.onchange = async () => {
        try { const r = await call("db.tx", { id: c.id, console: con.id, database: con.database || undefined, action: box.checked ? "autocommitOn" : "autocommitOff" }); con.autocommit = r.autocommit; }
        catch (e) { err(e); box.checked = con.autocommit; }
        renderResultsBar();
      };
      ac.append(box, document.createTextNode(" Auto-commit"));
      bar.append(ac);
      if (!con.autocommit) {
        bar.append(btn("cxCheck", "Commit", () => tx(con, "commit"), "ok"), btn("cxUndo", "Rollback", () => tx(con, "rollback"), "bad"));
      }
    }
    bar.append(btn("cxHistory", "Cronologia", e => showHistory(e, con)));
    if (con.running) bar.append(h("span", "cx-spin", "in esecuzione…"));
  }
  async function tx(con, action) {
    try { await call("db.tx", { id: con.conn.id, console: con.id, database: con.database || undefined, action }); toast(action === "commit" ? "Commit eseguito" : "Rollback eseguito", "ok"); }
    catch (e) { err(e); }
  }
  async function showHistory(e, con) {
    const list = await call("conn.history", { id: con.conn.id }).catch(() => []);
    if (!list.length) return toast("Nessuna query nella cronologia");
    window.IDE.contextMenu(e, list.slice(0, 25).map(x => ({ label: x.sql.replace(/\s+/g, " ").slice(0, 90), action: () => {
      const cur = con.handle.getContent(); con.handle.setContent(cur + (cur.endsWith("\n") ? "" : "\n") + x.sql + (x.sql.trim().endsWith(";") ? "\n" : ";\n")); con.handle.focus();
    } })));
  }

  function addResult(r, activate = true) {
    r.id = "r" + Math.random().toString(36).slice(2);
    C.results.push(r);
    if (C.results.length > 20) C.results.splice(0, C.results.length - 20);
    if (activate) C.active = r.id;
    window.IDE.showToolWindow("dbResults", { focus: false });
    renderResults();
  }

  function renderResults() {
    if (!resPane) return;
    const tabs = resPane.querySelector(".cx-rtabs"), body = resPane.querySelector(".cx-rbody");
    tabs.innerHTML = ""; body.innerHTML = "";
    if (!C.results.length) { body.append(h("div", "cx-empty", "I risultati delle query appaiono qui.")); return; }
    if (!C.results.find(r => r.id === C.active)) C.active = C.results[C.results.length - 1].id;
    for (const r of C.results) {
      const t = h("div", "cx-rtab" + (r.id === C.active ? " on" : "") + (r.res && r.res.error ? " bad" : ""));
      t.append(h("span", "", r.title));
      const x = h("button", "cx-x"); x.innerHTML = window.IDE.icons.html("close");
      x.onclick = e => { e.stopPropagation(); C.results = C.results.filter(y => y !== r); renderResults(); };
      t.append(x);
      t.onclick = () => { C.active = r.id; renderResults(); };
      tabs.append(t);
    }
    const r = C.results.find(x => x.id === C.active);
    if (r.data) return renderDataView(r, body);
    if (r.text != null) { body.append(h("pre", "cx-text", r.text)); return; }
    const res = r.res;
    if (res.error) { body.append(h("pre", "cx-text bad", res.error)); return; }
    if (res.text && !res.hasResultSet) { body.append(h("pre", "cx-text", res.text)); return; }
    if (!res.hasResultSet) { body.append(h("div", "cx-done", (res.affected != null ? `${res.affected} righe interessate` : "Eseguita") + ` · ${res.ms} ms`)); return; }
    const info = h("div", "cx-rinfo");
    info.append(h("span", "", `${res.rowCount}${res.truncated ? "+" : ""} righe · ${res.ms} ms`));
    if (res.truncated) {
      const more = h("button", "btn small", "Carica altri");
      more.onclick = () => { const con = C.consoles.get(r.console); if (con) execute(con, r.sql, Math.min((r.maxRows || 1000) * 5, 100000)); };
      info.append(more);
    }
    info.append(h("span", "cx-sp"), exportBtn(res, r.title));
    body.append(info, grid(res, {}));
  }

  function exportBtn(res, name) {
    const b = h("button", "cx-btn"); b.title = "Esporta"; b.append(ico("cxExport"));
    b.onclick = e => window.IDE.contextMenu(e, [
      { label: "Esporta CSV…", action: () => call("conn.export", { format: "csv", columns: res.columns, rows: res.rows, name }).then(p => p && toast("Salvato in " + p, "ok")).catch(err) },
      { label: "Esporta JSON…", action: () => call("conn.export", { format: "json", columns: res.columns, rows: res.rows, name }).then(p => p && toast("Salvato in " + p, "ok")).catch(err) },
      { label: "Copia come TSV", action: () => navigator.clipboard.writeText([res.columns.join("\t")].concat(res.rows.map(r => r.map(v => v == null ? "NULL" : v).join("\t"))).join("\n")).then(() => toast("Copiato")) },
    ]);
    return b;
  }

  // A sortable grid; `opts.edit(rowIndex, colIndex, td)` makes cells editable.
  function grid(res, opts) {
    const wrap = h("div", "cx-grid-wrap");
    const table = h("table", "cx-table");
    const thead = h("thead"), tr = h("tr");
    tr.append(h("th", "cx-rn", "#"));
    let order = opts.order || null;
    const rows = res.rows.map((r, i) => ({ r, i }));
    const sortRows = () => {
      if (!order || opts.serverSort) return rows;
      const k = order.col, dir = order.desc ? -1 : 1;
      return rows.slice().sort((a, b) => {
        const x = a.r[k], y = b.r[k];
        if (x == null) return 1; if (y == null) return -1;
        const nx = Number(x), ny = Number(y);
        return (!isNaN(nx) && !isNaN(ny) ? nx - ny : String(x).localeCompare(String(y))) * dir;
      });
    };
    res.columns.forEach((col, k) => {
      const th = h("th", "", col);
      if (order && order.col === k) th.classList.add(order.desc ? "desc" : "asc");
      th.onclick = () => {
        order = order && order.col === k ? (order.desc ? null : { col: k, desc: true }) : { col: k, desc: false };
        if (opts.onSort) return opts.onSort(order);
        const nw = grid(res, Object.assign({}, opts, { order })); wrap.replaceWith(nw);
      };
      tr.append(th);
    });
    thead.append(tr); table.append(thead);
    const tbody = h("tbody");
    for (const { r, i } of sortRows()) {
      const row = h("tr");
      row.append(h("td", "cx-rn", String(i + 1)));
      r.forEach((v, k) => {
        const td = h("td", v == null ? "null" : "", v == null ? "NULL" : String(v).length > 300 ? String(v).slice(0, 300) + "…" : String(v));
        td.title = v == null ? "NULL" : String(v).slice(0, 2000);
        if (opts.edit) td.ondblclick = () => opts.edit(i, k, td);
        row.append(td);
      });
      if (opts.rowMenu) row.oncontextmenu = e => { e.preventDefault(); window.IDE.contextMenu(e, opts.rowMenu(i)); };
      tbody.append(row);
    }
    table.append(tbody); wrap.append(table);
    return wrap;
  }

  // ---------- Table data view (editable) ----------
  async function openData(c, database, schema, table) {
    const r = { title: table, conn: c, data: { database, schema, table, where: "", order: null, limit: 200, offset: 0 } };
    addResult(r);
    await loadData(r);
  }
  async function loadData(r) {
    const c = r.conn, d = r.data;
    d.loading = true; renderResults();
    try {
      const res = await call("db.data", { id: c.id, database: dbArg(c, d.database), schema: d.schema, table: d.table, where: d.where,
        orderBy: d.order ? d.res.columns[d.order.col] : "", desc: d.order ? d.order.desc : false, limit: d.limit, offset: d.offset });
      if (res.error) throw new Error(res.error);
      d.res = res; d.error = null;
    } catch (e) { d.error = String(e.message || e); }
    d.loading = false; renderResults();
  }
  function renderDataView(r, body) {
    const c = r.conn, d = r.data;
    const bar = h("div", "cx-rinfo");
    const where = h("input", "cx-input cx-where"); where.placeholder = "WHERE (es. entity_id > 100 AND status = 'pending')"; where.value = d.where;
    where.onkeydown = e => { if (e.key === "Enter") { d.where = where.value; d.offset = 0; loadData(r); } };
    bar.append(ico("cxFilter"), where);
    const btn = (label, fn) => { const b = h("button", "btn small", label); b.onclick = fn; return b; };
    bar.append(btn("Aggiorna", () => loadData(r)));
    if (d.offset > 0) bar.append(btn("Indietro", () => { d.offset = Math.max(0, d.offset - d.limit); loadData(r); }));
    if (d.res && d.res.truncated) bar.append(btn("Avanti", () => { d.offset += d.limit; loadData(r); }));
    bar.append(btn("Nuova riga", () => editRow(r, "insert")));
    if (d.res) bar.append(h("span", "cx-dim", `${d.offset + 1}–${d.offset + d.res.rowCount}${d.res.truncated ? "+" : ""}`), h("span", "cx-sp"), exportBtn(d.res, d.table));
    body.append(bar);
    if (d.loading) body.append(h("div", "cx-empty", "Carico…"));
    if (d.error) body.append(h("pre", "cx-text bad", d.error));
    if (!d.res || d.loading) return;
    const pk = d.res.primaryKey || [];
    if (!pk.length) body.append(h("div", "cx-dim cx-note", "Senza chiave primaria i dati sono in sola lettura."));
    body.append(grid(d.res, {
      order: d.order, serverSort: true,
      onSort: order => { d.order = order; loadData(r); },
      edit: pk.length ? (i, k, td) => editCell(r, i, k, td) : null,
      rowMenu: pk.length ? i => [
        { label: "Modifica riga…", action: () => editRow(r, "update", i) },
        { label: "Duplica riga…", action: () => editRow(r, "insert", i) },
        { label: "Elimina riga…", danger: true, action: () => deleteRow(r, i) },
      ] : null,
    }));
  }
  const keyOf = (d, i) => { const k = {}; for (const col of d.res.primaryKey) k[col] = d.res.rows[i][d.res.columns.indexOf(col)]; return k; };
  function editCell(r, i, k, td) {
    const d = r.data, old = d.res.rows[i][k];
    const input = h("input", "cx-cell"); input.value = old == null ? "" : old;
    td.innerHTML = ""; td.append(input); input.focus(); input.select();
    let done = false;
    const finish = async commit => {
      if (done) return; done = true;
      if (!commit || input.value === (old == null ? "" : old)) return renderResults();
      const value = input.value === "" && old == null ? null : input.value;
      await applyRow(r, "update", { [d.res.columns[k]]: value }, keyOf(d, i));
    };
    input.onkeydown = e => {
      if (e.key === "Enter") finish(true);
      if (e.key === "Escape") finish(false);
      // ⌘⌫ sets NULL.
      if (e.key === "Backspace" && e.metaKey) { e.preventDefault(); done = true; applyRow(r, "update", { [d.res.columns[k]]: null }, keyOf(d, i)); }
    };
    input.onblur = () => finish(false);
  }
  async function editRow(r, op, i) {
    const d = r.data;
    if (!d.res) return;
    const ov = h("div", "cx-overlay"), dlg = h("div", "dlg cx-form");
    dlg.append(h("h3", "", op === "insert" ? `Nuova riga in ${d.table}` : `Modifica riga di ${d.table}`));
    const gridEl = h("div", "cx-grid"), inputs = {};
    d.res.columns.forEach((col, k) => {
      const v = i != null ? d.res.rows[i][k] : null;
      const inp = h("input", "cx-input"); inp.value = v == null ? "" : v; inp.placeholder = v == null ? "NULL" : "";
      const nul = h("label", "cx-null"); const nb = h("input"); nb.type = "checkbox"; nb.checked = v == null && op !== "insert" ? true : false; nul.append(nb, document.createTextNode(" NULL"));
      if (op === "insert" && d.res.primaryKey.includes(col) && i != null) inp.value = "";
      inputs[col] = { inp, nb, orig: v };
      gridEl.append(h("label", "cx-lbl", col), inp, nul);
    });
    const btns = h("div", "row-btn"); const no = h("button", "btn", "Annulla"), ok = h("button", "btn go", op === "insert" ? "Inserisci" : "Salva");
    btns.append(no, ok); dlg.append(gridEl, btns); ov.append(dlg); document.body.append(ov);
    no.onclick = () => ov.remove();
    ok.onclick = async () => {
      const values = {};
      for (const [col, f] of Object.entries(inputs)) {
        const v = f.nb.checked ? null : f.inp.value;
        if (op === "insert") { if (f.nb.checked || f.inp.value !== "") values[col] = v; }
        else if (v !== f.orig) values[col] = v;
      }
      ov.remove();
      if (op === "update" && !Object.keys(values).length) return;
      await applyRow(r, op, values, op === "update" ? keyOf(d, i) : {});
    };
  }
  async function deleteRow(r, i) { await applyRow(r, "delete", {}, keyOf(r.data, i)); }

  // Generated SQL is shown and confirmed before it runs.
  async function applyRow(r, op, values, key) {
    const c = r.conn, d = r.data;
    try {
      const b = await call("db.buildRow", { id: c.id, op, database: d.database, schema: d.schema, table: d.table, key, values });
      if (b.error) throw new Error(b.error);
      const ok = await window.IDE.confirm(op === "delete" ? "Elimino la riga?" : op === "insert" ? "Inserisco la riga?" : "Salvo la modifica?",
        { note: b.sql + (c.production ? "\n\nATTENZIONE: connessione di PRODUZIONE." : ""), danger: op === "delete" || c.production, action: "Esegui" });
      if (!ok) return renderResults();
      const res = await call("db.query", { id: c.id, database: dbArg(c, d.database), console: "data", sql: b.sql });
      const e = res.results.find(x => x.error); if (e) throw new Error(e.error);
      const aff = res.results[0] && res.results[0].affected;
      toast(aff != null ? `${aff} righe` : "Fatto", "ok");
      await loadData(r);
    } catch (e) { err(e); renderResults(); }
  }

  // ---------- Remote tool window ----------
  let rmPane;
  function mountRemote(el) {
    rmPane = el; el.classList.add("cx-pane");
    const bar = h("div", "cx-bar");
    const add = h("button", "cx-btn"); add.title = "Nuovo host"; add.append(ico("cxPlus"));
    add.onclick = e => window.IDE.contextMenu(e, [
      { label: "Nuovo host SSH / SFTP", action: () => editConnection({ kind: "ssh" }) },
      { label: "Importa da ~/.ssh/config…", action: importSshConfig },
    ]);
    const up = h("button", "cx-btn"); up.title = "Carica il file corrente sul server (⌥⇧⌘X)"; up.append(ico("cxUpload")); up.onclick = uploadCurrentFile;
    const refresh = h("button", "cx-btn"); refresh.title = "Aggiorna"; refresh.append(ico("cxRefresh"));
    refresh.onclick = () => { C.remoteCache.clear(); renderRemote(); };
    bar.append(h("span", "cx-title", "Remoto"), h("span", "cx-sp"), up, refresh, add);
    el.append(bar, h("div", "cx-tree"));
    renderRemote();
  }

  async function importSshConfig(e) {
    const hosts = await call("conn.sshConfig").catch(() => []);
    if (!hosts.length) return toast("Nessun host in ~/.ssh/config");
    window.IDE.contextMenu(e || { clientX: 200, clientY: 120 }, hosts.map(x => ({
      label: `${x.alias}${x.hostName ? "  " + (x.user ? x.user + "@" : "") + x.hostName : ""}${x.imported ? "  (già importato)" : ""}`,
      disabled: x.imported,
      action: async () => { try { await call("conn.importSSH", { alias: x.alias }); C.list = await call("conn.list"); renderRemote(); toast(`${x.alias} importato`, "ok"); } catch (er) { err(er); } },
    })));
  }

  let rmRender = 0;
  async function renderRemote() {
    if (!rmPane) return;
    const tree = rmPane.querySelector(".cx-tree");
    const n = ++rmRender;
    const frag = document.createDocumentFragment();
    const hosts = C.list.filter(c => c.kind === "ssh");
    if (!hosts.length) {
      const e = h("div", "cx-empty");
      e.append(h("div", "", "Nessun server salvato."));
      const b1 = h("button", "btn", "Nuovo host"); b1.onclick = () => editConnection({ kind: "ssh" });
      const b2 = h("button", "btn", "Importa da ~/.ssh/config"); b2.onclick = ev => importSshConfig(ev);
      e.append(b1, b2); frag.append(e);
    }
    for (const c of hosts) {
      const open = C.remoteOpen.has(c.id);
      const r = row(0, c.name, "cxServer", { expandable: true, open, cls: c.production ? "prod" : "", iconCls: c.connected ? "on" : "", meta: c.destination,
        toggle: () => { open ? C.remoteOpen.delete(c.id) : C.remoteOpen.add(c.id); renderRemote(); },
        dbl: () => openTerminal(c), menu: () => hostMenu(c) });
      if (c.color) r.style.setProperty("--cx-color", colorOf(c.color));
      frag.append(r);
      if (open) await renderRemoteDir(c, null, 1, frag);
    }
    if (n !== rmRender) return;
    tree.innerHTML = ""; tree.append(frag);
  }

  async function listRemote(c, path) {
    const key = c.id + "|" + (path || "");
    if (C.remoteCache.has(key)) return C.remoteCache.get(key);
    const r = await call("ssh.list", { id: c.id, path: path || "" });
    C.remoteCache.set(key, r);
    if (!path) C.remoteCache.set(c.id + "|" + r.path, r);
    return r;
  }

  async function renderRemoteDir(c, path, depth, frag) {
    let r;
    try { r = await listRemote(c, path); } catch (e) { frag.append(errRow(e, depth)); return; }
    if (!path) {
      frag.append(row(depth, r.path, "cxFolder", { cls: "grp", menu: () => dirMenu(c, r.path) }));
      depth++;
    }
    for (const it of r.entries) {
      const full = (r.path === "/" ? "" : r.path) + "/" + it.name;
      if (it.dir) {
        const k = c.id + "|" + full, open = C.remoteOpen.has(k);
        frag.append(row(depth, it.name, "cxFolder", { expandable: true, open, cls: it.name.startsWith(".") ? "dim" : "", meta: it.link ? "link" : "",
          toggle: () => { open ? C.remoteOpen.delete(k) : C.remoteOpen.add(k); renderRemote(); }, menu: () => dirMenu(c, full) }));
        if (open) await renderRemoteDir(c, full, depth + 1, frag);
      } else {
        frag.append(row(depth, it.name, "cxFile", { cls: it.name.startsWith(".") ? "dim" : "", meta: size(it.size),
          dbl: () => openRemoteFile(c, full), menu: () => fileMenu(c, full, it) }));
      }
    }
  }
  const size = b => b < 1024 ? b + " B" : b < 1048576 ? (b / 1024).toFixed(1) + " KB" : (b / 1048576).toFixed(1) + " MB";
  const parent = p => p.slice(0, p.lastIndexOf("/")) || "/";
  const refreshDir = (c, dir) => { C.remoteCache.delete(c.id + "|" + dir); if (dir === "") C.remoteCache.clear(); renderRemote(); };

  function hostMenu(c) {
    return [
      { label: "Apri terminale SSH", action: () => openTerminal(c) },
      { label: "Sfoglia file", action: () => { C.remoteOpen.add(c.id); renderRemote(); } },
      { label: c.connected ? "Disconnetti" : "Connetti", action: async () => {
        try { await call(c.connected ? "ssh.disconnect" : "ssh.connect", { id: c.id }); } catch (e) { err(e); }
      } },
      ...((c.forwards || []).length ? [{ separator: true }] : []),
      ...(c.forwards || []).map((f, i) => ({ label: `Inoltro ${f.localPort} → ${f.remoteHost}:${f.remotePort}`, action: async () => {
        try {
          const list = await call("ssh.forwards", { id: c.id });
          const active = list[i] && list[i].active;
          await call("ssh.forward", { id: c.id, index: i, start: !active });
          toast(active ? "Inoltro fermato" : `Inoltro attivo: localhost:${f.localPort}`, "ok");
        } catch (e) { err(e); }
      } })),
      { separator: true },
      { label: "Nuovo database tramite questo host…", action: () => editConnection({ kind: "mysql", sshVia: c.id, host: "127.0.0.1" }) },
      { label: "Modifica…", action: () => editConnection(c) },
      { label: "Elimina…", danger: true, action: async () => {
        if (await window.IDE.confirm(`Elimino l'host ${c.name}?`, { danger: true })) await call("conn.delete", { id: c.id }).catch(err);
      } },
    ];
  }
  function dirMenu(c, dir) {
    return [
      { label: "Carica qui…", action: async () => {
        try { const n = await call("ssh.upload", { id: c.id, dir }); if (n) { toast(`${n} elementi caricati`, "ok"); refreshDir(c, dir); } } catch (e) { err(e); }
      } },
      { label: "Nuovo file…", action: async () => {
        const name = await window.IDE.prompt("Nome del nuovo file", ""); if (!name) return;
        try { await call("ssh.touch", { id: c.id, path: dir + "/" + name }); refreshDir(c, dir); openRemoteFile(c, dir + "/" + name); } catch (e) { err(e); }
      } },
      { label: "Nuova cartella…", action: async () => {
        const name = await window.IDE.prompt("Nome della nuova cartella", ""); if (!name) return;
        try { await call("ssh.mkdir", { id: c.id, path: dir + "/" + name }); refreshDir(c, dir); } catch (e) { err(e); }
      } },
      { label: "Terminale qui", action: () => openTerminal(c, dir) },
      { label: "Scarica cartella…", action: () => download(c, dir) },
      { label: "Copia percorso", action: () => navigator.clipboard.writeText(dir) },
      { label: "Aggiorna", action: () => refreshDir(c, dir) },
      { separator: true },
      { label: "Rinomina…", action: () => rename(c, dir) },
      { label: "Permessi…", action: () => chmod(c, dir) },
      { label: "Elimina cartella…", danger: true, action: () => remove(c, dir, true) },
    ];
  }
  function fileMenu(c, path, it) {
    return [
      { label: "Apri", action: () => openRemoteFile(c, path) },
      { label: "Scarica…", action: () => download(c, path) },
      { label: "Copia percorso", action: () => navigator.clipboard.writeText(path) },
      { separator: true },
      { label: "Rinomina…", action: () => rename(c, path) },
      { label: `Permessi (${it.mode})…`, action: () => chmod(c, path, it.mode) },
      { label: "Elimina…", danger: true, action: () => remove(c, path, false) },
    ];
  }
  async function download(c, path) {
    try { const p = await call("ssh.download", { id: c.id, path }); if (p) toast("Scaricato in " + p, "ok"); } catch (e) { err(e); }
  }
  async function rename(c, path) {
    const name = await window.IDE.prompt("Nuovo nome", path.split("/").pop());
    if (!name || name === path.split("/").pop()) return;
    try { await call("ssh.rename", { id: c.id, from: path, to: parent(path) + "/" + name }); refreshDir(c, parent(path)); } catch (e) { err(e); }
  }
  async function chmod(c, path, mode) {
    const m = await window.IDE.prompt("Permessi (es. 644 o 755)", mode || "644");
    if (!m) return;
    try { await call("ssh.chmod", { id: c.id, path, mode: m }); refreshDir(c, parent(path)); toast("Permessi aggiornati", "ok"); } catch (e) { err(e); }
  }
  async function remove(c, path, dir) {
    if (!(await window.IDE.confirm(`Elimino ${path} da ${c.name}?`, { danger: true, note: dir ? "La cartella e tutto il suo contenuto vengono cancellati dal server. Non si può annullare." : "Non si può annullare." }))) return;
    try { await call("ssh.delete", { id: c.id, path }); refreshDir(c, parent(path)); } catch (e) { err(e); }
  }

  async function openTerminal(c, dir) {
    try {
      const r = await call("ssh.terminal", { id: c.id, dir: dir || "" });
      window.IDE.openTerminal({ title: r.title, command: r.command });
    } catch (e) { err(e); }
  }

  // Remote file in an editor tab: saving uploads it, with a check that nobody changed it meanwhile.
  async function openRemoteFile(c, path) {
    try {
      const r = await call("ssh.read", { id: c.id, path });
      if (r.binary) { if (await window.IDE.confirm("File binario: lo scarico?", {})) download(c, path); return; }
      let mtime = r.mtime;
      window.IDE.openEditorTab({
        id: `remote:${c.id}:${path}`, title: `${path.split("/").pop()} · ${c.name}`, content: r.content,
        language: undefined,
        onSave: async text => {
          let w = await call("ssh.write", { id: c.id, path, content: text, mtime });
          if (w.conflict) {
            const ok = await window.IDE.confirm(`${path.split("/").pop()} è cambiato sul server`, { danger: true, note: "Qualcuno l'ha modificato dopo che l'hai aperto. Sovrascrivo con la tua versione?", action: "Sovrascrivi" });
            if (!ok) throw new Error("salvataggio annullato");
            w = await call("ssh.write", { id: c.id, path, content: text, force: true });
          }
          mtime = w.mtime;
          toast(`Caricato su ${c.name}`, "ok");
        },
      });
    } catch (e) { err(e); }
  }

  // ⌥⇧⌘X: the file in the editor goes to the server mapped to its project folder.
  async function uploadCurrentFile() {
    let path = null;
    try {
      if (window.IDE.activeFile) path = window.IDE.activeFile();
      if (!path && window.monaco && monaco.editor.getEditors) {
        const eds = monaco.editor.getEditors();
        const ed = eds.find(e => e.hasTextFocus()) || eds[0];
        const m = ed && ed.getModel();
        if (m && m.uri.scheme === "file") path = m.uri.fsPath || m.uri.path;
      }
    } catch {}
    if (!path) return toast("Apri un file del progetto per caricarlo");
    try {
      const r = await call("ssh.uploadLocal", { path });
      toast(`Caricato su ${r.name}: ${r.remotePath}`, "ok");
      C.remoteCache.delete(r.id + "|" + parent(r.remotePath));
    } catch (e) { err(e); }
  }
})();
