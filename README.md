# tmux-pane-minimize

Collapse a tmux pane to a few lines and toggle it back — like minimizing a window.
Minimized panes stay pinned at their small size when you minimize/restore/resize
**other** panes, and it works for **any layout, however deeply nested** (it rewrites
the window layout tree directly rather than nudging panes with `resize-pane`).

Features:

- **Toggle** any pane minimized/restored (`prefix + Ctrl-t` by default).
- **Peek on focus** — selecting a minimized pane temporarily expands it; moving away
  re-collapses it.
- **Width-collapse** — minimize *every* pane in a vertical stack and the whole column
  narrows to `@minimize-width`, letting its neighbour widen to fill.
- **Per-pane minimized height** — drag a minimized pane's border, or use keys, to give
  it its own height.
- **Per-group minimized width** — drag the side border of a fully-minimized column to set
  its width; it persists for the life of the group (and across restarts).
- **Minimize others** — one key minimizes everything except the active pane; press again
  to restore.
- **Survives [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)** — minimized
  state (including custom heights/widths) is persisted across a save/restore.
- **Compiled engine** — the layout math runs in a tiny zero-dependency Rust binary; the
  bash side is just tmux glue.

A minimized pane is forgotten automatically when *you* resize it (toggle key, border
drag, or resize keys) — but **not** when the terminal window itself is resized.

