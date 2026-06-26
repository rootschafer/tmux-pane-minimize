# 00 — Hero demo (README top)

**Goal:** in ~5s show the one-key minimize/restore that defines the plugin. Loop it.
**Output:** `docs/media/hero.gif` (looping).

## SETUP (before recording — not on camera)
- Window ~120×35, large font, Recommended config loaded.
- Three panes: a wide left pane (run `htop` or `ls`-into a file viewer for visual texture),
  and a right column split into two (an editor up top, a shell below). Active pane = left.
- Make sure the left pane has obvious content (e.g. a file open) so its collapse is visible.

## SHOT LIST
- `[t=0.0]` **SCREEN:** "Three panes." — rest 1s on the full layout.
  **HIGHLIGHT:** none.
- `[t=1.0]` **DO:** focus the top-right pane (`prefix + ↑` or click it).
  **SCREEN:** "Minimize this one →"  **HIGHLIGHT:** circle the top-right pane's border.
- `[t=2.0]` **DO:** press the toggle key (`prefix + Ctrl-t`).
  **SCREEN:** "prefix + Ctrl-t"  (show the keys, top-center).
  **HIGHLIGHT:** as it collapses, arrow the pill indicator that appears on its border.
- `[t=2.8]` rest 1s. **SCREEN:** "It collapses; the rest reflow." **HIGHLIGHT:** box the
  pane that expanded to take the freed space.
- `[t=4.0]` **DO:** press the toggle key again (`prefix + Ctrl-t`) on the same pane.
  **SCREEN:** "Press again → restored." 
- `[t=4.8]` rest 1s on the original layout, then loop.

## Notes
- The point is "minimized panes stay pinned while others reflow" — make sure the viewer sees
  BOTH the collapse and the neighbour expanding. If it's not legible, use only a 2-pane split
  so the reflow is bigger.
