#!/usr/bin/env bash
# Interaction tests for the dashboard: a real Chromium loads the real page from a
# real sidecar, and the keyboard, filters and controls are driven through the
# DevTools protocol. This is the layer tests/dashboard.sh cannot reach — it caught
# a wrong `cd` target and an internal directory encoding leaking on screen, both
# invisible to unit tests on pure functions.
#
# Read-only: only GET /api/profiles and GET /api/sessions are ever exercised, and
# the driver never touches `Use` or anything else that mutates. The real
# ~/.claude-profiles is served but never written.
#
# Neither node nor Chromium is a claudius dependency. Both ship with Claude Code
# (Chromium via Playwright's cache), and when either is missing this suite skips.
# Checks that depend on what happens to be in the pool skip individually rather
# than failing on a pool that does not have that shape.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${CLAUDIUS_TEST_PORT:-8797}"
CDP_PORT="${CLAUDIUS_TEST_CDP_PORT:-9223}"

command -v node >/dev/null 2>&1 || {
  printf 'skipped: node not found\n'; exit 0; }
CHROME="$(ls -d "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux64/chrome 2>/dev/null | tail -1)"
[[ -n "$CHROME" && -x "$CHROME" ]] || {
  printf 'skipped: no Chromium in ~/.cache/ms-playwright\n'; exit 0; }