![status: works on tmux 3.0+](https://img.shields.io/badge/tmux-3.0%2B-green)

<!-- TODO(hero gif): the headline demo, looping, ~5s. A 3-pane window; toggle one pane
     minimized (it collapses, the others reflow), toggle it back. This is the "what is this"
     graphic — put the most legible single interaction here. Script: docs/recordings/00-hero.md -->

## Install

No compiler, no Rust, no manual steps: the plugin's layout math runs in a small
prebuilt binary that installs itself on first load (see [The engine](#the-engine)).
Add the plugin, reload tmux, done.

### TPM (recommended)
Add to `~/.tmux.conf`:
```tmux
set -g @plugin 'rootschafer/tmux-pane-minimize'
run '~/.tmux/plugins/tpm/tpm'
```
Then press `prefix + I` to fetch. On first load the plugin downloads the engine for
your platform in the background (a few hundred KB, sha256-verified); minimizing works
the moment it lands — typically within seconds. Updating the plugin (`prefix + U`)
updates the engine automatically on the next reload.

### Manual
```sh
git clone https://github.com/rootschafer/tmux-pane-minimize ~/.tmux/tmux-pane-minimize
```
```tmux
run-shell ~/.tmux/tmux-pane-minimize/pane-minimize.tmux
```
Same engine story as TPM: fetched and verified automatically on first load.

### Nix (flake)
The flake package builds the engine from source and ships it inside the plugin output —
nothing is downloaded at runtime. Add the repo as a flake input and run its entry point
from your tmux config:
```nix
# flake.nix
inputs.tmux-pane-minimize.url = "github:rootschafer/tmux-pane-minimize";
```
```nix
# wherever you build your tmux config (Home Manager / nix-darwin / NixOS)
programs.tmux.extraConfig = ''
  run-shell ${inputs.tmux-pane-minimize.packages.${pkgs.system}.default}/pane-minimize.tmux
  set -g @minimize-height 3
  # ... other @minimize-* options ...
'';
```
Pin/update with `nix flake update tmux-pane-minimize`. (Non-flake:
`pkgs.callPackage ./default.nix { }` on a checkout.)

### The engine
The layout math runs in a tiny zero-dependency Rust binary, `tmux-min-transform`
(the `engine-rs/` crate). The plugin resolves it in this order:

1. `$TMUX_MIN_TRANSFORM` — explicit path override.
2. Beside the scripts — where the Nix package places it.
3. Your `PATH`.
4. `~/.local/share/tmux-pane-minimize/` (`$XDG_DATA_HOME`) — where the **automatic
   download** installs it. `scripts/engine.manifest` (committed to this repo by the
   release workflow) pins the exact release and the sha256 the binary must match, so
   a download is verified against a checksum that shipped with the code, and a plugin
   update re-fetches the matching engine by itself.
5. `target/release/` — a local `cargo build --release` (development).

Prebuilt platforms: **macOS** (Apple silicon + Intel) and **Linux** (x86_64 + aarch64,
static musl builds that run on any distro). On anything else — BSDs, other
architectures — the plugin falls back to building the engine with an
already-installed `cargo` (it has zero dependencies, so that's fast and offline); it
never installs a toolchain itself. To forbid the download entirely, set
`set -g @minimize-engine-fetch off` and provide the binary via any of the other paths.
If no engine can be found, minimize/peek are silent no-ops and the plugin tells you
what's wrong via a status-line message.

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
<!-- TODO(gif, <5s, inline): a minimized pane; move focus INTO it (it expands to its saved
     height), move focus AWAY (it re-collapses). Loop it. -->
Selecting a minimized pane temporarily expands it to its saved height so you can glance
at it; moving focus away re-collapses it. On by default — set `@minimize-peek 'off'` to
disable. (Requires `focus-events on`, which most configs already set.) Resizing a pane
while it's peeked updates its saved height.

### Per-pane minimized height
<!-- TODO(gif, <5s, inline): a stack of minimized panes; drag one non-active pane's border
     down — only that pane grows taller, the rest stay collapsed. -->
Different minimized panes can have different heights. Drag the border of a
**non-active** minimized pane (one that isn't focused) and its new height becomes that
pane's minimized height — it stays minimized rather than expanding. You can also bind
keys (`@minimize-minh-grow-key` / `-shrink-key` / `-reset-key`) to adjust the focused
pane's minimized height. Resizing the **active** pane still changes its peek/restored
height, as before. A custom height lasts until the pane is un-minimized, then resets to
the global `@minimize-height`.

### Per-group minimized width
<!-- TODO(video >5s → docs/recordings/03-per-group-width.md): fully minimize a column (it
     narrows), focus away, drag its side border wider; show it sticks across a window resize. -->
When **every** pane in a vertical stack is minimized, the whole column narrows to
`@minimize-width`. If that group has no focused pane, drag its **side** border and the new
width becomes the group's custom minimized width — shared by every pane in the stack. Unlike
the per-pane height, this width **persists** as long as the group exists (across resizes,
un-minimize/re-minimize, and tmux-resurrect restarts), so a column you like wider stays wider.

### Minimize others (focus the active pane)
<!-- TODO(video >5s → docs/recordings/02-minimize-others.md): a busy 4-pane window; press the
     key (everything but the active pane collapses to strips); press again (exact layout
     restored). Show a pre-minimized pane surviving the round trip. -->
Bind `@minimize-others-key` to collapse every pane in the window except the active
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
save-state` / `restore-state` from your own hooks. (Peek and the minimize-others grouping are
transient and aren't persisted.)

## Configuration

### Recommended configuration
A complete, copy-paste setup that gives the experience in the demos above: a toggle key plus
"minimize others", per-pane height keys, the **pill** indicator embedded in your own pane
border, and a right-click pane menu. Drop this in `~/.tmux.conf` (adjust paths/colours/keys).

<!-- TODO(screenshot): a labelled still of a window using this config — one normal pane, one
     minimized (pill indicator visible on its border), one fully-minimized narrow column.
     Caption the pill, the index, and the narrow column. -->

```tmux
# --- tmux-pane-minimize: keys (prefix table) -------------------------------------
set -g @minimize-key             'C-t'  # toggle minimize on the active pane
set -g @minimize-others-key      'M'    # minimize every pane but the active one (toggle)
set -g @minimize-minh-grow-key   '+'    # grow a minimized pane's height
set -g @minimize-minh-shrink-key '_'    # shrink it
set -g @minimize-minh-reset-key  'R'    # reset its height to @minimize-height
set -g @minimize-minw-reset-key  'W'    # reset a minimized group's custom width

set -g @minimize-height 3               # comfortable minimized height (rows)
set -g @minimize-width  30              # width a fully-minimized column narrows to

# Mouse + focus enable the right-click menu, border-drag sizing, and peek-on-focus.
set -g mouse on
set -g focus-events on

# --- Pane borders + the minimized indicator --------------------------------------
# Own your border format and EMBED the plugin's indicator on minimized panes. Because the
# format references @minimize-indicator, the plugin leaves your border styling fully alone.
set -g pane-border-status top
set -g pane-border-lines heavy
set -g pane-border-style        'fg=colour14'   # your inactive border colour
set -g pane-active-border-style 'fg=colour48'   # your active border colour
set -g @minimize-marker-style pill              # indicator look: pill | flat | none
set -g pane-border-format '#[align=left] #{pane_index}#{?#{==:#{pane_title},#{host}},,: #{pane_title}} #{?@minimize_active,#{E:#{@minimize-indicator}},}'

# Load the plugin LAST — after the border colours above — so the pill derives its background
# from them. (TPM users: this `run-shell` is instead `set -g @plugin '…'` — see Install.)
run-shell ~/.tmux/plugins/tmux-pane-minimize/pane-minimize.tmux
```

#### Right-click pane menu (optional)
Adds Minimize / Un-Minimize and Minimize Others to a right-click menu, alongside the usual
pane actions. Point the `run-shell` paths at wherever the plugin lives.

<!-- TODO(gif): right-click a pane → menu opens → click "Minimize" → pane collapses. ~4s, can
     be an inline gif (under 5s). Circle the "Minimize" item on open. -->

```tmux
bind-key -T root MouseDown3Pane \
  display-menu -t = -x M -y M -T "#[align=centre]#{pane_index}" \
    "#{?@minimize_active,Un-Minimize,Minimize}" m \
      "run-shell '~/.tmux/plugins/tmux-pane-minimize/scripts/tmux-min.sh toggle #{pane_id}'" \
    "Minimize Others" a \
      "run-shell '~/.tmux/plugins/tmux-pane-minimize/scripts/tmux-min.sh minimize-others #{pane_id}'" \
    "" \
    "Horizontal Split" h "split-window -h" \
    "Vertical Split"   v "split-window -v" \
    "#{?window_zoomed_flag,Unzoom,Zoom}" z "resize-pane -Z" \
    "" \
    "Kill" X "kill-pane"
```

> **Nix / Home Manager users:** put the blocks above in `programs.tmux.extraConfig`, and use
> the plugin's flake package so the engine is built for you — see
> [Nix (flake)](#nix-flake). Reference the engine paths via the package store path rather than
> `~/.tmux/plugins/…`.

### All options
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
set -g @minimize-minw-reset-key  ''   # e.g. 'W'  reset a minimized group's custom width

set -g @minimize-others-key   ''   # e.g. 'M'  minimize all panes but the active one

set -g @minimize-resurrect 'on'       # persist minimized state across tmux-resurrect
                                      # save/restore (chains onto your resurrect hooks,
                                      # preserving them; 'off' to opt out — see below)

set -g @minimize-engine-fetch 'on'    # 'off' to never download the prebuilt engine;
                                      # provide it via PATH / TMUX_MIN_TRANSFORM / cargo
                                      # instead (see "The engine" above)
```
Only `@minimize-key` is bound by default; the grow/shrink/reset and minimize-others keys are
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
`@minimize_others` (minimized by the minimize-others key). A transient global
`@minimize_guard` suppresses the resize hooks during the plugin's own resizes, and a
per-window `mkdir` lock serialises the engine so the backgrounded focus/resize hooks
can't apply conflicting layouts. (Note: the engine names use an underscore,
`@minimize_active`; the user-facing **config options** use a hyphen, `@minimize-height`.)

## Requirements
tmux ≥ 3.0 (`select-layout`, `#{window_layout}`, hooks, `MouseDragEnd1Border`,
`MouseDown1Pane` with pane-relative `#{mouse_x}`/`#{mouse_y}`) and a POSIX shell with
`awk`, `sort`, `tr` — no GNU-only flags; tested on macOS bash 3.2. Click-to-toggle
also needs `set -g mouse on`. The automatic engine download needs `curl` (or `wget`);
without either, install the binary via one of the other paths in
[The engine](#the-engine).

## Known limitations
- With `pane-border-status` on, tmux paints a ~3-character segment in the **active**
  border colour at the T-junction where a stacked group of panes meets an adjacent
  column. This is tmux's own border painting (the junction cell belongs to both
  panes and tmux resolves it in favour of the active one) — it's cosmetic, and not
  fixable from a plugin without patching tmux.
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
- **Repeated/empty prompts may appear in a pane after many minimize/peek cycles — with some
  prompt frameworks.** This is **not** the plugin sending keystrokes (it never injects input —
  only resizes panes). Every resize sends the pane a `SIGWINCH`; a shell sitting at its prompt
  re-renders it in response. A *default* shell (`zsh`/`bash`) redraws in place — only the
  scrollback grows, which is harmless. But an **asynchronous / self-reprinting prompt** (e.g.
  Spaceship with `SPACESHIP_PROMPT_ASYNC=true`, and some `powerlevel10k`/transient-prompt
  setups) redraws via `zle reset-prompt` on each `SIGWINCH`/focus event, and the resize +
  async redraw can leave the *same* prompt rendered several times (tell-tale sign: the stacked
  prompts all show the **same** command-duration, i.e. one prompt re-rendered, not several
  commands). It predates this plugin — any resize triggers it — but minimize/peek resize far
  more often. Fixes, in order of leverage:
  - **`set -g @minimize-peek off`** — peek resizes on *every* focus change, the dominant source.
  - Tame the prompt's resize behaviour: e.g. `SPACESHIP_PROMPT_ASYNC=false`, or a prompt that
    redraws cleanly on `SIGWINCH`.
  - (The plugin already skips no-op resizes, so it won't churn when nothing actually changed.)

## License
MIT
