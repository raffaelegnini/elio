"use strict";
// Structure: symbols of the current file. TypeScript/JavaScript use Monaco's TS worker (navigation tree); the other
// languages (PHP above all, which Monaco only colors) use a light line scanner with brace/indent nesting. The same
// symbols feed the Structure tool window, the breadcrumb and Monaco's outline (⌘F12) for languages without one.

const SYM_STYLE = {
  class: ["#4C8EDA", "c"], interface: ["#4FB39A", "I"], trait: ["#C58AE0", "T"], enum: ["#D8A24A", "E"], struct: ["#4C8EDA", "s"],
  method: ["#E06C6C", "m"], function: ["#E5A04F", "f"], property: ["#B48AE0", "p"], field: ["#B48AE0", "p"], constant: ["#D8B04A", "C"],
  variable: ["#8C9AA8", "v"], namespace: ["#8C9AA8", "n"], heading: ["#7DA6D9", "#"], selector: ["#4A9FE0", "#"], key: ["#E5A24F", "k"],
  module: ["#8C9AA8", "n"], constructor: ["#E06C6C", "m"], extension: ["#4C8EDA", "x"],
};
function symbolIcon(kind) {
  const [c, t] = SYM_STYLE[kind] || ["#8C9AA8", "•"];
  return `<svg class="fi" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.2" fill="${c}26" stroke="${c}" stroke-width="1"/><text x="8" y="11" text-anchor="middle" font-size="8.5" font-weight="700" font-family="-apple-system,system-ui,sans-serif" fill="${c}">${t}</text></svg>`;
}

