# 03 — Per-group minimized width (side-border drag)

**Goal:** show a fully-minimized column narrowing, then dragging its side border to a custom
width that *persists* (across a window resize and a re-minimize). ~12s.
**Output:** `docs/media/per-group-width.{gif,mp4}`.

## SETUP (before recording — not on camera)
- Window ~160×40, Recommended config, `mouse on`.
- TWO columns: a wide left pane (active, with content) and a RIGHT column that is a vertical
  stack of 2–3 panes. Keep focus on the LEFT pane throughout (the group must have no active
  pane for the width drag to register).

## SHOT LIST
- `[t=0.0]` rest 1s. **SCREEN:** "A column of stacked panes." **HIGHLIGHT:** box the right column.
- `[t=1.0]` **DO:** minimize every pane in the right column (`prefix + Ctrl-t` on each), focus
  back to the left pane.
  **SCREEN:** "Minimize them all → the column narrows."
  **HIGHLIGHT:** arrow the right column as it collapses to `@minimize-width` (narrow).
- `[t=3.5]` rest 1s on the narrow column. **SCREEN:** "Default width (@minimize-width)."
- `[t=4.5]` **DO:** mouse-drag the SIDE border between the left pane and the narrow column,
  widening the column.
  **SCREEN:** "Drag the side border →"  **HIGHLIGHT:** circle the cursor on the border; show
  the column widening as you drag.
- `[t=6.5]` release. rest 1s. **SCREEN:** "…now it's your custom width."
- `[t=7.5]` **DO:** resize the whole terminal window (shrink then restore), OR `prefix + Ctrl-t`
  one pane out and back in.
  **SCREEN:** "It persists — resize, re-minimize…"
  **HIGHLIGHT:** box the column staying at the custom width through the resize.
- `[t=10.5]` rest 1.5s on the persisted state. **SCREEN:** "Width sticks for the group."
  Optionally: **DO** `prefix + W` (`@minimize-minw-reset-key`) and **SCREEN:** "prefix + W
  resets it" as it snaps back to the default narrow width.
- `[t=12.0]` end; hold 1s.

## Notes
- Two conditions to make on camera so it doesn't look like a fluke: (1) the column is FULLY
  minimized (every pane), (2) focus is OUTSIDE the column. Call these out if there's room.
- The persistence beat is the payoff — make the window-resize obviously NOT reset the width.
