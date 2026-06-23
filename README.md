# tmux-pane-minimize

Collapse a tmux pane to a few lines and toggle it back — like minimizing a window.
Minimized panes stay pinned at their small size when you minimize/restore/resize
**other** panes, and it works for **any layout, however deeply nested** (it rewrites
the window layout tree directly rather than nudging panes with `resize-pane`).

Features:

- **Toggle** any pane minimized/restored (`prefix + Ctrl-t` by default).
- **Peek on focus** — selecting a minimized pane temporarily expands it; moving away
  re-collapses it.
- **Per-pane minimized height** — drag a minimized pane's border, or use keys, to give
  it its own height.
- **Dashboard view** — one key minimizes everything except the active pane; press again
  to restore.
- **Survives [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)** — minimized
  state is persisted across a save/restore.

A minimized pane is forgotten automatically when *you* resize it (toggle key, border
drag, or resize keys) — but **not** when the terminal window itself is resized.

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

### Nix (flake)
Add the repo as a flake input and run its entry point from your tmux config:
```nix
# flake.nix
inputs.tmux-pane-minimize = {
  url = "github:rootschafer/tmux-pane-minimize";
  flake = false;
};
```
```nix
# wherever you build your tmux config (Home Manager / nix-darwin / NixOS)
programs.tmux.extraConfig = ''
  run-shell ${inputs.tmux-pane-minimize}/pane-minimize.tmux
  set -g @minimize-height 3
  # ... other @minimize-* options ...
'';
```
Pin/update with `nix flake update tmux-pane-minimize`.

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

### Peek on focus
Selecting a minimized pane temporarily expands it to its saved height so you can glance
at it; moving focus away re-collapses it. On by default — set `@minimize-peek 'off'` to
disable. (Requires `focus-events on`, which most configs already set.) Resizing a pane
while it's peeked updates its saved height.

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

### tmux-resurrect / continuum
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) restores the window
layout (so minimized panes come back the right *size*), but not the per-pane options
that mark a pane as minimized — so without help the plugin forgets which panes were
minimized after a restore. With `@minimize-resurrect 'on'` (the default) this plugin
hooks resurrect's save/restore to persist that state, keyed by
`session:window.pane_index`. **It sets `@resurrect-hook-post-save-all` and
`@resurrect-hook-post-restore-all`** — if you already use those hooks yourself, set
`@minimize-resurrect 'off'` and call `scripts/tmux-min.sh save-state` / `restore-state`
from your own hooks instead. (Peek and the dashboard grouping are transient and aren't
persisted.)

