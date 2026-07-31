#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# claudius team status line.  Enable with:  claudius statusline
#
# Shows [model] · context · 5h/7d rate limits with reset countdowns, AND warms
# claudius's per-profile usage cache for free (so the dashboard stays current with
# no extra API calls). Self-contained — no piping needed.
#
# Prefer your OWN status line? Skip this and just keep the cache-warming bonus by
# chaining the filter in front of yours:
#   node ~/.claudius/statusline-usage-cache.js | <your existing statusline command>
# ─────────────────────────────────────────────────────────────────────────────
# Parses the JSON on stdin with `node` (always present — Claude Code runs on it)
# rather than `jq` (not installed here). Shows Claude session stats and reset times.
# Every field is optional and degrades silently.
exec node -e '
let raw = "";
process.stdin.on("data", d => (raw += d));
process.stdin.on("end", () => {
  let j = {};
  try { j = JSON.parse(raw); } catch (e) {}

  // ANSI helpers — all dim by default; colour escapes inside carry their own reset back to dim.
  const DIM   = "\x1b[02m";
  const RESET = "\x1b[00m";

  // Semantic colour based on a 0-100 value: green → yellow → red.
  // Returns an ANSI SGR sequence string (no dim — caller wraps as needed).
  const semColor = v => {
    if (v === null || v === undefined) return "";
    if (v < 50)  return "\x1b[32m";   // green
    if (v < 75)  return "\x1b[33m";   // yellow
    if (v < 90)  return "\x1b[31m";   // red (soft)
    return "\x1b[91m";                 // bright red
  };

  // Coloured percentage string, returned as a plain (non-dim) coloured token.
  const colorPct = v => {
    if (v === null || v === undefined) return null;
    const rounded = Math.round(v);
    return `${semColor(v)}${rounded}%${RESET}`;
  };

  // Small 5-char progress bar: [████░]
  // Uses block characters; fill colour matches semantic colour.
  const progressBar = v => {
    if (v === null || v === undefined) return "";
    const filled = Math.round((v / 100) * 5);
    const empty  = 5 - filled;
    const col    = semColor(v);
    const bar    = "█".repeat(filled) + "░".repeat(empty);
    return `${DIM}[${RESET}${col}${bar}${RESET}${DIM}]${RESET}`;
  };

  // Format a reset epoch into a human-readable countdown.
  // >24 h  → "Xd Yh"   (days + remainder hours, rounded up to nearest day boundary)
  // 1–24 h → "Xh Ym"
  // <1 h   → "Xm"
  const fmtReset = epoch => {
    if (!epoch) return null;
    const diffMs = epoch * 1000 - Date.now();
    if (diffMs <= 0) return null;
    const totalMin = Math.ceil(diffMs / 60000);
    if (totalMin < 60) return `${totalMin}m`;
    const totalH = diffMs / 3600000;
    if (totalH < 24) {
      const h = Math.floor(totalH);
      const m = Math.round((totalH - h) * 60);
      return m > 0 ? `${h}h${m}m` : `${h}h`;
    }
    // >= 24 h: round up to full days, show remainder hours
    const days = Math.floor(totalH / 24);
    const remH = Math.round(totalH % 24);
    return remH > 0 ? `${days}d ${remH}h` : `${days}d`;
  };

  // ── Build sections ────────────────────────────────────────────────────────

  const parts = [];

  // Model in square brackets
  const model = j.model && j.model.display_name;
  if (model) parts.push(`${DIM}[${RESET}${model}${DIM}]${RESET}`);

  // Context window with progress bar + coloured percentage
  const ctxPct = j.context_window && j.context_window.used_percentage;
  if (ctxPct !== null && ctxPct !== undefined) {
    const bar = progressBar(ctxPct);
    const pct = colorPct(ctxPct);
    parts.push(`${DIM}ctx${RESET} ${bar}${DIM} ${RESET}${pct}`);
  }

  // Rate limits: progress bar + coloured percentage + reset countdown
  const rl = j.rate_limits || {};

  if (rl.five_hour) {
    const v = rl.five_hour.used_percentage;
    const bar = progressBar(v);
    const pct = colorPct(v);
    const reset = fmtReset(rl.five_hour.resets_at);
    let tok = `${DIM}5h${RESET} ${bar}${DIM} ${RESET}${pct}`;
    if (reset) tok += `${DIM}@${reset}${RESET}`;
    parts.push(tok);
  }

  if (rl.seven_day) {
    const v = rl.seven_day.used_percentage;
    const bar = progressBar(v);
    const pct = colorPct(v);
    const reset = fmtReset(rl.seven_day.resets_at);
    let tok = `${DIM}7d${RESET} ${bar}${DIM} ${RESET}${pct}`;
    if (reset) tok += `${DIM}@${reset}${RESET}`;
    parts.push(tok);
  }

  const SEP = `  ${DIM}│${RESET}  `;
  const out = parts.length ? parts.join(SEP) : "";
  process.stdout.write(out);

  // ── Keep the claudius usage cache warm (free) ──────────────────────────────
  // claudius (the account switcher) reads ~/.claude-profiles/<name>/.usage. Claude
  // Code already hands us this session live rate limits, so mirror them into that
  // cache for the profile this session runs as — no extra API call. Keyed off our
  // own config dir, so parallel sessions (default + CLAUDE_CONFIG_DIR profiles)
  // each keep their own profile fresh. Best-effort; runs AFTER output and can never
  // block or break the status line.
  try {
    const fs = require("fs"), os = require("os"), path = require("path");
    const home = os.homedir();
    const root = path.join(home, ".claude-profiles");

    // Which config dir is this session using?
    let cfg = process.env.CLAUDE_CONFIG_DIR;
    if (!cfg && typeof j.transcript_path === "string" && j.transcript_path.includes("/projects/")) {
      cfg = j.transcript_path.split("/projects/")[0];
    }

    // Resolve the target profile .usage path from that config dir.
    let target = null;
    if (cfg) {
      const norm = cfg.replace(/[\/]+$/, "");
      if (norm === path.join(home, ".claude")) {
        // Default session → whichever profile is currently active.
        try {
          const active = fs.readFileSync(path.join(root, ".active_profile"), "utf8").trim();
          if (active) target = path.join(root, active, ".usage");
        } catch (e) {}
      } else if (norm.startsWith(root + path.sep)) {
        // Running directly as a profile config dir.
        target = path.join(norm, ".usage");
      }
    }

    if (target && (rl.five_hour || rl.seven_day)) {
      const nowSec = Math.floor(Date.now() / 1000);
      // Throttle: status lines render often — skip if the cache is < 15s old.
      let fresh = false;
      try {
        const prev = fs.readFileSync(target, "utf8").trim().split(/\s+/);
        if (prev[2] && nowSec - parseInt(prev[2], 10) < 15) fresh = true;
      } catch (e) {}
      if (!fresh) {
        const pct = w => (w && w.used_percentage != null) ? String(Math.round(w.used_percentage)) : "-";
        const rst = w => (w && w.resets_at) ? String(Math.floor(w.resets_at)) : "-";
        const u5 = pct(rl.five_hour), u7 = pct(rl.seven_day);
        // Cache format matches claudius fetch_usage: "u5 u7 uts r5 r7".
        if (u5 !== "-" || u7 !== "-") {
          fs.writeFileSync(target,
            u5 + " " + u7 + " " + nowSec + " " + rst(rl.five_hour) + " " + rst(rl.seven_day) + "\n",
            { mode: 0o600 });
          // Append the same reading to <target>.log — "ts u5 u7 r5 r7", timestamp
          // first — which is what lets claudius show a burn rate instead of a
          // lone number. Sampled every 120s (the cache is every 15s) and never
          // rewritten here: pruning belongs to the reader, so an appender stays
          // this cheap and cannot corrupt the file. Only the last 256 bytes are
          // read, to find the previous sample time.
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
          } catch (e) {}
          if (nowSec - lastTs >= 120) {
            fs.appendFileSync(logPath,
              nowSec + " " + u5 + " " + u7 + " " + rst(rl.five_hour) + " " + rst(rl.seven_day) + "\n",
              { mode: 0o600 });
          }
        }
      }
    }
  } catch (e) { /* never let cache-writing affect the status line */ }
});
'
