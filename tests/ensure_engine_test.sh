#!/usr/bin/env bash
# Offline tests for scripts/ensure-engine.sh — the prebuilt-download install path.
#
# Hermetic: a stub `curl` on PATH serves a local file instead of the network, XDG_DATA_HOME
# points into a scratch dir, and TMUX_TMPDIR is isolated so note()'s display-message can
# never reach a real tmux server. Needs the dev engine built (target/release) as the
# "release asset" to serve; builds it if cargo is available, else skips.
set -u

EE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$EE_DIR/.."
# shellcheck source=lib.sh
. "$EE_DIR/lib.sh"

# check MESSAGE CMD... — run CMD, record ok/bad by its exit status
check() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi
}

BIN="$ROOT/target/release/tmux-min-transform"
if [ ! -x "$BIN" ]; then
  if command -v cargo >/dev/null 2>&1; then
    (cd "$ROOT" && cargo build --release >/dev/null 2>&1) || { echo "cargo build failed — skipping ensure-engine tests"; exit 0; }
  else
    echo "no engine binary and no cargo — skipping ensure-engine tests"; exit 0
  fi
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tmin_ee.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/bin" "$SCRATCH/data" "$SCRATCH/tmux"
export TMUX_TMPDIR="$SCRATCH/tmux"     # isolate note()'s tmux calls from any real server
export XDG_DATA_HOME="$SCRATCH/data"
unset TMUX_MIN_TRANSFORM 2>/dev/null || true

DATA_BIN="$SCRATCH/data/tmux-pane-minimize/tmux-min-transform"
VER_FILE="$SCRATCH/data/tmux-pane-minimize/engine-version"
MANIFEST="$ROOT/scripts/engine.manifest"

# The real manifest (if the release workflow has written one) must survive this test.
SAVED_MANIFEST=""
if [ -f "$MANIFEST" ]; then SAVED_MANIFEST="$SCRATCH/manifest.saved"; cp "$MANIFEST" "$SAVED_MANIFEST"; fi
restore_manifest() {
  if [ -n "$SAVED_MANIFEST" ]; then cp "$SAVED_MANIFEST" "$MANIFEST"; else rm -f "$MANIFEST"; fi
}
trap 'restore_manifest; rm -rf "$SCRATCH"' EXIT

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)  TARGET=aarch64-apple-darwin ;;
  Darwin/x86_64) TARGET=x86_64-apple-darwin ;;
  Linux/x86_64|Linux/amd64)  TARGET=x86_64-unknown-linux-musl ;;
  Linux/aarch64|Linux/arm64) TARGET=aarch64-unknown-linux-musl ;;
  *) echo "unknown test platform — skipping ensure-engine tests"; exit 0 ;;
esac

# stub curl that "downloads" $SCRATCH/asset regardless of URL
serve() {  # file-to-serve
  cp "$1" "$SCRATCH/asset"
  cat > "$SCRATCH/bin/curl" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
d="$(cd "$(dirname "$0")/.." && pwd)"
cp "$d/asset" "$out"
EOF
  chmod +x "$SCRATCH/bin/curl"
}
no_serve() { rm -f "$SCRATCH/bin/curl"; }

run_ee() { PATH="$SCRATCH/bin:$PATH" /bin/bash "$ROOT/scripts/ensure-engine.sh" >/dev/null 2>&1; }

# ---- 1. good manifest + matching asset -> fetched, verified, installed -------------
serve "$BIN"
printf 'repo example/tmux-pane-minimize\nversion v0.0.0-test\nsha256 %s %s\n' "$TARGET" "$(sha_of "$BIN")" > "$MANIFEST"
run_ee
check "fetch installs the engine" test -x "$DATA_BIN"
check "fetch records the pinned version" test "$(cat "$VER_FILE" 2>/dev/null)" = "v0.0.0-test"
check "installed engine runs" "$DATA_BIN" --version

# ---- 2. version current -> no-op (no curl available; must not need it) -------------
no_serve
run_ee
check "matching pin is a no-op" test "$(cat "$VER_FILE" 2>/dev/null)" = "v0.0.0-test"

# ---- 3. tampered asset (sha mismatch) -> never installed ---------------------------
cp "$BIN" "$SCRATCH/tampered" && printf 'X' >> "$SCRATCH/tampered"
serve "$SCRATCH/tampered"
printf 'repo example/tmux-pane-minimize\nversion v0.0.1-test\nsha256 %s %s\n' "$TARGET" "$(sha_of "$BIN")" > "$MANIFEST"
run_ee   # fetch must reject; cargo fallback may legitimately rebuild from source
if cmp -s "$SCRATCH/tampered" "$DATA_BIN"; then
  bad "tampered download was installed despite sha256 mismatch"
else
  ok "tampered download rejected (sha256 mismatch)"
fi
check "no stray download temp files" test -z "$(find "$SCRATCH/data/tmux-pane-minimize" -name '.fetch.*' 2>/dev/null)"

# ---- 4. @minimize-engine-fetch off honoured / script always exits 0 ----------------
serve "$BIN"
printf 'repo example/tmux-pane-minimize\nversion v9.9.9-test\nsha256 %s deadbeef\n' "$TARGET" > "$MANIFEST"
if PATH="$SCRATCH/bin:$PATH" /bin/bash "$ROOT/scripts/ensure-engine.sh" >/dev/null 2>&1; then
  ok "ensure-engine exits 0 even when everything fails"
else
  bad "ensure-engine must always exit 0 (run-shell would dump into the pane)"
fi

restore_manifest
summary ensure_engine
