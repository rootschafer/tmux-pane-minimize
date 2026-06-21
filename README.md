# tmux-pane-minimize

Collapse a tmux pane to a few lines and toggle it back — like minimizing a window.
Minimized panes stay pinned at their small size when you minimize/restore/resize
**other** panes, and it works for **any layout, however deeply nested** (it rewrites
the window layout tree directly rather than nudging panes with `resize-pane`).

A minimized pane is forgotten automatically when *you* resize it — by toggle key,
by dragging its border, or with the resize keys — but **not** when the terminal
window itself is resized.

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
`prefix` + `Ctrl-t` toggles the active pane between minimized (3 rows) and its
previous size. Re-bind with `@minimize-key`.

## Options
```tmux
set -g @minimize-key 'C-t'          # toggle key (prefix table)
set -g @minimize-height '3'         # minimized height in rows
set -g @minimize-width  '15'        # minimized width in columns (narrow column)
set -g @minimize-marker 'off'       # 'on' to show a marker on minimized panes
set -g @minimize-marker-position 'top'   # 'top' | 'bottom' (the border line)
set -g @minimize-marker-format '#[align=right]#[fg=colour214]#[bold] ⌄ #[default]'
```

### About the marker (opt-in)
The marker needs a pane-border status line, so enabling `@minimize-marker on`
makes the plugin set `pane-border-status` and `pane-border-format` for you. If you
already customize those, leave the marker `off` and add your own conditional on
`#{@minimize_active}` instead, e.g.:
```tmux
set -g pane-border-status top
set -g pane-border-format '#{pane_index} #{?@minimize_active,#[fg=yellow] ⌄ ,}'
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

State is kept in per-pane options `@minimize_active` and `@minimize_saved`, plus a
transient global `@minimize_guard` used to suppress the resize hooks during the
plugin's own resizes.

## Requirements
tmux ≥ 3.0 (`select-layout`, `#{window_layout}`, hooks, `MouseDragEnd1Border`) and a
POSIX shell with `awk`, `sort`, `tr` — no GNU-only flags; tested on macOS bash 3.2.

## Known limitations
- A pane that is **both minimized and at the very top/bottom edge** renders one row
  shorter than `@minimize-height`, because the pane-border status line overlays that
  edge row.
- Resizing an **unrelated** pane with the keyboard can nudge a minimized pane; the
  toggle key and mouse-drag paths keep it exact.
- The auto-forget mechanism (clearing minimized state when you resize a pane
  manually) only checks height. Manually dragging a narrowed vertical stack wider
  won't clear its saved widths, so a subsequent full-minimize/restore cycle might
  restore a stale width.

## License
MIT
