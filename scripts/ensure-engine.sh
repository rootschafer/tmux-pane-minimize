#!/usr/bin/env bash
# Ensure the Rust transform engine (tmux-min-transform) is available — WITHOUT asking the
# user to install a toolchain.
#
# Nix installs ship the engine prebuilt beside the scripts, so this is a fast no-op there.
# For TPM / manual installs, the binary is DOWNLOADED from the plugin's GitHub release:
# scripts/engine.manifest (committed to the repo by the release workflow) pins the release
# tag and the sha256 the binary must match per target, so a `git pull`/TPM update that
# bumps the manifest re-fetches the matching engine automatically. The binary lands in
# ~/.local/share/tmux-pane-minimize/ (XDG_DATA_HOME), where tmux-min.sh resolves it.
#
# Fallback ladder when there is no prebuilt for this platform (or the download fails):
# build from source with an ALREADY-INSTALLED cargo (the crate has zero dependencies, so
# it's fast and offline) — we never install Rust ourselves. Failing that, print what to do.
#
# Opt out of the download entirely with `set -g @minimize-engine-fetch off` (the cargo
# fallback still applies).
#
# pane-minimize.tmux runs this in the background on every load; every exit path is `exit 0`
# so a failure never dumps into a pane — problems surface via display-message instead.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"   # repo root (scripts/..)
MANIFEST="$DIR/scripts/engine.manifest"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-pane-minimize"
DATA_BIN="$DATA_DIR/tmux-min-transform"
DATA_VER_FILE="$DATA_DIR/engine-version"                     # what release DATA_BIN came from
DEV_BIN="$DIR/target/release/tmux-min-transform"             # cargo workspace target/ at repo root

note() { tmux display-message "tmux-pane-minimize: $*" 2>/dev/null || true; }

# Already available via a resolution path that outranks the download dir? Nothing to do.
# (These mirror scripts/tmux-min.sh's ladder: env override, Nix beside-scripts, PATH.)
[ -n "${TMUX_MIN_TRANSFORM:-}" ] && [ -x "${TMUX_MIN_TRANSFORM:-}" ] && exit 0
[ -x "$DIR/scripts/tmux-min-transform" ] && exit 0          # Nix package (binary beside scripts)
command -v tmux-min-transform >/dev/null 2>&1 && exit 0     # on PATH

# The pinned engine release + repo, from the manifest. Absent manifest (pre-release
# checkout / fork without releases) => nothing to pin against; PIN stays empty.
PIN="" REPO=""
if [ -f "$MANIFEST" ]; then
  PIN="$(awk '$1 == "version" { print $2; exit }' "$MANIFEST")"
  REPO="$(awk '$1 == "repo" { print $2; exit }' "$MANIFEST")"
fi

# A previously-installed engine that still matches the pin (or that nothing pins) is done.
# A version mismatch falls through to re-fetch; the old binary keeps working until the
# atomic mv below replaces it, so an update is seamless and an offline machine degrades
# to the previous engine rather than to nothing.
if [ -x "$DATA_BIN" ]; then
  [ -z "$PIN" ] && exit 0
  [ "$(cat "$DATA_VER_FILE" 2>/dev/null || true)" = "$PIN" ] && exit 0
fi

# No pin to fetch against: a local cargo build is as current as we can know. (With a pin,
# we keep going and converge on the pinned prebuilt instead — developers who want their
# own build to win should set TMUX_MIN_TRANSFORM, as CONTRIBUTING.md says.)
[ -z "$PIN" ] && [ -x "$DEV_BIN" ] && exit 0

# ---- try the prebuilt: detect target, download, verify sha256, smoke-test, install ----

_target() {
  case "$(uname -s)" in
    Darwin) case "$(uname -m)" in
              arm64)         echo aarch64-apple-darwin ;;
              x86_64)        echo x86_64-apple-darwin ;;
            esac ;;
    Linux)  case "$(uname -m)" in
              x86_64|amd64)  echo x86_64-unknown-linux-musl ;;
              aarch64|arm64) echo aarch64-unknown-linux-musl ;;
            esac ;;
  esac
}

