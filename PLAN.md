# Roadmap — toward the best tmux pane-minimize plugin

Status of the codebase and concrete next steps. **DESIGN-READY** items have a complete
implementation plan and just need building + testing.

## What works today
- Toggle minimize/un-minimize of the active pane (`prefix` + `@minimize-key`, default `C-t`).
- Correct layout math for **arbitrary nesting** (rewrites the window-layout tree +
  recomputes tmux's checksum, applied atomically via `select-layout`).
- **Width-collapse**: when every pane in a vertical stack is minimized, the whole
  column narrows to `@minimize-width` and its neighbour widens; un-minimizing widens back.
- **Peek-on-focus** (`@minimize-peek`, default on): selecting a minimized pane (click or
  keyboard nav) temporarily expands it to its saved height; leaving re-collapses it,
  keeping its minimized state. Lets you cycle through and inspect minimized panes.
- **Exact-height un-minimize/peek** (fixed this session): the pane being un-minimized or
  peeked is pinned to its **exact saved height** (other flexible panes absorb the
  remainder), instead of a skewed proportional share. Verified: peek returns 19→19,
  not 19→14.
- **Resize-while-peeked is remembered** (this session): resizing a peeked pane
  (keyboard/`resize-pane` via the `after-resize-pane` save-hook, or mouse drag via
  `MouseDragEnd1Border`) writes the new height into `@minimize_saved`, so future
  peeks/un-minimize use it.
- **Forget-on-manual-resize** for a *non-peeked* minimized pane (clears its minimized
  state); skips peeked panes; ignores terminal/window resize (those re-pin).
- **State indicator icon** on minimized panes (opt-in `@minimize-marker`, or via your
  own `pane-border-format` reading `#{@minimize_active}`).
- Idempotent plugin reload: hooks use `set-hook -g` (replace) / a `-g` + `-a` reset
  pair, so reloading never duplicates a hook. Offline `selftest`; macOS bash 3.2
  compatible; all `run-shell` paths force exit 0.

## Locked design decisions
1. **The border icon is NOT clickable, by design.** tmux border mouse events (a)
   resolve `#{pane_id}` to an *inconsistent* neighbouring pane near column dividers and
   (b) expose **no** `#{mouse_x}`/`#{mouse_y}`. No reliable way to map a border-icon
   click to its owning pane. Rejected: pane-content hot-corner (steals a cell from child
   TUIs); `border-status bottom` (same junction ambiguity). The icon is a **state
   indicator**; toggling is via key, the right-click menu, or peek.
2. **Right-click "Minimize/Un-Minimize"** lives in the user's `shared-config.nix`
   `display-menu`, not in the plugin — a *pane* event resolves `#{pane_id}` exactly, and
   the user owns their full menu. (The plugin no longer binds `MouseDown3Pane`.)
3. Dotfiles loads the plugin natively from the standalone working tree
   (`run-shell ~/tmux-pane-minimize/pane-minimize.tmux`) — no nix-store copy, so repo
   edits take effect on tmux config reload without a rebuild. Repo stays published for TPM.
4. **`set-option` does not expand `#{...}`** — capture formats via `run-shell` when a
   hook needs e.g. `#{pane_height}` written into an option.

## Next priorities

1. **Keyboard menu / minimize-all**: bind a key to a `display-menu` (mouse-free toggle),
   and a "minimize every other pane / restore all" key (`@minimize-all-key`). The engine
   already handles a multi-pane MINSET.
2. **DESIGN-READY — peek polish**:
   - `@minimize-peek-key`: cycle focus through minimized panes (peek each in turn).
   - Optional small re-collapse debounce so rapid focus flicker doesn't thrash the layout.
   - Audit edge cases: closing a pane mid-peek (dangling `@minimize_peek`); a peeked pane
     that becomes the only pane; zoom interactions.
3. **tmux-resurrect/continuum persistence**: save & restore `@minimize_active` +
   `@minimize_saved`/`@minimize_saved_w` so minimized state survives a restart. Start
   only once the feature set is stable.
4. **Compose with an existing `pane-border-format`** when `@minimize-marker on` (wrap the
   current format rather than overwriting it).
5. **Status-line count** (`N minimized`); **per-scope sizes** (`@minimize-height/-width`
   overrides per window/pane).
6. **Edge-nibble polish**: an edge minimized pane renders 1 row short under a
   border-status line (`_edge_bonus` compensates partially); make it universal.
7. **Width auto-forget**: the manual-resize forget rule only checks height; add a width
   check so dragging a narrowed stack wider clears its saved widths.

## Project / quality
- **CI** (GitHub Actions): `bash -n` + `selftest` on macOS and Linux; shellcheck.
- Expand `selftest` into a table-driven suite that also exercises the peek/un-minimize
  weight path (`transform` with WPANE/WVAL), not just MINSET membership.
- **Demo**: asciinema/GIF in the README (minimize, stack-narrow, peek, menu).
- **Publish** to the TPM plugin list once the keyboard menu + CI land.

## Known issues / watch-list
- Peek hooks are single-owner (`set-hook -g pane-focus-in/out`): if another plugin also
  uses those hooks, last-writer-wins. Composing politely needs a hook-merge mechanism
  tmux doesn't provide directly — revisit if it ever matters.
- `selftest`'s peek line only checks MINSET exclusion; the exact-height pinning is
  covered by the isolated-server tests, not offline yet.
