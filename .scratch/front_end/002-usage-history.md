# 002 — Usage history: what it does not do yet

**Status:** open · **Opened:** 2026-08-01 · **Area:** `claudius`, `dashboard.html`

`.usage.log`, `claudius history` and `claudius next` landed together. What they
do is documented in the README and above the functions themselves; this note is
only for the edges that were left, so nobody re-derives the reasoning.

## Accepted, with a reason

**A rate needs two samples ten minutes apart** (thirty for the 7d), so a fresh
install shows no trend for its first few minutes and no 7d trend for its first
half hour. Deliberate: a rate computed from two samples ninety seconds apart is
noise wearing a decimal point, and the page would rather show nothing. The floor
lives in `rate_of`'s `min_span`.

**Sampling is time-based, not event-based.** One sample per 120s regardless of
what happened in between, so a burst that starts and finishes inside two minutes
is invisible to the rate. Event-based sampling would mean the appenders reading
the previous value to decide, which is more work in three languages (the Ruby in
`fetch_usage` and the node in both status-line writers) for a case the 5h window
does not care about.

**The projection is linear.** It extrapolates the recent slope and nothing else —
no weighting, no curve. It is a warning, not a forecast, and a fancier model
would be harder to explain than the thing it predicts.

**`next` does not consider what you are about to do.** A 40-point account is
ranked above a 30-point one even if the job needs five points. Fine: the
recommendation is "most room", and the ranked list with reasons is right there
for anyone who wants to overrule it.

## Genuinely missing

**The TUI shows neither.** No burn rate, no recommendation marker, no `→` on the
account `next` would pick. The data is one `usage_history_json` call away and the
menu already shells out for usage, so this is not blocked on anything — it was
left out because the TUI has no test suite and every change to it has to be
driven by hand. Worth doing; do it as its own change.

**A limit reached while you are away is still a surprise.** History makes the
approach visible on the page, but nothing announces it: no notification when a
window crosses a threshold, and no page-level "everything is exhausted, the first
to clear is X at HH:MM" state — each card still says that individually and you
compare four of them. `next --json` already computes `blocked_until` and
`first_to_clear` for exactly that panel, so the data side is done.

**Nothing reads `history` back into `run`.** `claudius run "$(claudius next)"`
is a documented composition, not a flag. A `run --next` would be a small
addition; it was left out to keep `run`'s argument handling — where everything
unrecognised is passed through to `claude` — from growing a second claudius-owned
flag without a stronger reason than convenience.

## Not a defect

**`history` writes during a read.** Pruning happens in the reader, so a
`--json` read can rewrite `.usage.log`. That is the design: the appenders stay
dumb (one line, never a rewrite) so they cannot corrupt the file, and the shape
of it is decided in exactly one place. The rewrite is a temp file plus a rename,
and only fires past 1500 lines.
