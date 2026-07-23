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
| `@minimize-height` | `3` | `MIN_H` — comfortable content rows a minimized pane collapses to when there's room. |
| `@minimize-absolute-min-height` | `1` | `ABS_MIN_H` — the floor a minimized pane is shrunk to (no lower) when a peek/expansion needs the room. Once every minimized pane is at this floor, the expansion is capped. Clamped to `[1, @minimize-height]`. |
| `@minimize-width` | `30` | `MIN_W` — columns a *fully* minimized vertical stack narrows to. |
| `@minimize-peek` | `on` | peek-on-focus: focusing a minimized pane expands it to its saved height, collapsing again on focus-out. |
| `@minimize-resurrect` | `on` | persist per-pane state across restarts by **chaining onto** resurrect's post-save/restore hooks (any hook you already set is preserved — ours runs after it). Turn `off` to opt out entirely. |
| `@minimize-engine-fetch` | `on` | let `ensure-engine.sh` download the prebuilt engine pinned by `scripts/engine.manifest`. `off` = never download; the engine must then come from `TMUX_MIN_TRANSFORM`, beside the scripts (Nix), `PATH`, or a local cargo build. |
| `@minimize-others-key` | *(unbound)* | opt-in key for `minimize-others` (minimize all but active; toggle). |
| `@minimize-minh-step` | `1` | rows per grow/shrink step for the custom minimized height. |
| `@minimize-minh-grow-key` / `-shrink-key` / `-reset-key` | *(unbound)* | opt-in keys for per-pane custom minimized height. |
| `@minimize-minw-reset-key` | *(unbound)* | opt-in key to reset a fully-minimized group's custom width (set by side-border drag) back to `@minimize-width`. |
| `@minimize-marker` | `on` | own `pane-border-status`/`-format` and draw the minimized-pane marker. |
| `@minimize-marker-position` | *(respect existing)* | `top` or `bottom`. Unset = keep the user's current `pane-border-status` (only turn it on, at `top`, if it was `off`). |
| `@minimize-marker-style` | `flat` | `flat` (transparent chevrons in the border colour), `pill` (rounded coloured cap), or `none` (no indicator; leaves `pane-border-*` untouched). |
| `@minimize-indicator` | *(published by plugin)* | the computed indicator format. The plugin **sets** this so you can embed it in your OWN `pane-border-format`: `#{?@minimize_active,#{E:#{@minimize-indicator}},}`. If your `pane-border-format` references it, the plugin leaves your border options alone instead of augmenting them. |
| `@minimize-marker-left-format` | the existing `pane-border-format` | what every pane's border shows left of the marker. Defaults to whatever `pane-border-format` already was (the plugin *augments* rather than replaces it). Set explicitly to e.g. `#[align=left] #{pane_index} ` for an index-only border, or `''` for marker-only. |
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
| `@minimize_active` | pane | toggle / minimize-others / restore-state | `apply` (→ MINSET), marker format, focus/resize hooks | set when a pane is minimized; cleared on un-minimize or when the user resizes the active pane taller. |
| `@minimize_saved` | pane | toggle (on minimize), resize-while-peeked hook, minimize-others ENTER | toggle (on un-minimize), `peekin` (peek height) | the pane's height *before* minimizing — the size it restores/peeks to. |
| `@minimize_saved_set` | pane | `dragend` + the resize-while-peeked hook (set); toggle (cleared on both minimize and un-minimize) | `toggle` / `peekin` → the engine's `WSET` input | did the **user deliberately choose** `@minimize_saved`, by resizing the pane while it was peeked? Unset means `@minimize_saved` is just the height the pane happened to have when it was minimized — a snapshot that can be far bigger than the pane could ever occupy in its current stack (minimize a pane while it is alone in its column, then split it). The engine honours a *set* height exactly (minimized siblings may yield to `@minimize-absolute-min-height`), but treats an *unset* one as a hint that must never push a minimized sibling below `@minimize-height` while the group still has room. |
| `@minimize_saved_w` | pane | toggle (on minimize), minimize-others ENTER, narrow-toggle ON — **all only while `@minimize-narrow` is on** | `apply` (→ SAVEDW, restore a narrowed stack's width) | the pane's width before a fully-minimized stack narrowed — the NARROW feature's memory. Exists **only while narrowing is on** (cleared by narrow-toggle OFF after the widening repin, by minimize/dragend when narrow is off, and skipped by restore-state when narrow is off): with narrow off the engine would otherwise pin a fully-min stack to it on every apply, snapping back user drags. |
| `@minimize_minh` | pane | `dragend`, `minh-set/grow/shrink` | `apply` (→ MINH map) | per-pane custom minimized height; **cleared on un-minimize** (per-minimize-session). |
| `@minimize_minw` | pane | `dragend` (side-border drag on a fully-minimized group) | `apply` (→ MINW map) | custom minimized **width** for a fully-minimized vertical group, stored on each member pane and shared by the group. **Persists** (not cleared on un-minimize) so the group keeps its width; also saved/restored by resurrect. |
| `@minimize_peek` | pane | `peekin` (set) / `peekout` (unset) | `apply` (excluded from MINSET while peeking), focus hooks | transient: set only while a minimized pane is focused and expanded. Not persisted. |
| `@minimize_others` | pane | minimize-others ENTER | minimize-others EXIT (which panes WE minimized) | flags panes minimized *by* minimize-others so user-minimized panes survive the round trip. Cleared on EXIT. |
| `@minimize_others_layout` | window | minimize-others ENTER | minimize-others EXIT (verbatim restore) | the exact `window_layout` saved on ENTER; unset on EXIT. |
| `@minimize_guard` | global | `apply`, `minimize-others` | the `after-resize-pane` hooks | transient mutex flag: set while the plugin runs its own `select-layout`/`resize-pane` so the resize hooks don't mistake them for a user resize. |
| `@minimize_orig_format` | global | `pane-minimize.tmux` at load (once) | same | the user's `pane-border-format` captured before the marker was first appended, so reloads re-augment from the original instead of doubling the marker. |
| `@minimize_marker_installed` | global | `pane-minimize.tmux` at load (once) | same | guard so `@minimize_orig_format` is captured exactly once across reloads. |

### The pure transform's inputs

`apply()` reads the `@minimize_*` pane options above plus `#{window_layout}` in one
chained tmux call, folds them into the strings the **pure** transform consumes —
`MINSET` (minimized pane numbers), `SAVEDW`, `MINH`, `MINW` (custom group widths),
`WPANE`/`WVAL` (the restore pane and its target height) and `WSET` (is that height
user-chosen — see `@minimize_saved_set`) — and `BORDER_POS`, then shells out to the Rust engine
(`tmux-min-transform`, from `engine-rs/`) via `_transform()`. The transform touches no tmux:
same inputs → same layout. `scripts/transform.sh` is the byte-for-byte bash oracle the Rust
engine is validated against, and is what the offline property suite exhaustively checks.

---

## Out-of-band state

- **Resurrect sidecar** — `${@resurrect-dir:-~/.tmux/resurrect}/tmux-pane-minimize.state`.
  One `|`-separated line per minimized pane
  (`win|pane|saved|saved_w|minh|minw|saved_set|session`; session last so a `|` in a session
  name still parses; not TAB — tmux ≤ 3.4 mangles control chars in format output), keyed by
  resurrect's stable `session:window.pane_index` identity. `restore-state` also accepts the
  older 7-field form (no `saved_set`), unshifting it so an upgrade never drops saved state. Written by `save-state`, replayed
  by `restore-state`, both wired to resurrect's `post-save-all`/`post-restore-all` hooks when
  `@minimize-resurrect on`. Peek and minimize-others grouping are intentionally **not** persisted.
- **Downloaded engine** — `${XDG_DATA_HOME:-~/.local/share}/tmux-pane-minimize/`:
  `tmux-min-transform` (the prebuilt binary fetched by `ensure-engine.sh`) plus
  `engine-version` (which release it came from). `scripts/engine.manifest` in the repo —
  written by the release workflow — pins the release tag and per-target sha256; a
  mismatch between `engine-version` and the manifest triggers a background re-fetch on
  plugin load, and the old binary keeps serving until the new one atomically replaces it.
- **Per-window lock** — `${TMPDIR:-/tmp}/tmux-min-<window>.lock/` (an atomic `mkdir`
  mutex; macOS has no `flock`). Serializes `toggle`/`peekin`/`peekout`/`repin`/… so the
  focus/resize hooks (which fire concurrent `run-shell -b` copies) can't interleave applies.
  A dead holder is reclaimed via its recorded `pid`; a ~20s valve prevents a wedged holder
  hanging a keystroke forever.

---

## Shared (non-`@minimize`) global state the plugin touches

The plugin tries to be a **good citizen**: it owns the `@minimize-*` / `@minimize_*`
namespace freely, but where it must touch *shared* global tmux state it PRESERVES what's
already there rather than clobbering. Audit of everything outside our namespace:

| What | How | Citizenship |
|------|-----|-------------|
| `pane-focus-in` / `pane-focus-out` hooks | **append** (`set-hook -a`) via `_add_hook`, idempotent on `$SCRIPT` | preserves your/other plugins' focus hooks; never duplicates on reload |
| `after-resize-pane` (×2) / `after-resize-window` hooks | **append** (`_add_hook`), idempotent | same — preserves existing resize hooks |
| `@resurrect-hook-post-save-all` / `-post-restore-all` | **chain** (`existing ; ours`) via `_add_resurrect_hook`, idempotent on `$SCRIPT` | preserves a resurrect hook you already set; ours runs after |
| `pane-border-status` / `pane-border-format` | only in the **zero-config augment** path; respects existing position, remembers the original. If you embed `@minimize-indicator` in your own format, or set `@minimize-marker-style none`, the plugin does **not** touch them | opt-out by design |
| `@minimize-key` + opt-in keys (`MouseDragEnd1Border`, minimize-others/minh keys) | **replace** (binding a key is replacing) | accepted: binding the key is the user's explicit request. The mouse-border-drag bind has no tmux default. |

Refreshing an *appended* hook after its command changes needs a server restart (or
`set-hook -gu <event>`), since we can't remove just our entry without rebuilding the array —
that's the deliberate cost of not clobbering. New hooks must follow this pattern: append +
idempotent, never bare `set-hook -g` on a shared event.
