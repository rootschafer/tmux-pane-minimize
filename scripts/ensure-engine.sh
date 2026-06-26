#!/usr/bin/env bash
# Ensure the Rust transform engine (tmux-min-transform) is built and available.
#
# Nix installs ship the engine prebuilt beside the scripts, so this is a no-op there.
# For TPM / manual installs the binary doesn't exist on first load, so pane-minimize.tmux
# runs this IN THE BACKGROUND once: it builds engine-rs/ with cargo, and — if cargo isn't
# installed — bootstraps a minimal Rust toolchain via rustup first (opt out with
# `set -g @minimize-auto-install-rust off`). Minimize starts working once it finishes.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # repo root (scripts/..)
BIN="$DIR/target/release/tmux-min-transform"                 # cargo workspace target/ at repo root

note() { tmux display-message "tmux-pane-minimize: $*" 2>/dev/null || true; }

# Already available via any of tmux-min.sh's resolution paths? Then there's nothing to do.
[ -n "${TMUX_MIN_TRANSFORM:-}" ] && [ -x "${TMUX_MIN_TRANSFORM:-}" ] && exit 0
[ -x "$DIR/scripts/tmux-min-transform" ] && exit 0          # Nix package (binary beside scripts)
command -v tmux-min-transform >/dev/null 2>&1 && exit 0     # on PATH
[ -x "$BIN" ] && exit 0                                     # prior cargo build
[ -f "$DIR/Cargo.toml" ] || { note "engine source (Cargo.toml) missing — cannot build"; exit 0; }

# Locate cargo: PATH, then a rustup install under ~/.cargo.
CARGO=""
if command -v cargo >/dev/null 2>&1; then
  CARGO=cargo
elif [ -x "$HOME/.cargo/bin/cargo" ]; then
  CARGO="$HOME/.cargo/bin/cargo"
fi

if [ -z "$CARGO" ]; then
  if [ "$(tmux show-option -gqv @minimize-auto-install-rust 2>/dev/null || true)" = "off" ]; then
    note "Rust not found. Build the engine (cargo build --release in engine-rs/) or set @minimize-auto-install-rust on."
    exit 0
  fi
  command -v curl >/dev/null 2>&1 || { note "need cargo or curl to build the engine — see README"; exit 0; }
  note "installing a minimal Rust toolchain (one-time) to build the engine…"
  if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path >/dev/null 2>&1; then
    note "Rust install failed — install rustup/cargo and reload, or build engine-rs manually."
    exit 0
  fi
  CARGO="$HOME/.cargo/bin/cargo"
fi

note "building the minimize engine (one-time)…"
if ( cd "$DIR" && "$CARGO" build --release >/dev/null 2>&1 ); then
  note "minimize engine ready."
else
  note "engine build failed — run: cargo build --release (from the repo root)"
fi
