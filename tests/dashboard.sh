#!/usr/bin/env bash
# Tests for the dashboard's pure logic — the parts of dashboard.html that decide
# what a row says, what a copied command is, and what is remembered in the
# browser. Nothing here opens a port, reads the real ~/.claude, or needs a
# display: the page's <script> blocks are sliced out by section banner and run
# under node against stubbed storage and DOM.
#
# node is NOT a dependency of claudius. It ships with Claude Code, so it is
# almost always present, and when it is not this suite skips rather than fails —
# the CLI itself must never need it.
#
# The slicing keys off the `/* ═══════════ <name> ═══…*/` banners already in the
# file. Rename a banner and the extraction fails loudly, with the name it wanted;
# it never silently tests nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGE="$ROOT/dashboard.html"

if ! command -v node >/dev/null 2>&1; then
  printf 'skipped: node not found (the dashboard suite needs it; claudius does not)\n'
  exit 0
fi
if [[ ! -f "$PAGE" ]]; then
  printf 'dashboard.html not found next to tests/\n' >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claudius-dash.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── Extract ───────────────────────────────────────────────────────────────────
# Two scripts live in the page: the small pre-paint appearance restore in <head>
# and the main IIFE. Both are pulled out whole, then the main one is sliced into
# the sections the tests need.
ruby - "$PAGE" "$WORK" <<'RB'
page, work = ARGV[0], ARGV[1]
html = File.read(page)
scripts = html.scan(%r{<script[^>]*>(.*?)</script>}m).flatten
abort 'expected two <script> blocks in dashboard.html' unless scripts.length == 2
main = scripts.max_by(&:length)
File.write(File.join(work, 'head.js'), scripts.min_by(&:length))
File.write(File.join(work, 'main.js'), main)

# A section runs from its banner to the next banner (or to end of script). The
# closing */ is not required on the banner line: some banners carry a paragraph of
# explanation underneath, and the slice keeps the whole comment either way.
BANNER = %r{^\s*/\* [═]+ (.+?) [═]+}
marks = []
main.each_line.with_index { |l, i| (m = l.match(BANNER)) && marks << [m[1].strip, i] }
lines = main.lines
sections = {}
marks.each_with_index do |(name, at), k|
  stop = marks[k + 1] ? marks[k + 1][1] : lines.length
  # Start after the banner comment *closes*, not after its first line: dropping the
  # opening /* while keeping the paragraph under it would leave loose prose in the
  # slice, which is a syntax error rather than a comment.
  close = (at...stop).find { |i| lines[i].include?('*/') } || at
  sections[name] = lines[(close + 1)...stop].join
end

want = ['linked sessions', 'history']
missing = want.reject { |w| sections.key?(w) }
abort "banner section(s) not found: #{missing.join(', ')} (have: #{sections.keys.join(' | ')})" if missing.any?

# Chunks that are not whole sections, taken by their opening line and matching
# brace-depth so an edit inside them does not change the slice.
def chunk(src, start_re, label)
  lines = src.lines
  i = lines.index { |l| l =~ start_re } or abort "chunk not found: #{label}"
  depth = 0
  out = []
  lines[i..].each do |l|
    out << l
    depth += l.count('{') + l.count('(') - l.count('}') - l.count(')')
    break if depth <= 0 && out.length > 0
  end
  out.join
end

