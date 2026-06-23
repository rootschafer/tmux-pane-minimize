# tmux-pane-minimize

Collapse a tmux pane to a few lines and toggle it back — like minimizing a window.
Minimized panes stay pinned at their small size when you minimize/restore/resize
**other** panes, and it works for **any layout, however deeply nested** (it rewrites
the window layout tree directly rather than nudging panes with `resize-pane`).

A minimized pane is forgotten automatically when *you* resize it — by toggle key,
by dragging its border, or with the resize keys — but **not** when the terminal
window itself is resized. You can also **click** the on-border marker to toggle a
pane (restore it, or minimize it when the optional minimize button is enabled).

![status: works on tmux 3.0+](https://img.shields.io/badge/tmux-3.0%2B-green)

## Install

### TPM (recommended)
Add to `~/.tmux.conf`:
```tmux
set -g @plugin 'rootschafer/tmux-pane-minimize'
run '~/.tmux/plugins/tpm/tpm'
```
Then press `prefix + I` to fetch.

### Manual
```tmux
run-shell ~/clone/of/tmux-pane-minimize/pane-minimize.tmux
```

## Usage
`prefix` + `Ctrl-t` toggles the active pane between minimized (`@minimize-height`
rows, default 3) and its previous size. Re-bind with `@minimize-key`.

```
   before                      after minimizing A and B
 ┌──────────────┐            ┌──────────────┐ ⌄   ← A, minimized
 │ A            │            ├──────────────┤ ⌄   ← B, minimized
 ├──────────────┤            │ C            │
 │ B            │            │ (expands to  │
 ├──────────────┤            │  fill)       │
 │ C            │            │              │
 └──────────────┘            └──────────────┘

 minimize *every* pane in a vertical stack and the whole column
 collapses to @minimize-width, letting its neighbour widen to fill.
```

### Per-pane minimized height
Different minimized panes can have different heights. Drag the border of a
**non-active** minimized pane (one that isn't focused) and its new height becomes that
pane's minimized height — it stays minimized rather than expanding. You can also bind
keys (`@minimize-minh-grow-key` / `-shrink-key` / `-reset-key`) to adjust the focused
pane's minimized height. Resizing the **active** pane still changes its peek/restored
height, as before. A custom height lasts until the pane is un-minimized, then resets to
the global `@minimize-height`.

### Dashboard view (minimize all but active)
Bind `@minimize-dashboard-key` to collapse every pane in the window except the active
one into minimized strips — a quick "focus on this pane" view. Press it again to
restore the previous layout exactly. Panes you had already minimized yourself stay
minimized through the round trip.

## Options
```tmux
set -g @minimize-key 'C-t'          # toggle key (prefix table)
set -g @minimize-height '3'         # minimized height in rows
set -g @minimize-width  '15'        # minimized width in columns (narrow column)
set -g @minimize-marker 'off'       # 'on' to show a state marker on minimized panes
set -g @minimize-menu 'off'         # 'on' to add Minimize/Un-Minimize to the
                                    #      right-click (MouseDown3Pane) pane menu
set -g @minimize-marker-position 'top'   # 'top' | 'bottom' (the border line)
set -g @minimize-marker-format '#[align=right]#[fg=colour214]#[bold]  󰘖 #[default]'  # marker (minimized)

# Per-pane minimized height (optional). Drag a NON-active minimized pane's border to
# set its minimized height; or bind keys to set it from the keyboard:
set -g @minimize-minh-step       '1'  # rows per grow/shrink press
set -g @minimize-minh-grow-key   ''   # e.g. '+'  grow focused pane's minimized height
set -g @minimize-minh-shrink-key ''   # e.g. '-'  shrink it
set -g @minimize-minh-reset-key  ''   # e.g. '0'  reset it to @minimize-height

set -g @minimize-dashboard-key   ''   # e.g. 'M'  minimize all panes but the active one
```
The default marker icon (`󰘖`) is a Nerd Font glyph; override the format with any
glyph your font has (see the fallback note below).

### About the marker (opt-in)
The marker needs a pane-border status line, so enabling `@minimize-marker on`
makes the plugin set `pane-border-status` and `pane-border-format` for you (this
replaces the border line's contents with just the marker — non-minimized panes show
an empty line). If you already customize those, leave the marker `off` and add your
own conditional on `#{@minimize_active}` instead, e.g.:
```tmux
set -g pane-border-status top
set -g pane-border-format '#{pane_index} #{?@minimize_active,#[fg=yellow]  ⌄ ,}'
```
The leading spaces matter: with `#[align=right]` the border line is drawn right up
to the marker, so a space or two keeps it from butting against the line.

**Glyph not rendering?** The default (`󰘖`) needs a Nerd Font. If you see a box, set
`@minimize-marker-format` to a glyph your font has — e.g. universal `+`, `▢`, or `⌄`.
The colour (`colour214` orange) is configurable in the same format; pick a
high-contrast colour if it's hard to read against your theme.

## Mouse: the right-click menu
`@minimize-menu on` adds a **Minimize / Un-Minimize** item (toggling per the pane's
state) to the top of a right-click (`MouseDown3Pane`) pane menu, alongside a few
handy defaults (Zoom, Swap, Kill). Needs `set -g mouse on`.

This is the supported click path because a *pane* mouse event resolves `#{pane_id}`
to the exact moused pane. Clicking the border **icon** is deliberately *not* wired up:
border mouse events resolve to an inconsistent neighbouring pane near column dividers
and expose no coordinates, and a pane-content click would steal the top cell from
child TUIs. The border icon is therefore a **state indicator**; toggle with the key
or the menu. (A focus-based "peek" — temporarily expand a minimized pane while it's
selected — is planned; see `PLAN.md`.)

## How it works
On toggle, the plugin reads `#{window_layout}`, parses the layout tree, forces every
pane flagged `@minimize_active` to `@minimize-height`, redistributes the remaining
height within each vertical split (proportionally), recomputes tmux's layout
checksum, and applies it atomically with `select-layout`. A pane that sits in a
horizontal (side-by-side) split collapses its whole row, since panes in a row share
their height. Additionally, when **every** pane within a vertical-split group is
minimized, that whole group is narrowed to `@minimize-width` columns (default 15)
and its horizontal neighbour widens to fill — restoring any pane in the group
widens it back.

State is kept in per-pane options `@minimize_active`, `@minimize_saved` (pre-minimize
height) and `@minimize_saved_w` (pre-narrow width), plus a transient global
`@minimize_guard` used to suppress the resize hooks during the plugin's own resizes.

## Requirements
tmux ≥ 3.0 (`select-layout`, `#{window_layout}`, hooks, `MouseDragEnd1Border`,
`MouseDown1Pane` with pane-relative `#{mouse_x}`/`#{mouse_y}`) and a POSIX shell with
`awk`, `sort`, `tr` — no GNU-only flags; tested on macOS bash 3.2. Click-to-toggle
also needs `set -g mouse on`.

## Known limitations
- A pane that is **both minimized and at the very top/bottom edge** renders one row
  shorter than `@minimize-height`, because the pane-border status line overlays that
  edge row.
- The border **icon is not clickable** — border mouse events resolve to an
  inconsistent neighbouring pane and carry no coordinates, so they can't be mapped to
  a pane reliably. Toggle via the key or the right-click menu (`@minimize-menu`).
- Resizing an **unrelated** pane with the keyboard can nudge a minimized pane; the
  toggle key and mouse-drag paths keep it exact.
- The auto-forget mechanism (clearing minimized state when you resize a pane
  manually) only checks height. Manually dragging a narrowed vertical stack wider
  won't clear its saved widths, so a subsequent full-minimize/restore cycle might
  restore a stale width.

## License
MIT
