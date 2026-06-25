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

### Building the engine
The layout math runs in a small compiled Rust engine (`engine-rs/`, binary
`tmux-min-transform`) — it has zero dependencies, so the build is fast and offline:
```sh
cargo build --release --manifest-path engine-rs/Cargo.toml
```
The plugin finds the binary via `$TMUX_MIN_TRANSFORM`, then your `PATH`, then the
`engine-rs/target/release` build above. For a TPM/manual install, build it once (or put
`tmux-min-transform` on your `PATH`); set `TMUX_MIN_TRANSFORM` to an explicit path if you
install the binary elsewhere. On Nix, build it with `rustPlatform.buildRustPackage` and
`set-environment -g TMUX_MIN_TRANSFORM <store-path>/bin/tmux-min-transform` before loading
the plugin. If the binary can't be found, minimize/peek do nothing (there is no fallback).

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
`session:window.pane_index`. It **chains onto** `@resurrect-hook-post-save-all` and
`@resurrect-hook-post-restore-all` — if you already set those hooks yourself, they're
preserved (ours runs after, via resurrect's `eval`), so you don't need to disable anything.
Set `@minimize-resurrect 'off'` to opt out entirely and call `scripts/tmux-min.sh
save-state` / `restore-state` from your own hooks. (Peek and the dashboard grouping are
transient and aren't persisted.)

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
set -g @minimize-marker-style 'flat'    # 'flat' (transparent) | 'pill' | 'none' (no marker)
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
                                      # save/restore (chains onto your resurrect hooks,
                                      # preserving them; 'off' to opt out — see below)
```
A typical setup that turns on the optional keys:
```tmux
set -g @minimize-key 'C-t'              # prefix + C-t  toggle minimize
set -g @minimize-dashboard-key 'M'      # prefix + M    minimize all but the active pane
set -g @minimize-minh-grow-key '+'      # prefix + +    taller minimized height
set -g @minimize-minh-shrink-key '-'    # prefix + -    shorter
set -g @minimize-minh-reset-key '0'     # prefix + 0    back to @minimize-height
set -g @minimize-marker-style 'pill'    # 'flat' (default) or 'pill'
set -g mouse on                         # for the right-click menu + border-drag sizing
```
Only `@minimize-key` is bound by default; the grow/shrink/reset and dashboard keys are
opt-in (empty until you set them). The marker and resurrect persistence are on by default.

### About the marker
The marker is **on by default**. Looks:
- **flat** (default) — just the chevrons, in `fg=default`, which on a pane border *is* the
  border line's colour — so they match the border per active/inactive pane and stay
  transparent. Clean on any theme; nothing to configure.
- **pill** (`@minimize-marker-style pill`) — a rounded background in your border colour
  with the chevrons cut out of it (via `#[reverse]`, so they read on any theme).
- **none** (`@minimize-marker-style none`) — no indicator; the plugin leaves your
  `pane-border-*` options completely alone.

#### Place the marker yourself (keep control of your border)
The plugin publishes the computed marker to the **`@minimize-indicator`** option. Embed it
anywhere in your *own* `pane-border-format` and the plugin will **not** touch your border:
```tmux
set -g pane-border-status top
set -g pane-border-format '#[align=left] #{pane_index} #{?@minimize_active,#{E:#{@minimize-indicator}},}'
```
`#{E:…}` expands the indicator's nested formatting; the `#{?@minimize_active,…,}` shows it
only on minimized panes. This is the recommended way if you style your border line yourself
— the plugin stops owning `pane-border-format` the moment it sees `@minimize-indicator` in it.

For a **zero-config** install that doesn't reference the option, the plugin instead augments
the existing `pane-border-format` for you (remembering the original). To keep that augment
behaviour but change what's left of the marker, set `@minimize-marker-left-format`. To turn
the indicator off entirely, set `@minimize-marker off` or `@minimize-marker-style none`.

**Glyphs not rendering?** The chevrons need a Nerd Font (or any font with U+F053/F054). If
you see boxes, set `@minimize-marker-icon` / `-icon-active` to glyphs your font has. The
rounded pill caps need Powerline glyphs (U+E0B6/E0B4) — set `@minimize-marker-left ''` /
`-right ''` to drop them for square ends.

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