## Options
```tmux
set -g @minimize-key 'C-t'          # toggle key (prefix table)
set -g @minimize-height '3'         # minimized height in rows
set -g @minimize-width  '30'        # minimized width in columns (narrow column)
set -g @minimize-peek 'on'          # 'off' to disable peek-on-focus
set -g @minimize-marker 'on'        # 'off' to hide the on-border state marker
set -g @minimize-menu 'off'         # 'on' to add Minimize/Un-Minimize to the
                                    #      right-click (MouseDown3Pane) pane menu
set -g @minimize-marker-position 'top'   # 'top' | 'bottom' (the border line)

# The marker shows two chevrons that point inward (minimized) / outward (peeked). Two
# styles:
#   flat (default) — just the chevrons, coloured 'default' which on a pane border is the
#                    border-line colour, so they match the border per active/inactive pane
#                    and stay transparent (no background).
#   pill           — a rounded coloured background (your border colours) with the chevrons
#                    "cut out" of it (drawn in the terminal background via #[reverse], so
#                    they stay sharp on any theme without a contrast guess).
set -g @minimize-marker-style 'flat'    # 'flat' (transparent) | 'pill'
set -g @minimize-marker-icon ''         # inactive glyph (default two chevrons, inward)
set -g @minimize-marker-icon-active ''  # active/peeked glyph (default two chevrons, outward)
set -g @minimize-marker-icon-color ''   # default: 'default' (flat) / 'cutout' (pill); 'auto'
                                        #          = black/white by bg luminance; or a colour
# pill-only:
set -g @minimize-marker-width '3'        # pill padding: '3' (snug) or '5'
set -g @minimize-marker-bg ''            # inactive pill bg (default: inactive border colour)
set -g @minimize-marker-bg-active ''     # active pill bg   (default: active border colour)
set -g @minimize-marker-left ''         # left cap glyph (default rounded U+E0B6)
set -g @minimize-marker-right ''        # right cap glyph (default rounded U+E0B4)
set -g @minimize-marker-format ''        # set to fully override the built marker

# Per-pane minimized height (optional). Drag a NON-active minimized pane's border to
# set its minimized height; or bind keys to set it from the keyboard:
set -g @minimize-minh-step       '1'  # rows per grow/shrink press
set -g @minimize-minh-grow-key   ''   # e.g. '+'  grow focused pane's minimized height
set -g @minimize-minh-shrink-key ''   # e.g. '-'  shrink it
set -g @minimize-minh-reset-key  ''   # e.g. '0'  reset it to @minimize-height

set -g @minimize-dashboard-key   ''   # e.g. 'M'  minimize all panes but the active one

set -g @minimize-resurrect 'on'       # persist minimized state across tmux-resurrect
                                      # save/restore (set 'off' if you manage the
                                      # resurrect hooks yourself — see below)
```
The default marker icon (`󰘖`) is a Nerd Font glyph; override the format with any
glyph your font has (see the fallback note below).

A typical setup that turns on the optional keys:
```tmux
set -g @minimize-key 'C-t'              # prefix + C-t  toggle minimize
set -g @minimize-dashboard-key 'M'      # prefix + M    minimize all but the active pane
set -g @minimize-minh-grow-key '+'      # prefix + +    taller minimized height
set -g @minimize-minh-shrink-key '-'    # prefix + -    shorter
set -g @minimize-minh-reset-key '0'     # prefix + 0    back to @minimize-height
set -g @minimize-marker 'on'            # show the on-border state marker
set -g mouse on                         # for the right-click menu + border-drag sizing
```
Only `@minimize-key` is bound by default; the grow/shrink/reset and dashboard keys are
opt-in (empty until you set them). Resurrect persistence is on by default.

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
or the menu. (To glance at a minimized pane without toggling, just select it — see
[Peek on focus](#peek-on-focus).)

## How it works
On toggle, the plugin reads `#{window_layout}`, parses the layout tree, forces every
pane flagged `@minimize_active` to `@minimize-height`, redistributes the remaining
height within each vertical split (proportionally), recomputes tmux's layout
checksum, and applies it atomically with `select-layout`. A pane that sits in a
horizontal (side-by-side) split collapses its whole row, since panes in a row share
their height. Additionally, when **every** pane within a vertical-split group is
minimized, that whole group is narrowed to `@minimize-width` columns (default 30)
and its horizontal neighbour widens to fill — restoring any pane in the group
widens it back.

If the window is **zoomed**, the plugin preserves the zoom across its own layout
changes — so a terminal resize (which repins minimized panes) or minimizing a background
pane won't kick you out of zoom. Minimizing the zoomed pane itself does exit zoom.

State is kept in per-pane options: `@minimize_active` (is it minimized),
`@minimize_saved` / `@minimize_saved_w` (pre-minimize height / pre-narrow width),
`@minimize_peek` (currently peeked), `@minimize_minh` (per-pane custom height), and
`@minimize_dashboard` (minimized by the dashboard key). A transient global
`@minimize_guard` suppresses the resize hooks during the plugin's own resizes, and a
per-window `mkdir` lock serialises the engine so the backgrounded focus/resize hooks
can't apply conflicting layouts. (Note: the engine names use an underscore,
`@minimize_active`; the user-facing **config options** use a hyphen, `@minimize-height`.)

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
