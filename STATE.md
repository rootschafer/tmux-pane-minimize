# State model

The single reference for every option the plugin reads or writes. There are two
namespaces, by deliberate convention:

- **`@minimize-*`** (hyphen) — **user configuration.** Set these in your tmux config
  before the plugin loads. The plugin only ever *reads* them.
- **`@minimize_*`** (underscore) — **internal runtime state.** The plugin owns these; you
  should not set them by hand. They record which panes are minimized and their remembered
  sizes. Most are *pane* options (`set-option -p`); a couple are *window* or *global*.

Plus a small amount of out-of-band state: a sidecar file (resurrect persistence) and a
per-window lock directory.

---

## Configuration — `@minimize-*` (you set; plugin reads)

| option | default | what |
|--------|---------|------|
| `@minimize-key` | `C-t` | prefix-table key bound to `toggle`. |
| `@minimize-height` | `3` | `MIN_H` — content rows a minimized pane collapses to. |
| `@minimize-width` | `30` | `MIN_W` — columns a *fully* minimized vertical stack narrows to. |
| `@minimize-peek` | `on` | peek-on-focus: focusing a minimized pane expands it to its saved height, collapsing again on focus-out. |
| `@minimize-resurrect` | `on` | persist per-pane state across restarts by setting resurrect's post-save/restore hooks. Turn `off` if you drive those hooks yourself. |
| `@minimize-dashboard-key` | *(unbound)* | opt-in key for `dashboard` (minimize all but active; toggle). |
| `@minimize-minh-step` | `1` | rows per grow/shrink step for the custom minimized height. |
| `@minimize-minh-grow-key` / `-shrink-key` / `-reset-key` | *(unbound)* | opt-in keys for per-pane custom minimized height. |
| `@minimize-marker` | `on` | own `pane-border-status`/`-format` and draw the minimized-pane marker. |
| `@minimize-marker-position` | `top` | `top` or `bottom` (sets `pane-border-status`). |
| `@minimize-marker-style` | `flat` | `flat` (transparent chevrons in the border colour) or `pill` (rounded coloured cap). |
| `@minimize-marker-left-format` | `#[align=left] #{pane_index} ` | what every pane's border shows left of the marker. Set `''` for a marker-only border. |
| `@minimize-marker-format` | *(computed)* | override the whole minimized-pane marker string. |
| `@minimize-marker-icon` / `-icon-active` | chevrons | the inward/outward glyph pair. |
| `@minimize-marker-icon-color` | `default` (flat) / `cutout` (pill) | chevron colour; `auto` picks black/white by pill luminance, or an explicit colour. |
| `@minimize-marker-width` | `3` | pill padding: `3` snug, `5` padded. |
| `@minimize-marker-bg` / `-bg-active` | derived from `pane-border-style` | pill background (inactive / active pane). |
| `@minimize-marker-left` / `-right` | rounded caps | pill end-cap glyphs. |

`@minimize-marker-*` are read once at load by `build_marker` (in `scripts/marker.sh`);
`@minimize-height` / `-width` are read on **every** engine invocation (they can change
live). Everything else is read once at load by `pane-minimize.tmux`.

---

## Runtime state — `@minimize_*` (plugin owns; don't set by hand)

| option | scope | written by | read by | lifecycle |
|--------|-------|-----------|---------|-----------|
| `@minimize_active` | pane | toggle / dashboard / restore-state | `apply` (→ MINSET), marker format, focus/resize hooks | set when a pane is minimized; cleared on un-minimize or when the user resizes the active pane taller. |
| `@minimize_saved` | pane | toggle (on minimize), resize-while-peeked hook, dashboard ENTER | toggle (on un-minimize), `peekin` (peek height) | the pane's height *before* minimizing — the size it restores/peeks to. |
| `@minimize_saved_w` | pane | toggle (on minimize), dashboard ENTER | `apply` (→ SAVEDW, restore a narrowed stack's width) | the pane's width before a fully-minimized stack narrowed. |
| `@minimize_minh` | pane | `dragend`, `minh-set/grow/shrink` | `apply` (→ MINH map) | per-pane custom minimized height; **cleared on un-minimize** (per-minimize-session). |
| `@minimize_peek` | pane | `peekin` (set) / `peekout` (unset) | `apply` (excluded from MINSET while peeking), focus hooks | transient: set only while a minimized pane is focused and expanded. Not persisted. |
| `@minimize_dashboard` | pane | dashboard ENTER | dashboard EXIT (which panes WE minimized) | flags panes minimized *by* dashboard so user-minimized panes survive the round trip. Cleared on EXIT. |
| `@minimize_dashboard_layout` | window | dashboard ENTER | dashboard EXIT (verbatim restore) | the exact `window_layout` saved on ENTER; unset on EXIT. |
| `@minimize_guard` | global | `apply`, `dashboard` | the `after-resize-pane` hooks | transient mutex flag: set while the plugin runs its own `select-layout`/`resize-pane` so the resize hooks don't mistake them for a user resize. |

### The pure transform's inputs

`apply()` reads the `@minimize_*` pane options above plus `#{window_layout}` in one
chained tmux call, folds them into the strings the **pure** `transform()` consumes —
`MINSET` (minimized pane numbers), `SAVEDW`, `MINH`, `WPANE`/`WVAL` (the restore pane and
its target height) — and `BORDER_POS`. `transform()` (in `scripts/transform.sh`) touches
no tmux: same inputs → same layout, which is what the offline suite exhaustively checks.

---

## Out-of-band state

- **Resurrect sidecar** — `${@resurrect-dir:-~/.tmux/resurrect}/tmux-pane-minimize.state`.
  One TAB line per minimized pane (`session  window  pane  saved  saved_w  minh`), keyed by
  resurrect's stable `session:window.pane_index` identity. Written by `save-state`, replayed
  by `restore-state`, both wired to resurrect's `post-save-all`/`post-restore-all` hooks when
  `@minimize-resurrect on`. Peek and dashboard grouping are intentionally **not** persisted.
- **Per-window lock** — `${TMPDIR:-/tmp}/tmux-min-<window>.lock/` (an atomic `mkdir`
  mutex; macOS has no `flock`). Serializes `toggle`/`peekin`/`peekout`/`repin`/… so the
  focus/resize hooks (which fire concurrent `run-shell -b` copies) can't interleave applies.
  A dead holder is reclaimed via its recorded `pid`; a ~20s valve prevents a wedged holder
  hanging a keystroke forever.
