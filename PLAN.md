# Roadmap — toward the best tmux pane-minimize plugin

Status of the codebase and the concrete next steps. Anything marked **DESIGN-READY**
has a complete implementation plan below and just needs to be built + tested.

## What works today
- Toggle minimize/restore of the active pane (`prefix` + `@minimize-key`, default `C-t`).
- Correct layout math for **arbitrary nesting** (rewrites the window-layout tree +
  recomputes tmux's checksum, applied atomically via `select-layout`).
- **Width-collapse**: when every pane in a vertical stack is minimized, the whole
  column narrows to `@minimize-width` and its neighbour widens; restoring widens back.
- **Forget-on-manual-resize** (keyboard, `resize-pane`, border drag) but not on
  terminal/window resize (those re-pin).
- **State indicator icon** on minimized panes (opt-in `@minimize-marker`, or via your
  own `pane-border-format` reading `#{@minimize_active}`).
- **Right-click menu** item "Minimize / Un-Minimize" (opt-in `@minimize-menu`).
- Offline `selftest`; macOS bash 3.2 compatible; `run-shell` paths force exit 0.

## Locked design decisions
1. **The border icon is NOT clickable, by design.** tmux border mouse events (a)
   resolve `#{pane_id}` to an *inconsistent* neighbouring pane near column dividers
   (verified: a left-column icon resolved to the pane above; a right-edge icon
   resolved correctly) and (b) expose **no** `#{mouse_x}`/`#{mouse_y}`. There is no
   way to map a border-icon click to its owning pane reliably across layouts.
   Rejected alternatives: a pane-content hot-corner (steals the top-left cell from
   child TUIs — unacceptable); `border-status bottom` (same junction ambiguity).
   → The icon is a **state indicator**; toggling is via key + right-click menu.
2. **Click path = right-click menu**, because a *pane* event resolves `#{pane_id}`
   exactly. (Default `MouseDown1Pane` is left untouched: click-to-focus and mouse
   forwarding to child apps are preserved.)
3. Plugin is **vendored + loaded natively** in the dotfiles (not TPM); the standalone
   repo stays published for TPM users.

---

## DESIGN-READY: Peek-on-focus (temporary expand while selected)

**Goal:** selecting a minimized pane (by click or keyboard nav) temporarily expands it
so you can inspect it; leaving it re-collapses it — without clearing its minimized
state. Lets you cycle through minimized panes without re-toggling. Default **on**,
disable with the user option `set -g @minimize-peek off`.

### State
- New transient per-pane user option `@minimize_peek` (`1` while peeking).
- A pane is "logically minimized" when `@minimize_active=1`. It is *displayed*
  minimized when `@minimize_active=1 AND @minimize_peek!=1`.

### Engine changes (`scripts/tmux-min.sh`)
- `apply()` builds `MINSET` from panes where **`@minimize_active=1 AND @minimize_peek!=1`**
  (one extra `#{?...}` in the `list-panes -F`). Peeking panes are excluded → the
  existing layout math expands them automatically.
- The peeked pane should expand to ~its saved size: reuse the restore weight path
  (`WPANE`/`WVAL` = the pane's `@minimize_saved`) so it rejoins at roughly its prior
  height instead of an even share.
- `toggle_pane()` on restore must also clear `@minimize_peek` (a real un-minimize
  ends any peek).
- New subcommands: `peekin <pane_id>` (set `@minimize_peek=1`, guard, `apply`) and
  `peekout <pane_id>` (unset `@minimize_peek`, guard, `apply`).

### Hooks (`pane-minimize.tmux`) — gated on `@minimize-peek on`
Requires `focus-events on` (already set in this dotfiles config).
```tmux
set-hook -g pane-focus-in  "if -F '#{&&:#{@minimize_active},#{!=:#{@minimize_peek},1}}' 'run-shell -b \"$SCRIPT peekin #{pane_id}\"'"
set-hook -g pane-focus-out "if -F '#{@minimize_peek}' 'run-shell -b \"$SCRIPT peekout #{pane_id}\"'"
```
(These hooks may already be set by other plugins; append rather than overwrite if so —
tmux `set-hook -a`.)

### Critical interactions to handle (and test)
- **Forget-on-resize false trigger:** a peeking pane is tall, so the existing
  `after-resize-pane` forget rule (`@minimize_active && height>GROW → clear`) would
  *permanently* un-minimize it. Fix: add `&& #{!=:#{@minimize_peek},1}` to that rule.
- **Loop safety:** engine resizes are wrapped in `@minimize_guard`; `select-layout`
  changes size, not focus, so it should not re-fire focus hooks. Still, have `peekin`/
  `peekout` no-op when `@minimize_guard=1`.
- **Window/terminal resize while peeking:** `repin` must keep peeking panes expanded
  (automatic, since they're excluded from `MINSET`).
- **Closing a peeking pane / last pane:** ensure no dangling `@minimize_peek`.

### Verification
- Offline: extend `selftest` with a peek case (pane flagged active+peek → excluded
  from MINSET → expands; flagged active only → minimized).
- Live (isolated server): minimize a stack pane; focus it (expect expand); focus away
  (expect collapse); keyboard-nav through several minimized panes (each peeks);
  confirm the forget rule does NOT clear state on peek; window resize keeps peek.

### Optional companions
- `@minimize-peek-key`: a key that cycles focus through minimized panes (peeking each).
- A short re-collapse debounce so transient focus flicker doesn't thrash the layout.

---

## Other features (rough priority)

1. **Minimize-all / restore-all** keys (`@minimize-all-key`): collapse every non-active
   pane; restore all. Engine already handles multi-pane MINSET, so this is mostly a
   key + setting all panes' `@minimize_active`.
2. **Keyboard menu**: bind a key to the same `display-menu` for users without mouse.
3. **tmux-resurrect/continuum persistence**: save & restore `@minimize_active` (+ saved
   height/width) so minimized state survives a restart. Hook resurrect's save/restore.
4. **Compose with an existing `pane-border-format`** instead of overwriting it when
   `@minimize-marker on` (detect and wrap the current format).
5. **Status-line count**: a format fragment exposing "N minimized" for the status bar.
6. **Per-scope sizes**: allow `@minimize-height`/`-width` overrides per window/pane.
7. **Edge-nibble polish**: currently an edge minimized pane renders 1 row short under a
   border-status line; explore compensating in the layout math universally.
8. **Width auto-forget**: the manual-resize forget rule only checks height; add a width
   check so dragging a narrowed stack wider clears its saved widths.

## Project / quality
- **CI** (GitHub Actions): `bash -n` + `selftest` on macOS and Linux; shellcheck.
- **Demo**: asciinema/GIF in the README (minimize, stack-narrow, peek, menu).
- **Publish** to the TPM plugin list once peek + CI land.
- Expand `selftest` into a small table-driven suite (more nestings, edge cases).

## Open questions (need a decision before building)
- Peek re-collapse: immediate on focus-out, or after a short delay? (Default: immediate.)
- Should `@minimize-menu` replace plain right-click, or live only under a submenu of the
  default `M-MouseDown3Pane` menu? (Current: binds plain `MouseDown3Pane`.)
