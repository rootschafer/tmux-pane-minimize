#!/usr/bin/env bash
# Deterministic layout generator. PURE — no tmux, no RNG, no time.
#
# Emits one line per (tree-shape x window-size):
#     <cs,geom>\t<space-separated leaf pane-nums>
# e.g.
#     2b8c,80x24,0,0{...}\t 1 2 3
#
# The transform() under test strips and recomputes the checksum, so the leading
# checksum only needs to be present (comma-delimited). We compute the REAL one
# anyway (al_checksum) so generated layouts are also valid to feed a live tmux
# select-layout in the live suite.
#
# Shapes are written in a tiny prefix DSL:
#   L            a leaf
#   h <k> c1..ck  a horizontal split of k children (side by side)
#   v <k> c1..ck  a vertical   split of k children (stacked)
# children may themselves be L / h / v (one level of nesting is covered).
#
# Bash 3.2 compatible.

set -u
GEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$GEN_DIR/assert_layout.sh"   # for al_checksum

# All trees of 1-4 leaves: leaf, 2/3/4-way h & v splits, and one level of nesting
# (a column beside a 2/3-stack — the exact zero-height bug shape — and friends).
SHAPES='L
h 2 L L
v 2 L L
h 3 L L L
v 3 L L L
h 4 L L L L
v 4 L L L L
h 2 L v 2 L L
v 2 L h 2 L L
h 2 v 2 L L L
v 2 h 2 L L L
h 2 L v 3 L L L
h 2 v 2 L L v 2 L L
v 2 h 2 L L h 2 L L'

# Window sizes: small, medium, large.
SIZES='24 8
80 24
222 61'

# --- recursive builder over the token array SH[] (index SHI), pane counter PID ---
declare -a SH
SHI=0
PID=0
BRET=""        # built substring
BLEAVES=""     # accumulated leaf pane-nums for the whole tree

# build W H X Y  -> sets BRET to the node substring, advances SHI/PID
build() {
  local w=$1 h=$2 x=$3 y=$4
  local tok k i avail each cw ch cx cy parts
  tok="${SH[$SHI]}"; SHI=$((SHI + 1))
  case "$tok" in
    L)
      PID=$((PID + 1))
      BLEAVES="$BLEAVES $PID"
      BRET="${w}x${h},${x},${y},${PID}"
      ;;
    h)
      k="${SH[$SHI]}"; SHI=$((SHI + 1))
      avail=$((w - (k - 1)))
      each=$((avail / k))
      [ "$each" -lt 1 ] && each=1
      cx=$x; parts=""; i=0
      while [ "$i" -lt "$k" ]; do
        if [ "$i" -eq $((k - 1)) ]; then cw=$((x + w - cx)); else cw=$each; fi
        [ "$cw" -lt 1 ] && cw=1
        build "$cw" "$h" "$cx" "$y"
        parts="$parts,$BRET"
        cx=$((cx + cw + 1))
        i=$((i + 1))
      done
      BRET="${w}x${h},${x},${y}{${parts#,}}"
      ;;
    v)
      k="${SH[$SHI]}"; SHI=$((SHI + 1))
      avail=$((h - (k - 1)))
      each=$((avail / k))
      [ "$each" -lt 1 ] && each=1
      cy=$y; parts=""; i=0
      while [ "$i" -lt "$k" ]; do
        if [ "$i" -eq $((k - 1)) ]; then ch=$((y + h - cy)); else ch=$each; fi
        [ "$ch" -lt 1 ] && ch=1
        build "$w" "$ch" "$x" "$cy"
        parts="$parts,$BRET"
        cy=$((cy + ch + 1))
        i=$((i + 1))
      done
      BRET="${w}x${h},${x},${y}[${parts#,}]"
      ;;
  esac
}

gen_one() {
  local shape="$1" W="$2" H="$3" geom cs
  # shellcheck disable=SC2206
  SH=($shape)
  SHI=0; PID=0; BLEAVES=""
  build "$W" "$H" 0 0
  geom="$BRET"
  cs=$(al_checksum "$geom")
  printf '%s,%s\t%s\n' "$cs" "$geom" "$BLEAVES"
}

main() {
  local shape w h
  printf '%s\n' "$SHAPES" | while IFS= read -r shape; do
    [ -z "$shape" ] && continue
    printf '%s\n' "$SIZES" | while read -r w h; do
      [ -z "$w" ] && continue
      gen_one "$shape" "$w" "$h"
    done
  done
}

main