pieces = {
  'esc'   => chunk(main, /^  const esc = s =>/, 'esc'),
  'store' => chunk(main, /^  const store = \{/, 'store'),
  'looks' => chunk(main, /^  const LOOKS = /, 'LOOKS') +
             chunk(main, /^  const LOOK_DEFAULT = /, 'LOOK_DEFAULT') +
             chunk(main, /^  Object\.keys\(LOOKS\)\.forEach/, 'look repair') +
             chunk(main, /^  const cycleLook = /, 'cycleLook'),
  'biases' => main[/^  const BIASES = .*$/],
}
abort 'chunk not found: BIASES' if pieces['biases'].nil?
pieces.each { |k, v| File.write(File.join(work, "piece-#{k}.js"), v) }
File.write(File.join(work, 'sec-sessions.js'), sections['linked sessions'])
File.write(File.join(work, 'sec-history.js'), sections['history'])
RB
[[ $? -eq 0 ]] || { printf 'extraction failed\n' >&2; exit 1; }

# ── Harness ───────────────────────────────────────────────────────────────────
# The section code is wrapped in a function with a tail that exposes its
# internals, so tests can set state (SESSIONS, filters, cursor) that the page
# owns privately. Stubs stand in for everything that touches a browser.
cat > "$WORK/run.js" <<'JS'
const fs = require("fs");
const W = process.env.WORK;
const read = f => fs.readFileSync(`${W}/${f}`, "utf8");

let PASS = 0, FAIL = 0;
const ok = (name, cond) => {
  if (cond) { PASS++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  else { FAIL++; console.log(`  \x1b[31m✗\x1b[0m ${name}`); }
};
const eq = (name, got, want) => {
  const good = JSON.stringify(got) === JSON.stringify(want);
  ok(good ? name : `${name}\n      got:  ${JSON.stringify(got)}\n      want: ${JSON.stringify(want)}`, good);
};

// ── stubs ────────────────────────────────────────────────────────────────────
function freshStorage(seed){
  const db = Object.assign({}, seed || {});
  globalThis.localStorage = {
    getItem: k => (k in db ? db[k] : null),
    setItem: (k, v) => { db[k] = String(v); },
  };
  return db;
}
const NODES = {};
function stubDom(){
  const node = id => (NODES[id] = NODES[id] || {
    id, textContent:"", innerHTML:"", value:"", hidden:false, disabled:false,
    className:"", dataset:{}, style:{},
    classList:{ list:new Set(),
      add(c){ this.list.add(c); }, remove(c){ this.list.delete(c); },
      toggle(c, on){ on ? this.list.add(c) : this.list.delete(c); },
      contains(c){ return this.list.has(c); } },
    setAttribute(k, v){ this.dataset[k] = v; },
    insertAdjacentHTML(_, h){ this.innerHTML += h; },
    scrollIntoView(){},
  });
  globalThis.$ = sel => node(String(sel).replace(/^#/, ""));
  globalThis.$$ = () => [];
  globalThis.document = { documentElement:{ dataset:{ bias:"neutral", sevset:"punchy" } } };
  return node;
}
const LOGS = [];
globalThis.log = (kind, msg) => LOGS.push({ kind, msg });
globalThis.toast = () => {};
globalThis.esc = null;   // replaced by the page's own esc below

// The sessions section, wrapped so its private state is reachable.
function loadSessions(state){
  const src = [
    read("piece-esc.js"),
    read("piece-store.js"),
    "let PROFILES = [];",
    "let ACTIVE = '';",
    "const activeName = () => ACTIVE;",
    read("sec-sessions.js"),
  ].join("\n");
  const tail = `
    return {
      fns:{ shq, resumeCmd, projName, projPath, weightOf, stamp, sessAge, sessMatch,
            visibleSessions, sessProjects, markHits, sessLabelHTML, sessLabelHint,
            sessWho, cycleSessWho, paintSessions, paintScope, moveSessCursor:
            (typeof moveSessCursor === 'function' ? moveSessCursor : null) },
      set:(o) => {
        if ('SESSIONS' in o) SESSIONS = o.SESSIONS;
        if ('sessScope' in o) sessScope = o.sessScope;
        if ('sessQ' in o) sessQ = o.sessQ;
        if ('sessLimit' in o) sessLimit = o.sessLimit;
        if ('sessCursor' in o) sessCursor = o.sessCursor;
        if ('sessTarget' in o) sessTarget = o.sessTarget;
        if ('PROFILES' in o) PROFILES = o.PROFILES;
        if ('ACTIVE' in o) ACTIVE = o.ACTIVE;
      },
      get:() => ({ sessScope, sessQ, sessLimit, sessCursor, sessTarget }),
    };`;
  const api = new Function(`${src}\n${tail}`)();
  if (state) api.set(state);
  return api;
}

// The history section, wrapped the same way. HIST and NEXT are private to the
// page, and everything here has to hold against a shape the real data can
// actually take — including a profile with no history at all, which is what a
// fresh install looks like for its first few minutes.
function loadHistory(state){
  const src = [
    read("piece-esc.js"),
    "let ACTIVE = '';",
    "const activeName = () => ACTIVE;",
    read("sec-history.js"),
  ].join("\n");
  const tail = `
    return {
      fns:{ etaText, etaSev, sparkSVG, trendHTML, nextChip, histOf, nextPick },
      set:(o) => {
        if ('HIST' in o) HIST = o.HIST;
        if ('NEXT' in o) NEXT = o.NEXT;
        if ('ACTIVE' in o) ACTIVE = o.ACTIVE;
      },
    };`;
  const api = new Function(`${src}\n${tail}`)();
  if (state) api.set(state);
  return api;
}

// A sample series: n points, `mins` apart, ending now, value from f(i).
const series = (n, f, mins = 2) => {
  const now = Math.floor(Date.now() / 1000);
  return Array.from({ length:n }, (_, i) =>
    [now - (n - 1 - i) * mins * 60, f(i), f(i)]);
};

const S = (over) => Object.assign({
  id:"11111111-1111-1111-1111-111111111111", cwd:"/home/a/claudius", short:"~/claudius",
  exists:true, dirkey:"-home-a-claudius", label:"Fix the card", lsrc:"title",
  branch:"main", mts:1700000000, size:1000,
}, over || {});

// ── 1. resume commands ───────────────────────────────────────────────────────
console.log("1. resume commands");
{
  freshStorage(); stubDom();
  const a = loadSessions({ PROFILES:[{name:"main"},{name:"other"}], ACTIVE:"main" });
  const s = S();
  eq("active account uses bare claude",
    a.fns.resumeCmd(s, "main"), `cd /home/a/claudius && claude --resume ${s.id}`);
  eq("other account goes through claudius run",
    a.fns.resumeCmd(s, "other"), `cd /home/a/claudius && claudius run other --resume ${s.id}`);
  eq("no cwd means no cd clause",
    a.fns.resumeCmd(S({cwd:null}), "other"), `claudius run other --resume ${s.id}`);
  eq("plain path is left unquoted", a.fns.shq("/home/a/b-c_d.e"), "/home/a/b-c_d.e");
  eq("a space forces quoting", a.fns.shq("/home/a/My Code"), "'/home/a/My Code'");
  eq("an apostrophe is escaped", a.fns.shq("/home/a/it's"), "'/home/a/it'\\''s'");
  eq("a dollar sign forces quoting", a.fns.shq("/home/$USER/x"), "'/home/$USER/x'");
  eq("a semicolon forces quoting", a.fns.shq("/a;rm -rf b"), "'/a;rm -rf b'");
  eq("a backtick forces quoting", a.fns.shq("/a/`id`"), "'/a/`id`'");
}

// ── 2. row fields ────────────────────────────────────────────────────────────
console.log("2. row fields");
{
  freshStorage(); stubDom();
  const a = loadSessions();
  eq("project is the basename", a.fns.projName(S()), "claudius");
  eq("home itself stays a tilde", a.fns.projName(S({short:"~", cwd:"/home/a"})), "~");
  eq("trailing slash tolerated", a.fns.projName(S({short:null, cwd:"/home/a/work/"})), "work");
  eq("tooltip path prefers the short form", a.fns.projPath(S()), "~/claudius");
  // A row with no cwd of its own borrows the path from a sibling in the same
  // project directory, rather than showing the raw encoded key.
  a.set({ SESSIONS:[S(), S({ id:"x", cwd:null, short:null })] });
  eq("a cwd-less row inherits its project path",
     a.fns.projPath(S({ id:"x", cwd:null, short:null })), "~/claudius");
  eq("and shows the sibling's project name",
     a.fns.projName(S({ id:"x", cwd:null, short:null })), "claudius");
  a.set({ SESSIONS:[S({ id:"x", cwd:null, short:null, dirkey:"-alone" })] });
  eq("with no sibling it says so instead of leaking the key",
     a.fns.projName(S({ id:"x", cwd:null, short:null, dirkey:"-alone" })), "unknown project");
  a.set({ SESSIONS:[] });
  eq("weight hidden under a megabyte", a.fns.weightOf(S({size:900000})), "");
  eq("weight shown with one decimal", a.fns.weightOf(S({size:2621440})), "2.5MB");
  eq("weight rounds past ten megabytes", a.fns.weightOf(S({size:34886109})), "33MB");
  eq("missing size is not a weight", a.fns.weightOf(S({size:null})), "");
  ok("stamp renders a real date", /\d/.test(a.fns.stamp(1700000000)));
  eq("stamp of nothing", a.fns.stamp(0), "never");
  eq("age in seconds", a.fns.sessAge(Math.floor(Date.now()/1000) - 5), "5s");
  eq("age in minutes", a.fns.sessAge(Math.floor(Date.now()/1000) - 300), "5m");
  eq("age in hours", a.fns.sessAge(Math.floor(Date.now()/1000) - 7200), "2h");
  eq("age in days", a.fns.sessAge(Math.floor(Date.now()/1000) - 172800), "2d");
}

// ── 3. search and scope ──────────────────────────────────────────────────────
console.log("3. search and scope");
{
  freshStorage(); stubDom();
  const rows = [
    S({ id:"a", label:"Fix the dashboard card", branch:"main", mts:300 }),
    S({ id:"b", label:null, lsrc:null, branch:"api-part8", mts:200 }),
    S({ id:"c", cwd:"/home/a/other", short:"~/other", dirkey:"-home-a-other",
        label:"Table & filter <issue>", branch:null, mts:400 }),
  ];
  const a = loadSessions({ SESSIONS:rows });
  const ids = () => a.fns.visibleSessions().map(s => s.id).join(",");
  a.set({ sessQ:"dashboard" }); eq("matches the label", ids(), "a");
  a.set({ sessQ:"PART8" });     eq("case-insensitive on branch", ids(), "b");
  a.set({ sessQ:"other" });     eq("matches the path", ids(), "c");
  a.set({ sessQ:"a" });         ok("id match works", a.fns.visibleSessions().length >= 1);
  a.set({ sessQ:"zzz" });       eq("no match is empty", ids(), "");
  a.set({ sessQ:"   " });       eq("whitespace query shows all", ids(), "a,b,c");
  a.set({ sessQ:"" });          eq("empty query shows all", ids(), "a,b,c");
  a.set({ sessQ:"untitled" });  eq("a null label matches nothing", ids(), "");
  a.set({ sessQ:"", sessScope:"-home-a-claudius" }); eq("scope narrows", ids(), "a,b");
  a.set({ sessQ:"part8" });     eq("scope and query compose", ids(), "b");
  a.set({ sessQ:"other" });     eq("scope beats a cross-project match", ids(), "");
  a.set({ sessQ:"", sessScope:"" });
  const p = a.fns.sessProjects();
  eq("one entry per project", p.length, 2);
  eq("ordered by most recent", p[0].key, "-home-a-other");
  eq("counts per project", [p[0].n, p[1].n], [1, 2]);
}

// ── 4. highlighting escapes first ────────────────────────────────────────────
console.log("4. highlighting escapes first");
{
  freshStorage(); stubDom();
  const a = loadSessions();
  const m = a.fns.markHits;
  eq("plain highlight", m("Fix the card", "card"), "Fix the <mark>card</mark>");
  eq("every occurrence", m("aXaXa", "x"), "a<mark>X</mark>a<mark>X</mark>a");
  eq("no query still escapes", m("Table & filter <issue>", ""), "Table &amp; filter &lt;issue&gt;");
  eq("escapes while marking", m("Table & filter <issue>", "filter"),
     "Table &amp; <mark>filter</mark> &lt;issue&gt;");
  eq("a query cannot match inside an entity", m("a & b", "amp"), "a &amp; b");
  eq("angle brackets escaped inside the mark", m("x <issue> y", "<issue>"),
     "x <mark>&lt;issue&gt;</mark> y");
  ok("a script payload cannot escape",
     !m("<script>alert(1)</script>", "script").includes("<script>"));
  eq("a quote payload is escaped", m('" onerror="x', "onerror"),
     "&quot; <mark>onerror</mark>=&quot;x");
  eq("null text is empty", m(null, "a"), "");
}

// ── 5. label source shows as itself ──────────────────────────────────────────
console.log("5. label source shows as itself");
{
  freshStorage(); stubDom();
  const a = loadSessions();
  const h = a.fns.sessLabelHTML;
  eq("a title reads as a name", h(S({label:"Real Title", lsrc:"title"}), ""), "Real Title");
  eq("a prompt is quoted", h(S({label:"why so slow", lsrc:"prompt"}), ""),
     '<span class="qm">“</span>why so slow<span class="qm">”</span>');
  ok("a last prompt is quoted too", h(S({label:"x", lsrc:"last"}), "").includes("qm"));
  eq("a command is not quoted", h(S({label:"/resume", lsrc:"command"}), ""), "/resume");
  eq("a slug is not quoted", h(S({label:"fix the card", lsrc:"slug"}), ""), "fix the card");
  eq("nothing said", h(S({label:null, lsrc:null}), ""), "empty session");
  eq("highlight survives inside quotes", h(S({label:"rails runner", lsrc:"prompt"}), "runner"),
     '<span class="qm">“</span>rails <mark>runner</mark><span class="qm">”</span>');
  eq("an unknown source falls back to bare", h(S({label:"z", lsrc:"from-the-future"}), ""), "z");
  ok("the hint names the source", a.fns.sessLabelHint(S({label:"x", lsrc:"prompt"}))
     .includes("first prompt"));
  ok("an unknown source has no hint",
     a.fns.sessLabelHint(S({label:"x", lsrc:"nope"})) === "x");
}

// ── 6. keyboard cursor ───────────────────────────────────────────────────────
console.log("6. keyboard cursor");
{
  freshStorage(); stubDom();
  const rows = [S({id:"a"}), S({id:"b"}), S({id:"c"})];
  const a = loadSessions({ SESSIONS:rows, PROFILES:[{name:"p"}], ACTIVE:"p" });
  if (!a.fns.moveSessCursor){ ok("moveSessCursor is reachable", false); }
  else {
    a.fns.moveSessCursor(1);  eq("first down picks the top row", a.get().sessCursor, 0);
    a.fns.moveSessCursor(1);  eq("down moves on", a.get().sessCursor, 1);
    a.fns.moveSessCursor(-1); eq("up moves back", a.get().sessCursor, 0);
    a.fns.moveSessCursor(-1); eq("up clamps at the top", a.get().sessCursor, 0);
    a.set({ sessCursor:2 });
    a.fns.moveSessCursor(1);  eq("down clamps at the bottom", a.get().sessCursor, 2);
    a.set({ sessCursor:-1 });
    a.fns.moveSessCursor(-1); eq("first up picks the last row", a.get().sessCursor, 2);
    a.set({ SESSIONS:[], sessCursor:-1 });
    a.fns.moveSessCursor(1);  eq("an empty list has no cursor", a.get().sessCursor, -1);
  }
}

// ── 7. resume-as target ──────────────────────────────────────────────────────
console.log("7. resume-as target");
{
  const db = freshStorage(); stubDom();
  const a = loadSessions({ PROFILES:[{name:"one"},{name:"two"}], ACTIVE:"one" });
  eq("defaults to the active account", a.fns.sessWho(), "one");
  a.set({ sessTarget:"two" });
  eq("a remembered target is honoured", a.fns.sessWho(), "two");
  a.set({ sessTarget:"gone" });
  eq("a removed profile falls back to active", a.fns.sessWho(), "one");
  a.set({ PROFILES:[], ACTIVE:"", sessTarget:"x" });
  eq("no profiles means no target", a.fns.sessWho(), "");
  a.set({ PROFILES:[{name:"z"}], ACTIVE:"", sessTarget:"" });
  eq("no active account uses the first profile", a.fns.sessWho(), "z");
  a.set({ PROFILES:[{name:"one"},{name:"two"}], ACTIVE:"one", sessTarget:"" });
  a.fns.cycleSessWho();
  eq("cycling advances", a.fns.sessWho(), "two");
  eq("cycling persists", db["claudius.sessTarget"], "two");
}

// ── 8. scope survives a reload ───────────────────────────────────────────────
console.log("8. scope survives a reload");
{
  const db = freshStorage({ "claudius.sessScope":"-home-a-claudius" }); stubDom();
  const a = loadSessions();
  a.fns.paintScope();
  eq("an unread pool keeps the remembered scope", a.get().sessScope, "-home-a-claudius");
  eq("and does not rewrite storage", db["claudius.sessScope"], "-home-a-claudius");
  a.set({ SESSIONS:[S({dirkey:"-home-a-claudius"})] });
  a.fns.paintScope();
  eq("a scope still in the pool is kept", a.get().sessScope, "-home-a-claudius");
  a.set({ SESSIONS:[S({dirkey:"-home-a-other"})] });
  a.fns.paintScope();
  eq("a scope whose project vanished reverts", a.get().sessScope, "");
  eq("the revert is persisted", db["claudius.sessScope"], "");
}

// ── 9. appearance restore, before the first paint ────────────────────────────
console.log("9. appearance restore, before the first paint");
{
  const looksApi = (seed) => {
    const db = freshStorage(seed);
    const root = { dataset:{ bias:"neutral", sevset:"punchy" } };
    globalThis.document = { documentElement: root };
    new Function(read("head.js"))();                      // the <head> restore
    const src = [read("piece-store.js"), read("piece-biases.js"), read("piece-looks.js")].join("\n");
    const api = new Function(`${src}; return { cycleLook };`)();
    return { db, root, ...api };
  };
  let b = looksApi({});
  eq("nothing stored leaves the document defaults",
     [b.root.dataset.bias, b.root.dataset.sevset], ["neutral", "punchy"]);
  eq("and writes nothing", Object.keys(b.db).length, 0);
  b = looksApi({ "claudius.bias":"warm", "claudius.sevset":"dusty" });
  eq("a stored look is restored", [b.root.dataset.bias, b.root.dataset.sevset], ["warm", "dusty"]);
  b = looksApi({});
  b.cycleLook("bias");
  eq("cycling advances", b.root.dataset.bias, "cool");
  eq("cycling persists", b.db["claudius.bias"], "cool");
  b.cycleLook("bias"); b.cycleLook("bias");
  eq("cycling wraps", b.root.dataset.bias, "neutral");
  b = looksApi({ "claudius.bias":"chartreuse" });
  eq("a bogus value is repaired", b.root.dataset.bias, "neutral");
  eq("and cleaned out of storage", b.db["claudius.bias"], "neutral");
  b = looksApi({ "claudius.sevset":"standard" });
  eq("a valid sibling is untouched", b.root.dataset.sevset, "standard");
}

// ── 10. storage that throws on every call ────────────────────────────────────
console.log("10. storage that throws on every call");
{
  globalThis.localStorage = {
    getItem(){ throw new Error("denied"); },
    setItem(){ throw new Error("denied"); },
  };
  const root = { dataset:{ bias:"neutral", sevset:"punchy" } };
  globalThis.document = { documentElement: root };
  let threw = false;
  try { new Function(read("head.js"))(); } catch (e) { threw = true; }
  ok("the head restore survives it", !threw && root.dataset.bias === "neutral");
  try {
    const src = [read("piece-store.js"), read("piece-biases.js"), read("piece-looks.js")].join("\n");
    const api = new Function(`${src}; return { cycleLook };`)();
    api.cycleLook("bias");
    ok("cycling survives it", root.dataset.bias === "cool");
  } catch (e) { ok("cycling survives it", false); }
  try {
    stubDom();
    const a = loadSessions({ SESSIONS:[S()] });
    ok("the sessions section still loads", a.fns.sessWho() === "");
  } catch (e) { ok("the sessions section still loads", false); }
}

console.log("11. usage history reads as time, not just numbers");
{
  freshStorage(); stubDom();
  const a = loadHistory();
  const { etaText, etaSev } = a.fns;
  const now = Math.floor(Date.now() / 1000);
  eq("a ceiling an hour out is a countdown", etaText(now + 3600), "in 60m");
  ok("one already reached is not a negative countdown", etaText(now - 5) === "any moment");
  ok("further out it becomes a clock time", /^at \d/.test(etaText(now + 4 * 3600)));
  ok("beyond today it carries a date",
     /^[A-Z][a-z]{2} \d/.test(etaText(now + 3 * 86400)));
  eq("under an hour is critical", etaSev(now + 1800), "crit");
  eq("under three hours is a warning", etaSev(now + 2 * 3600), "warn");
  eq("further out wears no severity colour", etaSev(now + 9 * 3600), "");
}

console.log("12. the sparkline is never auto-ranged");
{
  freshStorage(); stubDom();
  const { sparkSVG } = loadHistory().fns;
  const flatLow = sparkSVG(series(10, () => 3), 1);
  const flatHigh = sparkSVG(series(10, () => 90), 1);
  ok("a flat 3% and a flat 90% do not draw the same line", flatLow !== flatHigh);
  ok("the 90% line sits above the 3% one",
     parseFloat(flatHigh.match(/points="[\d.]+,([\d.]+)/)[1])
     < parseFloat(flatLow.match(/points="[\d.]+,([\d.]+)/)[1]));
  eq("two points are not a chart", sparkSVG(series(2, () => 10), 1), "");
  eq("no samples at all draw nothing", sparkSVG(null, 1), "");
  ok("a value past the ceiling stays inside the box",
     sparkSVG(series(4, () => 140), 1).match(/,(-?[\d.]+)/g)
       .every(m => parseFloat(m.slice(1)) >= 0));
  ok("a gap in one window does not break the other",
     sparkSVG([[1, null, 5], [2, null, 6], [3, null, 7]], 2).includes("polyline"));
}

console.log("13. the trend caption, and what it says when it cannot say much");
{
  freshStorage(); stubDom();
  const now = Math.floor(Date.now() / 1000);
  const a = loadHistory({ HIST:{
    busy:   { rate5:12.34, eta5:now + 1800, samples:series(8, i => i * 10) },
    idle:   { rate5:0.2, eta5:null, samples:series(8, () => 5) },
    rising: { rate5:9, eta5:null, samples:series(8, i => i) },
    thin:   { rate5:null, eta5:null, samples:series(2, () => 5) },
  }});
  const t = a.fns.trendHTML;
  ok("a profile with no history gets no caption at all", t("unknown", 5) === "");
  ok("nor does one with too little to measure or draw", t("thin", 5) === "");
  ok("the rate is signed", t("busy", 5).includes("+12.3%/h"));
  ok("a projected ceiling is marked for the ticker to update",
     t("busy", 5).includes(`data-eta="${now + 1800}"`));
  ok("and takes the severity of how soon it lands", t("busy", 5).includes("s-crit"));
  ok("a flat account is holding", t("idle", 5).includes("holding"));
  ok("a climbing one that resets in time says so", t("rising", 5).includes("clears first"));
  ok("no projection means no flag", !t("rising", 5).includes("data-eta"));
}

console.log("14. the recommendation chip");
{
  freshStorage(); stubDom();
  const a = loadHistory({ NEXT:{ pick:"spare", reason:"88% left on the 7d" },
                          ACTIVE:"work" });
  ok("only the recommended profile is chipped", a.fns.nextChip("work") === "");
  ok("the recommendation says to use it", a.fns.nextChip("spare").includes("use next"));
  ok("it carries the reason", a.fns.nextChip("spare").includes("88% left on the 7d"));
  a.set({ ACTIVE:"spare" });
  ok("when you are already on it, it says that instead",
     a.fns.nextChip("spare").includes("you're on it"));
  a.set({ NEXT:{ pick:"spare", reason:'<img src=x onerror="boom">' } });
  ok("the reason is escaped before it lands in an attribute",
     !a.fns.nextChip("spare").includes("<img"));
  a.set({ NEXT:null });
  ok("nothing is chipped before the ranking has loaded", a.fns.nextChip("spare") === "");
}

console.log("");
console.log(`${PASS} passed, ${FAIL} failed`);
process.exit(FAIL === 0 ? 0 : 1);
JS

WORK="$WORK" node "$WORK/run.js"