_sha256() {  # file -> lowercase hex digest (portable: coreutils on Linux, shasum on macOS)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1;    then shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_fetch() {  # url outfile ; https only
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    return 1
  fi
}

try_prebuilt() {
  [ -n "$PIN" ] && [ -n "$REPO" ] || return 1
  [ "$(tmux show-option -gqv @minimize-engine-fetch 2>/dev/null || true)" = "off" ] && return 1
  local target sum tmp url got
  target="$(_target)"
  [ -n "$target" ] || return 1                               # platform without a prebuilt
  sum="$(awk -v t="$target" '$1 == "sha256" && $2 == t { print $3; exit }' "$MANIFEST")"
  [ -n "$sum" ] || return 1
  mkdir -p "$DATA_DIR" 2>/dev/null || return 1
  tmp="$DATA_DIR/.fetch.$$"
  url="https://github.com/$REPO/releases/download/$PIN/tmux-min-transform-$target"
  if ! _fetch "$url" "$tmp"; then rm -f "$tmp"; return 1; fi
  # Integrity: the digest must match the one committed to the repo alongside the code —
  # a corrupted download or a swapped release asset is rejected here.
  got="$(_sha256 "$tmp")"
  if [ -z "$got" ] || [ "$got" != "$sum" ]; then
    rm -f "$tmp"
    note "engine download failed checksum verification — not installing it"
    return 1
  fi
  chmod +x "$tmp"
  # Smoke test: proves the binary executes on this machine (right arch/OS) before install.
  if ! "$tmp" --version >/dev/null 2>&1; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$DATA_BIN" || { rm -f "$tmp"; return 1; }    # atomic: old engine works until here
  printf '%s\n' "$PIN" > "$DATA_VER_FILE.tmp.$$" && mv -f "$DATA_VER_FILE.tmp.$$" "$DATA_VER_FILE"
  note "minimize engine $PIN installed."
  return 0
}

# Fallback: build with an existing cargo (never install one). The result is copied into
# DATA_DIR with the pinned version recorded, so it counts as current until the next bump.
try_cargo() {
  [ -f "$DIR/Cargo.toml" ] || return 1
  [ -w "$DIR" ] || return 1                                  # read-only store path: can't build here
  local cargo log
  if command -v cargo >/dev/null 2>&1; then cargo=cargo
  elif [ -x "$HOME/.cargo/bin/cargo" ]; then cargo="$HOME/.cargo/bin/cargo"
  else return 1
  fi
  note "no prebuilt engine for this platform — building it with cargo (one-time)…"
  log="${TMPDIR:-/tmp}/tmux-min-build.log"
  if ! ( cd "$DIR" && "$cargo" build --release ) >"$log" 2>&1; then
    note "engine build failed ($(tail -n1 "$log" 2>/dev/null)) — full log: $log"
    return 1
  fi
  mkdir -p "$DATA_DIR" 2>/dev/null || return 1
  cp -f "$DEV_BIN" "$DATA_BIN.tmp.$$" && chmod +x "$DATA_BIN.tmp.$$" && mv -f "$DATA_BIN.tmp.$$" "$DATA_BIN" || return 1
  printf '%s\n' "${PIN:-source}" > "$DATA_VER_FILE.tmp.$$" && mv -f "$DATA_VER_FILE.tmp.$$" "$DATA_VER_FILE"
  note "minimize engine built and installed."
  return 0
}

try_prebuilt && exit 0
try_cargo && exit 0

# Both paths failed. If a stale downloaded engine exists it still works — stay quiet-ish;
# otherwise tell the user exactly what to do.
if [ -x "$DATA_BIN" ] || [ -x "$DEV_BIN" ]; then
  note "couldn't update the minimize engine (will retry next reload); using the existing one."
else
  note "engine unavailable: couldn't download a prebuilt (network? unsupported platform?) and cargo isn't installed — see README § Install."
fi
exit 0
