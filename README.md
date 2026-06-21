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

## Options
```tmux
set -g @minimize-key 'C-t'          # toggle key (prefix table)
set -g @minimize-height '3'         # minimized height in rows
set -g @minimize-width  '15'        # minimized width in columns (narrow column)
set -g @minimize-marker 'off'       # 'on' to show a marker on minimized panes
set -g @minimize-button 'off'       # 'on' to also show a clickable minimize button
                                    #      on normal panes (needs the marker on)
set -g @minimize-marker-position 'top'   # 'top' | 'bottom' (the border line)
set -g @minimize-marker-format '#[align=right]#[fg=colour214]#[bold]  󰘖 #[default]'  # restore icon (minimized)
set -g @minimize-button-format '#[align=right]#[fg=colour244]  󰘕 #[default]'         # minimize icon (normal)
```
The default icons (`󰘖` expand / `󰘕` collapse) are Nerd Font glyphs; override the
formats with any glyph your font has (see the fallback note below).

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

**Glyph not rendering?** The defaults (`󰘖`/`󰘕`) need a Nerd Font. If you see a box,
set `@minimize-marker-format` / `@minimize-button-format` to glyphs your font has —
e.g. universal `+`/`-`, `▢`/`_`, or `⌄`/`⌃`. The colours (`colour214` orange,
`colour244` grey) are configurable in the same formats; pick high-contrast colours
if they're hard to read against your theme.

## Click to toggle
Click the marker (the right edge of a pane's border line) to toggle that pane —
a minimized pane **restores**, and with `@minimize-button on` a normal pane
**minimizes**. This needs `set -g mouse on`. It binds `MouseDown1Border`, which has
no default binding and is separate from drag-to-resize (`MouseDrag1Border`), so it
doesn't interfere with resizing or pane selection.

If you draw your own `pane-border-format` (marker `off`), click-to-restore still
works — it's based on pane geometry, not on who renders the marker. To get the
clickable minimize button on normal panes, set `@minimize-button on` and include the
button icon in your format, e.g.:
```tmux
set -g pane-border-format '#{?@minimize_active,#[align=right]#[fg=colour214]  󰘖 ,#[align=right]#[fg=colour244]  󰘕 }'
```

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
tmux ≥ 3.0 (`select-layout`, `#{window_layout}`, hooks, `MouseDown1Border`/
`MouseDragEnd1Border`, `#{mouse_x}`/`#{mouse_y}`) and a POSIX shell with `awk`,
`sort`, `tr` — no GNU-only flags; tested on macOS bash 3.2. Click-to-toggle also
needs `set -g mouse on`.

## Known limitations
- A pane that is **both minimized and at the very top/bottom edge** renders one row
  shorter than `@minimize-height`, because the pane-border status line overlays that
  edge row.
- Click-to-toggle fires on mouse **press** (`MouseDown1Border`), so beginning a
  resize-drag from exactly within the marker's right-edge hit region (the last few
  columns of a border line) will toggle the pane. Grab the border elsewhere to drag.
- Resizing an **unrelated** pane with the keyboard can nudge a minimized pane; the
  toggle key and mouse-drag paths keep it exact.
- The auto-forget mechanism (clearing minimized state when you resize a pane
  manually) only checks height. Manually dragging a narrowed vertical stack wider
  won't clear its saved widths, so a subsequent full-minimize/restore cycle might
  restore a stale width.

## License
MIT
