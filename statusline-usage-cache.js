#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// statusline-usage-cache.js — keep claudius's usage cache warm, for free.
//
// Claude Code hands your status line this session's live rate limits on stdin
// (as JSON) on every render. This script mirrors those numbers into claudius's
// per-profile cache — ~/.claude-profiles/<name>/.usage — so the dashboard shows
// live usage for any account you have a session open for, with NO extra API call.
//
// It is a PASS-THROUGH FILTER: it reads the status line JSON on stdin, writes the
// cache as a side effect, and re-emits the exact same JSON on stdout. So you chain
// it in front of your existing status line command — it changes nothing you see.
//
// ── Enable it (settings.json → statusLine.command) ───────────────────────────
//   Keep your existing status line, just prepend this filter:
//     node ~/.claudius/statusline-usage-cache.js | <your existing statusline cmd>
//
//   Example (a status line that itself runs node):
//     node ~/.claudius/statusline-usage-cache.js | bash ~/.claude/statusline-command.sh
//
//   If you have no status line yet and only want the cache warming, you can run it
//   alone — it will just echo the JSON (harmless, but nothing useful is displayed).
//
// Keyed off each session's own config dir, so running accounts in parallel (the
// default ~/.claude plus any CLAUDE_CONFIG_DIR profiles) each refresh their own
// profile. Accounts with no live session still need a manual `claudius refresh`.
//
// Best-effort and defensive: any error is swallowed so it can never break or slow
// your status line. Node ships with Claude Code, so there is nothing to install.
// ─────────────────────────────────────────────────────────────────────────────

const fs = require("fs");
const os = require("os");
const path = require("path");

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  // Pass the JSON straight through first, so the downstream status line is never
  // delayed and a later failure here cannot affect what is displayed.
  process.stdout.write(raw);

  try {
    let j = {};
    try { j = JSON.parse(raw); } catch (e) { return; }

    const rl = j.rate_limits || {};
    if (!rl.five_hour && !rl.seven_day) return;

    const home = os.homedir();
    const root = path.join(home, ".claude-profiles");

    // Which config dir is this session using?
    let cfg = process.env.CLAUDE_CONFIG_DIR;
    if (!cfg && typeof j.transcript_path === "string" && j.transcript_path.includes("/projects/")) {
      cfg = j.transcript_path.split("/projects/")[0];
    }
    if (!cfg) return;

    // Resolve the target profile .usage path from that config dir.
    let target = null;
    // Normalise before comparing: the paths come from two different sources (the
    // env var / transcript_path vs path.join here), so a doubled or trailing
    // slash in either would make every comparison below fail and the cache would
    // silently never be written.
    const norm = path.normalize(cfg).replace(/[\/]+$/, "");
    if (norm === path.join(home, ".claude")) {
      // Default session → whichever profile is currently active.
      try {
        const active = fs.readFileSync(path.join(root, ".active_profile"), "utf8").trim();
        if (active) target = path.join(root, active, ".usage");
      } catch (e) { /* no active profile recorded */ }
    } else if (norm.startsWith(root + path.sep)) {
      // Running directly as a profile config dir.
      target = path.join(norm, ".usage");
    }
    if (!target) return;

    const nowSec = Math.floor(Date.now() / 1000);
    // Throttle: status lines render often — skip if the cache is < 15s old.
    try {
      const prev = fs.readFileSync(target, "utf8").trim().split(/\s+/);
      if (prev[2] && nowSec - parseInt(prev[2], 10) < 15) return;
    } catch (e) { /* no cache yet — write it */ }

    const pct = (w) => (w && w.used_percentage != null) ? String(Math.round(w.used_percentage)) : "-";
    const rst = (w) => (w && w.resets_at) ? String(Math.floor(w.resets_at)) : "-";
    const u5 = pct(rl.five_hour), u7 = pct(rl.seven_day);
    if (u5 === "-" && u7 === "-") return;

    // Cache format matches claudius fetch_usage: "u5 u7 uts r5 r7".
    fs.writeFileSync(
      target,
      u5 + " " + u7 + " " + nowSec + " " + rst(rl.five_hour) + " " + rst(rl.seven_day) + "\n",
      { mode: 0o600 }
    );

    // Append the same reading to <target>.log — "ts u5 u7 r5 r7", timestamp
    // first — which is what lets claudius show a burn rate rather than a single
    // number. Sampled every 120s (the cache itself is every 15s) and never
    // rewritten here: pruning belongs to the reader, so appenders stay this
    // cheap and can't corrupt the file. Reads only the last 256 bytes to find
    // the previous sample's time.
    const logPath = target + ".log";
    let lastTs = 0;
    try {
      const st = fs.statSync(logPath);
      const len = Math.min(st.size, 256);
      const buf = Buffer.alloc(len);
      const fd = fs.openSync(logPath, "r");
      try { fs.readSync(fd, buf, 0, len, st.size - len); } finally { fs.closeSync(fd); }
      const lines = buf.toString("utf8").trim().split("\n");
      lastTs = parseInt(lines[lines.length - 1].split(/\s+/)[0], 10) || 0;
    } catch (e) { /* no history yet — start one */ }
    if (nowSec - lastTs >= 120) {
      fs.appendFileSync(
        logPath,
        nowSec + " " + u5 + " " + u7 + " " + rst(rl.five_hour) + " " + rst(rl.seven_day) + "\n",
        { mode: 0o600 }
      );
    }
  } catch (e) {
    // Never let cache-writing affect the status line.
  }
});
