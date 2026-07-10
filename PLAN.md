# Roadmap

What's shipped, and what's next. (The feature docs live in README.md; the state model in
STATE.md; dev workflow in CONTRIBUTING.md.)

## Shipped (v0)

- Toggle minimize/restore for any pane in **any layout nesting** — the engine rewrites the
  window-layout tree and applies it atomically (compiled Rust engine, ~30× the bash port).
- Peek-on-focus; per-pane minimized height (keys + border drag); per-group minimized width;
  minimize-others; width-collapse of fully-minimized stacks (opt-in `@minimize-narrow`).
- tmux-resurrect persistence (chains politely onto existing hooks).
- Border marker (flat/pill), embeddable in your own `pane-border-format`.
- **Install without a toolchain**: prebuilt engine per platform on GitHub Releases,
  pinned + sha256-verified by `scripts/engine.manifest`, fetched in the background;
  Nix flake ships it built from source; cargo fallback for exotic platforms.
- CI on macOS + ubuntu: cargo tests, Rust-vs-bash differential, ~11k offline property
  cases, install-path suite, live isolated-server suite.

## Next (post-v0, driven by real usage)

1. **Peek polish**: `@minimize-peek-key` to cycle through minimized panes; optional
   re-collapse debounce; audit closing-a-pane-mid-peek edge cases.
2. **Keyboard `display-menu`** for mouse-free toggling.
3. **Width auto-forget**: manual-resize forget currently only checks height (see README
   known limitations).
4. **Per-scope sizes**: `@minimize-height`/`-width` overrides per window/pane.
5. **Status-line count** (`N minimized`).
6. Demo GIFs/asciinema for the README; submit to the TPM plugin list.

## Locked design decisions

1. **The border icon is NOT clickable, by design.** tmux border mouse events resolve
   `#{pane_id}` to an inconsistent neighbouring pane near column dividers and expose no
   `#{mouse_x}`/`#{mouse_y}` — there is no reliable mapping from a border click to its
   owning pane. The icon is a state indicator; toggle via key or the right-click menu.
2. **Right-click menu is opt-in** (`@minimize-menu`) or user-owned: a *pane* mouse event
   resolves `#{pane_id}` exactly, so that's the supported click path.
3. **The transform stays pure** — layout math only in `engine-rs/`, tmux IO only in
   `scripts/tmux-min.sh`; `scripts/transform.sh` remains the byte-for-byte test oracle.
4. **No toolchain installs, ever** — the plugin downloads a pinned prebuilt or uses an
   existing cargo; it never bootstraps rustup.