async function getSymbols(model) {
  if (!model || model.isDisposed()) return [];
  const v = model.getVersionId();
  if (model._sym && model._sym.v === v) return model._sym.list;
  let list = null;
  const lang = model.getLanguageId();
  if ((lang === "typescript" || lang === "javascript") && monaco.languages.typescript) {
    try {
      const getter = lang === "typescript" ? monaco.languages.typescript.getTypeScriptWorker : monaco.languages.typescript.getJavaScriptWorker;
      const worker = await (await getter())(model.uri);
      const tree = await worker.getNavigationTree(model.uri.toString());
      list = navToSymbols(model, (tree && tree.childItems) || []);
    } catch { list = null; }
  }
  if (!list) list = scanSymbols(model.getLinesContent(), lang);
  model._sym = { v, list };
  return list;
}
function navToSymbols(model, items) {
  const kinds = { class: "class", interface: "interface", enum: "enum", method: "method", function: "function", property: "property",
    const: "constant", let: "variable", var: "variable", constructor: "constructor", module: "namespace", type: "interface", getter: "method", setter: "method" };
  const out = [];
  for (const it of items) {
    if (!kinds[it.kind] || !it.spans || !it.spans.length) continue;
    const start = model.getPositionAt(it.spans[0].start), end = model.getPositionAt(it.spans[0].start + it.spans[0].length);
    out.push({ name: it.text, kind: kinds[it.kind], line: start.lineNumber, col: start.column, endLine: end.lineNumber,
      children: ["class", "interface", "module", "enum"].includes(it.kind) || it.kind === "function" ? navToSymbols(model, it.childItems || []) : [] });
  }
  return out;
}
// Line scanner. Each rule: [regex, kind, isContainer]. Nesting by braces (C-like) or indentation (Python, YAML).
const SYM_RULES = {
  php: [
    [/^\s*namespace\s+([\w\\]+)/, "namespace", false],
    [/^\s*(?:(?:abstract|final|readonly)\s+)*(class|interface|trait|enum)\s+(\w+)/, null, true],
    [/^\s*(?:(?:public|protected|private|static|abstract|final)\s+)*function\s+&?\s*(\w+)\s*\(/, "method", true],
    [/^\s*(?:(?:public|protected|private|final)\s+)*const\s+(?:\w+\s+)?(\w+)\s*=/, "constant", false],
    [/^\s*(?:public|protected|private|var)\s+(?:(?:static|readonly)\s+)*(?:\??[\w\\|]+\s+)?\$(\w+)/, "property", false],
  ],
  swift: [
    [/^\s*(?:(?:public|private|fileprivate|internal|open|final|@\w+)\s+)*(class|struct|enum|protocol|extension|actor)\s+([\w.]+)/, null, true],
    [/^\s*(?:(?:public|private|fileprivate|internal|open|final|static|override|mutating|nonisolated|@\w+(?:\([^)]*\))?)\s+)*func\s+(\w+)/, "method", true],
    [/^\s*(?:(?:public|private|fileprivate|internal|convenience|required|override)\s+)*init[?!]?\s*\(/, "constructor", true, "init"],
    [/^\s*(?:(?:public|private|fileprivate|internal|static|lazy|weak|override|@\w+(?:\([^)]*\))?)\s+)*(?:var|let)\s+(\w+)/, "property", false],
  ],
  generic: [
    [/^\s*(?:(?:export|default|public|private|protected|internal|abstract|final|static|sealed|data|open|pub(?:\([\w]+\))?)\s+)*(class|interface|enum|struct|trait|impl|object|record)\s+([\w<>, ]+?)\s*(?:[:{(]|extends|implements|where|$)/, null, true],
    [/^\s*(?:(?:export|default|async|public|private|protected|internal|static|override|suspend|pub(?:\([\w]+\))?|unsafe|const)\s+)*(?:function\*?|fn|func|fun|def)\s+(?:\([^)]*\)\s*)?(\w+)/, "function", true],
  ],
  shell: [[/^\s*(?:function\s+)?([\w-]+)\s*\(\)\s*\{?/, "function", true]],
  css: [[/^\s*(@media[^{]+|@supports[^{]+|[^@{}\s/][^{};]*?)\s*\{/, "selector", true]],
};
function scanSymbols(lines, lang) {
  if (lang === "markdown") return scanHeadings(lines);
  if (lang === "python") return scanIndented(lines, [[/^(\s*)(?:async\s+)?def\s+(\w+)/, "method"], [/^(\s*)class\s+(\w+)/, "class"]]);
  if (lang === "yaml") return scanIndented(lines, [[/^(\s{0,4})([\w.\-"']+)\s*:/, "key"]], 4);
  const rules = SYM_RULES[lang === "php" ? "php" : lang === "swift" ? "swift" : lang === "shell" ? "shell" : ["css", "scss", "less"].includes(lang) ? "css" : "generic"];
  const isCss = ["css", "scss", "less"].includes(lang);
  const root = { children: [] }, stack = [{ sym: root, depth: -1 }];
  let depth = 0, inBlock = false;
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    // Strip comments and strings so their braces don't count.
    if (inBlock) { const e = line.indexOf("*/"); if (e < 0) continue; line = line.slice(e + 2); inBlock = false; }
    line = line.replace(/\/\*.*?\*\//g, "").replace(/(["'`])(?:\\.|(?!\1).)*\1/g, "\"\"");
    const bc = line.indexOf("/*"); if (bc >= 0) { line = line.slice(0, bc); inBlock = true; }
    line = line.replace(isCss ? /(^|\s)\/\/.*$/ : /(^|\s)(\/\/|#(?![\[{])).*$/, "$1");
    if (lang === "php" && /^\s*\*/.test(lines[i])) continue;
    for (const [rx, kind, container, fixedName] of rules) {
      const m = rx.exec(line);
      if (!m) continue;
      const k = kind || (m[1] === "protocol" ? "interface" : m[1] === "impl" || m[1] === "object" || m[1] === "record" ? "class" : m[1]);
      const name = (fixedName || (kind ? m[1] : m[2]) || "").trim();
      if (!name || ["if", "for", "while", "switch", "catch", "return", "function"].includes(name)) break;
      while (stack.length > 1 && stack[stack.length - 1].depth >= depth) { stack[stack.length - 1].sym.endLine = i; stack.pop(); }
      const parent = stack[stack.length - 1].sym;
      const sym = { name, kind: k === "method" && parent === root ? "function" : k,
        line: i + 1, col: Math.max(1, lines[i].search(/\S/) + 1), endLine: i + 1, children: [] };
      parent.children.push(sym);
      if (container) stack.push({ sym, depth, open: false });
      break;
    }
    for (const ch of line) {
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        while (stack.length > 1 && stack[stack.length - 1].depth >= depth) { stack[stack.length - 1].sym.endLine = i + 1; stack.pop(); }
      }
    }
    // A container that ended without a block (abstract method, `fn x();`): close it.
    const top = stack[stack.length - 1];
    if (stack.length > 1 && top.sym.line === i + 1 && /;\s*$/.test(line) && !line.includes("{")) { top.sym.endLine = i + 1; stack.pop(); }
  }
  while (stack.length > 1) { stack.pop().sym.endLine = lines.length; }
  return root.children;
}
function scanIndented(lines, rules, maxIndent = 99) {
  const root = { children: [] }, stack = [{ sym: root, ind: -1 }];
  lines.forEach((line, i) => {
    if (!line.trim() || /^\s*#/.test(line)) return;
    const ind = line.search(/\S/);
    while (stack.length > 1 && stack[stack.length - 1].ind >= ind) { stack[stack.length - 1].sym.endLine = i; stack.pop(); }
    if (ind > maxIndent) return;
    for (const [rx, kind] of rules) {
      const m = rx.exec(line); if (!m) continue;
      const parent = stack[stack.length - 1].sym;
      const sym = { name: m[2].replace(/^["']|["']$/g, ""), kind: kind === "method" && parent === root ? "function" : kind, line: i + 1, col: ind + 1, endLine: lines.length, children: [] };
      parent.children.push(sym); stack.push({ sym, ind });
      break;
    }
  });
  return root.children;
}
function scanHeadings(lines) {
  const root = { children: [], level: 0 }, stack = [root];
  let fence = false;
  lines.forEach((line, i) => {
    if (/^\s*```/.test(line)) fence = !fence;
    const m = !fence && /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line); if (!m) return;
    const level = m[1].length;
    while (stack.length > 1 && stack[stack.length - 1].level >= level) { stack[stack.length - 1].endLine = i; stack.pop(); }
    const sym = { name: m[2], kind: "heading", line: i + 1, col: 1, endLine: lines.length, children: [], level };
    stack[stack.length - 1].children.push(sym); stack.push(sym);
  });
  return root.children;
}
async function symbolChainAt(model, line) {
  const chain = [];
  let list = await getSymbols(model);
  for (let guard = 0; guard < 8; guard++) {
    const hit = [...list].reverse().find(s => s.line <= line && (s.endLine || s.line) >= line && (s.children.length || ["method", "function", "constructor", "class", "interface", "trait", "enum", "struct", "heading", "selector", "key", "extension"].includes(s.kind)));
    if (!hit) break;
    chain.push(hit);
    list = hit.children || [];
  }
  return chain;
}

// Monaco outline (⌘F12, sticky scroll) for languages that have no symbol provider of their own.
onBoot(() => {
  const SK = monaco.languages.SymbolKind;
  const map = { class: SK.Class, interface: SK.Interface, trait: SK.Interface, enum: SK.Enum, struct: SK.Struct, method: SK.Method, function: SK.Function,
    property: SK.Property, field: SK.Field, constant: SK.Constant, variable: SK.Variable, namespace: SK.Namespace, heading: SK.String, key: SK.Key,
    constructor: SK.Constructor, extension: SK.Class, selector: SK.Class };
  const toDoc = (model, s) => {
    const end = Math.min(Math.max(s.endLine || s.line, s.line), model.getLineCount());
    return { name: s.name, detail: "", kind: map[s.kind] ?? SK.Variable, tags: [],
      range: { startLineNumber: s.line, startColumn: 1, endLineNumber: end, endColumn: model.getLineMaxColumn(end) },
      selectionRange: { startLineNumber: s.line, startColumn: s.col || 1, endLineNumber: s.line, endColumn: model.getLineMaxColumn(s.line) },
      children: (s.children || []).map(c => toDoc(model, c)) };
  };
  for (const lang of ["php", "python", "swift", "markdown", "shell", "yaml", "go", "rust", "java", "kotlin", "ruby", "csharp", "dart", "scala", "cpp", "c"]) {
    monaco.languages.registerDocumentSymbolProvider(lang, {
      displayName: "Elio",
      provideDocumentSymbols: model => scanSymbols(model.getLinesContent(), model.getLanguageId()).map(s => toDoc(model, s)),
    });
  }
  let t;
  const refresh = () => { clearTimeout(t); t = setTimeout(() => { if (TW.get("structure").visible) renderStructure(); }, 400); };
  on("tabChanged", refresh);
  editor.onDidChangeModelContent(refresh);
  editor.onDidChangeCursorPosition(() => { if (TW.get("structure").visible) markStructureCursor(); });
});

// ---------- Structure tool window ----------
const stw = {};
registerToolWindow({
  id: "structure", title: "Struttura", icon: "structure", side: "left", slot: "top", order: 26, key: "⌘7",
  mount(box) {
    box.classList.add("structure-pane");
    stw.filter = el("input", "st-filter"); stw.filter.placeholder = "Filtra i simboli";
    stw.list = el("div", "st-list");
    box.append(stw.filter, stw.list);
    stw.filter.oninput = renderStructure;
    stw.filter.onkeydown = e => { if (e.key === "Enter") { const f = stw.list.querySelector(".st-row"); if (f) f.click(); } if (e.key === "Escape") editor.focus(); };
  },
  onShow: () => renderStructure(),
  focus: () => stw.filter && stw.filter.focus(),
});
async function renderStructure() {
  if (!stw.list) return;
  const t = S.active;
  stw.list.innerHTML = "";
  if (!t) { stw.list.append(el("div", "empty", "Nessun file aperto.")); return; }
  const syms = await getSymbols(t.model);
  if (S.active !== t) return;
  stw.list.innerHTML = "";
  const q = stw.filter.value.trim().toLowerCase();
  const head = el("div", "st-file"); const ic = el("span", "ic"); ic.innerHTML = t.virtual ? fileIcon(t.title, false) : fileIcon(basename(t.path), false);
  head.append(ic, el("span", "", t.virtual ? t.title : basename(t.path)));
  stw.list.append(head);
  let count = 0;
  const walk = (list, depth) => {
    for (const s of list) {
      const match = !q || s.name.toLowerCase().includes(q);
      if (match) {
        const row = el("div", "st-row"); row.style.paddingLeft = (10 + depth * 16) + "px";
        row.dataset.line = s.line; row.dataset.end = s.endLine || s.line;
        const i = el("span", "ic"); i.innerHTML = symbolIcon(s.kind);
        const nm = el("span", "nm"); nm.append(q ? highlight(q, s.name) : s.name);
        row.append(i, nm, el("span", "ln", String(s.line)));
        row.onclick = () => { editor.revealLineInCenter(s.line); editor.setPosition({ lineNumber: s.line, column: s.col || 1 }); editor.focus(); };
        stw.list.append(row); count++;
      }
      walk(s.children || [], match || !q ? depth + 1 : depth);
    }
  };
  walk(syms, 0);
  if (!count) stw.list.append(el("div", "empty", q ? "Nessun simbolo corrisponde." : "Nessun simbolo trovato in questo file."));
  markStructureCursor();
}
function markStructureCursor() {
  if (!stw.list || !editor.getPosition()) return;
  const line = editor.getPosition().lineNumber;
  let best = null;
  stw.list.querySelectorAll(".st-row").forEach(r => { r.classList.remove("cur"); if (+r.dataset.line <= line && +r.dataset.end >= line) best = r; });
  if (best) { best.classList.add("cur"); }
}