ruby -e 'require "webrick"' >/dev/null 2>&1 || {
  printf 'skipped: webrick not available\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claudius-live.XXXXXX")"
SIDECAR_PID=""; CHROME_PID=""
cleanup() {
  [[ -n "$CHROME_PID" ]] && kill "$CHROME_PID" 2>/dev/null
  [[ -n "$SIDECAR_PID" ]] && kill "$SIDECAR_PID" 2>/dev/null
  # Wait for them to actually go before removing the directory they are writing
  # into — Chromium's profile dir repopulates itself under an rm otherwise.
  [[ -n "$CHROME_PID" ]] && wait "$CHROME_PID" 2>/dev/null
  [[ -n "$SIDECAR_PID" ]] && wait "$SIDECAR_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# Refuse to reuse a port something else already holds — that something is probably
# the user's own dashboard, and driving it would be both wrong and confusing.
if ruby -rsocket -e 'begin; TCPSocket.new("127.0.0.1", ARGV[0].to_i).close; exit 0; rescue; exit 1; end' "$PORT"; then
  printf 'skipped: port %s is already in use (set CLAUDIUS_TEST_PORT)\n' "$PORT"; exit 0
fi

ruby "$ROOT/claude-dashboard.rb" --port "$PORT" --root "$HOME/.claude-profiles" \
  --script "$ROOT/claudius" > "$WORK/sidecar.log" 2>&1 &
SIDECAR_PID=$!
"$CHROME" --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
  --remote-debugging-port="$CDP_PORT" --window-size=1320,1400 \
  --user-data-dir="$WORK/chrome" about:blank > "$WORK/chrome.log" 2>&1 &
CHROME_PID=$!

# Wait for both, rather than sleeping and hoping.
for _ in $(seq 1 40); do
  ruby -rsocket -e 'begin; TCPSocket.new("127.0.0.1", ARGV[0].to_i).close; exit 0; rescue; exit 1; end' "$PORT" \
    && break
  sleep 0.25
done

cat > "$WORK/drive.js" <<'JS'
const PORT = process.env.PORT, CDP = process.env.CDP_PORT;
const sleep = ms => new Promise(r => setTimeout(r, ms));
let PASS = 0, FAIL = 0, SKIP = 0;
const ok   = (n, c) => { c ? PASS++ : FAIL++; console.log(`  ${c ? "\x1b[32m✓\x1b[0m" : "\x1b[31m✗\x1b[0m"} ${n}`); };
const skip = (n, why) => { SKIP++; console.log(`  \x1b[33m—\x1b[0m ${n}  (${why})`); };

(async () => {
  // What the pool actually contains, so nothing below hardcodes one machine's data.
  const all = await (await fetch(`http://127.0.0.1:${PORT}/api/sessions?limit=0`)).json();
  const capped = await (await fetch(`http://127.0.0.1:${PORT}/api/sessions`)).json();
  const TOTAL = all.length, SHOWN = capped.length;
  if (!TOTAL){ console.log("  \x1b[33m—\x1b[0m whole suite  (no sessions in the pool)"); process.exit(0); }

  let url;
  for (let i = 0; i < 40 && !url; i++){
    try {
      const list = await (await fetch(`http://127.0.0.1:${CDP}/json/list`)).json();
      url = list.find(t => t.type === "page" && t.webSocketDebuggerUrl)?.webSocketDebuggerUrl;
    } catch (e) {}
    if (!url) await sleep(250);
  }
  if (!url) throw new Error("no debuggable page");

  const ws = new WebSocket(url);
  await new Promise(r => ws.addEventListener("open", r));
  let id = 0; const pending = new Map();
  ws.addEventListener("message", ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)){ pending.get(m.id)(m); pending.delete(m.id); }
  });
  const send = (method, params) => new Promise(res => {
    const n = ++id; pending.set(n, res); ws.send(JSON.stringify({ id:n, method, params }));
  });
  const js = async (expr) => {
    const r = await send("Runtime.evaluate",
      { expression:`(() => { ${expr} })()`, awaitPromise:true, returnByValue:true });
    if (r.result?.exceptionDetails)
      throw new Error(r.result.exceptionDetails.exception?.description || "eval failed");
    return r.result?.result?.value;
  };
  const key = (k, code, vk) =>
    send("Input.dispatchKeyEvent", { type:"keyDown", key:k, code, windowsVirtualKeyCode:vk,
                                     nativeVirtualKeyCode:vk })
      .then(() => send("Input.dispatchKeyEvent", { type:"keyUp", key:k, code,
                                                   windowsVirtualKeyCode:vk }));
  const type = async (sel, value) => {
    await js(`const i = document.querySelector("${sel}"); i.focus(); i.value = ${JSON.stringify(value)};
              i.dispatchEvent(new Event("input", { bubbles:true })); return 1;`);
    await sleep(300);
  };

  await send("Page.navigate", { url:`http://127.0.0.1:${PORT}/` });
  // the page fetches profiles and sessions on boot; wait for rows, don't guess
  for (let i = 0; i < 40; i++){
    if (await js(`return document.querySelectorAll(".srow").length > 0`)) break;
    await sleep(250);
  }

  console.log("1. rows");
  ok(`the newest ${SHOWN} rows load`,
     await js(`return document.querySelectorAll(".srow").length === ${SHOWN}`));
  ok("no row is sliced by the panel height", await js(`
    const b = document.querySelector("#sessBody");
    const h = document.querySelector(".srow").getBoundingClientRect().height;
    return h > 0 && Math.abs(b.clientHeight % h) < 0.5;`));
  ok("the age cell carries a real timestamp", await js(`
    const t = document.querySelector(".srow .age").title;
    return /\\d/.test(t.replace("last active", ""));`));
  ok("no row shows a raw encoded directory key", await js(`
    return ![...document.querySelectorAll(".srow .where")].some(w => /^-/.test(w.title));`));

  const heavy = capped.some(s => (s.size || 0) >= 1048576);
  const light = capped.some(s => (s.size || 0) < 1048576);
  if (heavy && light)
    ok("weight is shown on heavy rows and hidden on light ones", await js(`
      const w = [...document.querySelectorAll(".srow .wt")].map(e => e.textContent.trim());
      return w.some(x => /MB$/.test(x)) && w.some(x => x === "");`));
  else skip("weight only on heavy rows", "pool has no mix of sizes");

  if (capped.some(s => s.short === "~"))
    ok("a session in $HOME reads as ~, not as a username", await js(`
      return [...document.querySelectorAll(".srow .where")].some(w => w.textContent.trim().startsWith("~"));`));
  else skip("a session in $HOME reads as ~", "no session in $HOME");

  console.log("2. search");
  const term = (capped.find(s => s.label && /^[a-z ]{6,}$/i.test(s.label))?.label || "").split(" ")[0];
  if (term){
    await type("#sessQ", term);
    ok("the list narrows",
       await js(`return document.querySelectorAll(".srow").length < ${SHOWN}`));
    ok("the count says N of M",
       await js(`return /of\\s*${SHOWN}/.test(document.querySelector("#sessCnt").textContent)`));
    ok("matches are marked", await js(`return document.querySelectorAll(".srow mark").length > 0`));
    ok("the mark is bright enough to read as a highlight", await js(`
      const bg = getComputedStyle(document.querySelector(".srow mark")).backgroundColor;
      let [r,g,b] = bg.match(/[\\d.]+/g).map(Number);
      if (r <= 1 && g <= 1 && b <= 1){ r *= 255; g *= 255; b *= 255; }
      return (0.299*r + 0.587*g + 0.114*b) > 45;`));
  } else skip("search narrows the list", "no plain-text label to search for");

  console.log("3. keyboard");
  await js(`document.querySelector("#sessQ").focus(); return 1;`);
  await key("ArrowDown", "ArrowDown", 40); await sleep(200);
  ok("ArrowDown picks the first row", await js(`return !!document.querySelector(".srow.cur")`));
  await key("ArrowDown", "ArrowDown", 40); await sleep(200);
  ok("ArrowDown moves on", await js(`
    return [...document.querySelectorAll(".srow")].findIndex(r => r.classList.contains("cur")) === 1;`));
  await key("ArrowUp", "ArrowUp", 38); await sleep(200);
  ok("ArrowUp moves back", await js(`
    return [...document.querySelectorAll(".srow")].findIndex(r => r.classList.contains("cur")) === 0;`));
  await key("Enter", "Enter", 13); await sleep(400);
  ok("Enter copies a resume command", await js(`
    const t = document.querySelector("#toast").textContent || "";
    return t.includes("--resume");`));
  ok("the copy is recorded in the log", await js(`
    return [...document.querySelectorAll(".logrow")].some(r => /copied/.test(r.textContent));`));

  await js(`document.querySelector("#sessQ").focus(); return 1;`);
  await key("Escape", "Escape", 27); await sleep(300);
  ok("Escape clears the search", await js(`
    return document.querySelector("#sessQ").value === "" &&
           document.querySelectorAll(".srow").length === ${SHOWN};`));
  await js(`document.querySelector("#sessQ").blur(); document.body.focus(); return 1;`);
  await key("/", "Slash", 191); await sleep(200);
  ok("/ jumps to the search box", await js(`return document.activeElement.id === "sessQ"`));

  console.log("4. the whole pool");
  if (TOTAL > SHOWN){
    ok("the offer to show everything is there",
       await js(`return !!document.querySelector("#sessAll")`));
    await js(`document.querySelector("#sessAll").click(); return 1;`);
    for (let i = 0; i < 60; i++){
      if (await js(`return document.querySelectorAll(".srow").length === ${TOTAL}`)) break;
      await sleep(500);
    }
    ok(`all ${TOTAL} rows load`,
       await js(`return document.querySelectorAll(".srow").length === ${TOTAL}`));
    ok("and the offer withdraws", await js(`return !document.querySelector("#sessAll")`));
    ok("the header count agrees",
       await js(`return /${TOTAL}/.test(document.querySelector("#sessCnt").textContent)`));
    ok("still no sliced row", await js(`
      const b = document.querySelector("#sessBody");
      const h = document.querySelector(".srow").getBoundingClientRect().height;
      return Math.abs(b.clientHeight % h) < 0.5;`));
  } else skip("show the whole pool", `the pool is only ${TOTAL} rows`);

  ok("the scope control lists every project exactly once", await js(`
    const n = document.querySelector("#sessScope").options.length;
    const paths = new Set([...document.querySelectorAll(".srow")].map(r => r.querySelector(".where").title));
    return n === paths.size + 1;`));

  if (all.some(s => s.exists === false))
    ok("a project whose directory is gone is struck through and tagged", await js(`
      const g = document.querySelector(".srow.gone");
      return !!g && !!g.querySelector(".where .tag") &&
        getComputedStyle(g.querySelector(".where")).textDecorationLine.includes("line-through");`));
  else skip("a missing project directory is marked", "every project still exists");

  console.log("5. usage history on the surface");
  // Whether this machine has any history depends on how long the status line has
  // been appending, so both outcomes are asserted — and the one that matters most
  // on a fresh install is that nothing at all is drawn.
  const hist = await (await fetch(`http://127.0.0.1:${PORT}/api/history`)).json();
  const withRate = hist.filter(h => h.rate5 != null || h.rate7 != null);
  if (withRate.length){
    ok("a measurable account shows its burn rate", await js(`
      return [...document.querySelectorAll(".surface .trend .rate")]
        .some(e => /%\\/h$/.test(e.textContent.trim()));`));
    ok("every projection is tagged for the ticker to update", await js(`
      const hits = [...document.querySelectorAll(".trend .hit")];
      return hits.every(h => !/100%/.test(h.textContent) || h.hasAttribute("data-eta"));`));
    if (withRate.some(h => (h.samples || []).filter(s => s[1] != null).length >= 3))
      ok("and a sparkline that stays inside its box", await js(`
        const s = document.querySelector(".trend .spark");
        if (!s) return false;
        const b = s.getBoundingClientRect(), p = s.querySelector("polyline");
        const ys = p.getAttribute("points").split(" ").map(t => +t.split(",")[1]);
        return b.width > 0 && b.height > 0 &&
               Math.min(...ys) >= 0 && Math.max(...ys) <= b.height;`));
    else skip("the sparkline stays inside its box", "no window has 3+ samples yet");
  } else {
    // The row is always there — it is what keeps two cards agreeing on where
    // everything below it sits — so what is asserted is that it says nothing,
    // not that it is absent.
    ok("with no history, no half-answer is drawn", await js(`
      return [...document.querySelectorAll(".trend")]
        .every(t => t.textContent.trim() === "" && !t.querySelector("svg"));`));
    skip("the burn rate reads correctly", "no profile has enough history yet");
    skip("the sparkline stays inside its box", "no profile has enough history yet");
  }

  // ── tooltips ───────────────────────────────────────────────────────────────
  // Hovering is read-only, and this is the layer where the tooltip actually
  // lives: the whole mechanism is DOM lifecycle — a title taken off its element
  // and put back — which a unit test on pure functions cannot see at all.
  console.log("6. tooltips");
  const hover = (sel, ev) => `
    const el = document.querySelector(${JSON.stringify(sel)});
    if (!el) return "no-el";
    el.dispatchEvent(new PointerEvent(${JSON.stringify(ev)},
      { bubbles:true, relatedTarget:${ev === "pointerout" ? "document.body" : "null"} }));`;
  const settle = ms => new Promise(r => setTimeout(r, ms));

  if (await js(`return !!document.querySelector(".surface [data-reset]");`)){
    await js(hover(".surface [data-reset]", "pointerover"));
    await settle(300);
    ok("a reset countdown says which day it means", await js(`
      const tip = document.querySelector(".tip");
      if (!tip || !tip.classList.contains("on")) return false;
      /* the absolute time, and the relative one it is standing in for */
      return /\\d/.test(tip.textContent) && !!tip.querySelector(".when");`));
    ok("and the tooltip stays inside the viewport", await js(`
      const b = document.querySelector(".tip").getBoundingClientRect();
      return b.left >= 0 && b.top >= 0 && b.right <= innerWidth && b.bottom <= innerHeight;`));
    await js(hover(".surface [data-reset]", "pointerout"));
    await settle(120);
    ok("and it goes when the pointer does", await js(`
      return !document.querySelector(".tip").classList.contains("on");`));
  } else {
    skip("a reset countdown says which day it means", "no cached reset time in the pool");
    skip("the tooltip stays inside the viewport", "no cached reset time in the pool");
    skip("the tooltip goes when the pointer does", "no cached reset time in the pool");
  }

  if (await js(`return !!document.querySelector("button[data-copy]");`)){
    const before = await js(`
      return document.querySelector("button[data-copy]").getAttribute("title");`);
    await js(hover("button[data-copy]", "pointerover"));
    await settle(300);
    ok("a title is read out in the page's own tooltip", await js(`
      const tip = document.querySelector(".tip");
      return tip.classList.contains("on") &&
             tip.textContent.trim() === ${JSON.stringify(String(before || "").trim())};`));
    ok("and the browser's own is suppressed while it shows", await js(`
      return document.querySelector("button[data-copy]").getAttribute("title") === null;`));
    await js(hover("button[data-copy]", "pointerout"));
    await settle(120);
    ok("the title comes back on the way out", await js(`
      return document.querySelector("button[data-copy]").getAttribute("title")
             === ${JSON.stringify(before)};`));
  } else {
    skip("a title is read out in the page's own tooltip", "no card with a copy button");
    skip("the browser's own tooltip is suppressed", "no card with a copy button");
    skip("the title comes back on the way out", "no card with a copy button");
  }

  const pick = await (await fetch(`http://127.0.0.1:${PORT}/api/next`)).json();
  if (pick && pick.pick)
    ok("the recommended account is the only one chipped", await js(`
      const chips = [...document.querySelectorAll(".nextchip")];
      if (chips.length !== 1) return false;
      const card = chips[0].closest("[data-name]");
      return card && card.dataset.name === ${JSON.stringify(pick.pick)};`));
  else skip("the recommendation is chipped", "no account is usable right now");

  console.log("");
  console.log(`${PASS} passed, ${FAIL} failed${SKIP ? `, ${SKIP} skipped` : ""}`);
  ws.close();
  process.exit(FAIL === 0 ? 0 : 1);
})().catch(e => { console.error(`\nFAILED: ${e.message}`); process.exit(1); });
JS

PORT="$PORT" CDP_PORT="$CDP_PORT" node "$WORK/drive.js"
rc=$?
exit $rc
