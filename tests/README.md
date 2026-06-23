# tests/ — tmux-pane-minimize harness

Deterministic test suite for the minimize engine. Everything runs under `/bin/bash`
to enforce the macOS **bash 3.2** compatibility constraint.

```sh
tests/run.sh           # bash -n + offline property suite + live suite
QUICK=1 tests/run.sh   # offline: skip the WPANE/WVAL inner sweep (fast iteration)
VERBOSE=1 tests/run.sh # print every passing assertion too
```

## Files

| file | what |
|------|------|
| `assert_layout.sh` | **Invariant checker.** Independent re-implementation of the layout parser. Asserts every box ≥1 (fails loudly on any 0), `Σ child + borders == parent` for each split, contiguity, and a valid checksum. Run standalone: `assert_layout.sh '<cs,geom>'`. |
| `gen_layouts.sh` | **Layout generator.** Emits all trees of 1–4 leaves (h/v 2–4 splits + one level of nesting, incl. the column-beside-stack bug shape) at sizes 24×8 / 80×24 / 222×61. |
| `transform_props.sh` | **Offline property suite** (≈11k cases). For every generated layout × every MINSET subset × every WPANE × WVAL extreme `{0,1,3,9,1000}` × per-pane `MINH` extremes, plus a `BORDER_POS` top/bottom edge-bonus pass, runs the pure `transform` and checks invariants. `transform` is referentially transparent, so this is fully deterministic. |
| `live_sequences.sh` | **Live suite** on an isolated `tmux -L … -f /dev/null` server with a socket-patched engine. Parts: 1 scripted regressions, 1b stale-saved-dimension, 2 deterministic fuzz, 3 race-exposer (busy-marker overlap detector), `minh` per-pane height, dashboard, peek (peekin/peekout + resize-while-peeked), resize-window repin, resurrect round-trip, and an **end-to-end resurrect** test that drives the real `save.sh` (set `RESURRECT_PATH` to point at a checkout; skips if not found). Skips cleanly if tmux is absent. |
| `lib.sh` | shared pass/fail counters. |
| `run.sh` | top-level runner (CI entry point). |

## What the suite caught / guards

- **All-columns-minimized width loss** — when every column in a row is fully
  minimized there was no flexible neighbour, and the fallback dropped ~`Σ MIN_W`
  columns → a malformed layout tmux *silently* applies. Fixed in `recompute` (h).
- **Stale / too-large saved dimension and tiny windows** — restoring a pane to a
  saved height/width from a *larger* window (after the terminal shrank), or
  minimizing in a window too small for `MIN_H`, produced sum-mismatched layouts.
  Fixed by the `reconcile` pass (children always tile their parent, each ≥1,
  degrading by shaving the tallest/flex first).
- **Focus-hook race** — concurrent `run-shell -b` peekin/peekout both passed the old
  global `@minimize_guard` check-then-set (measured 47 overlapping applies). Now
  serialized by a per-window `mkdir` lock; handlers re-check live state under the lock.

The race-exposer (Part 3) instruments `apply()` and fails if applies aren't
serialized (a lock-neutered engine measures ~50 concurrent; fixed measures ≤3).
