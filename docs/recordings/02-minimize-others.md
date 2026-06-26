# 02 — Minimize others (focus toggle)

**Goal:** show one key collapsing everything but the active pane, then restoring exactly —
and that a pane you'd already minimized survives the round trip. ~10s.
**Output:** `docs/media/minimize-others.{gif,mp4}`.

## SETUP (before recording — not on camera)
- Window ~140×40, Recommended config (so `@minimize-others-key` is `M`).
- FOUR panes in an interesting layout: e.g. left column (two stacked), a big middle pane
  (active), a right pane. Give each visible content.
- BEFORE recording, minimize ONE of the left panes yourself (`prefix + Ctrl-t` on it) so we
  can show it surviving. Leave the middle pane active.

## SHOT LIST
- `[t=0.0]` rest 1s. **SCREEN:** "4 panes — one already minimized."
  **HIGHLIGHT:** circle the pane you pre-minimized (note its pill).
- `[t=1.0]` **DO:** press `prefix + M`.
  **SCREEN:** "prefix + M → focus the active pane" (top-center, show the keys).
  **HIGHLIGHT:** arrow the active (middle) pane as everything else collapses to strips.
- `[t=2.5]` rest 1.5s on the focused view. **SCREEN:** "Everything else minimizes."
- `[t=4.0]` **DO:** press `prefix + M` again.
  **SCREEN:** "Press again → exact layout back."
  **HIGHLIGHT:** box the whole window as it snaps back to the original sizes.
- `[t=5.5]` rest 1.5s. **SCREEN (point at the pre-minimized pane):** "Your own minimized pane
  stayed minimized." **HIGHLIGHT:** circle that pane again — it's still collapsed, not
  restored along with the rest.
- `[t=7.0]` end; hold the final frame 1s.

## Notes
- The two teaching points: (1) one key in / same key out, (2) panes you minimized yourself are
  NOT swept up — they survive untouched. Make the pre-minimized pane visually distinct.
