# shellcheck shell=bash
# Invariant checker for tmux layout strings. PURE — no tmux, no RNG, no time.
#
# This is an INDEPENDENT re-implementation of the layout parser (al_* prefix) so
# that a bug in the engine's own parser cannot mask itself: the engine produces a
# layout, this checker re-parses it from scratch and validates the geometry.
#
# A layout string is "<cs>,<geom>" where <geom> is a node:
#   leaf:    WxH,X,Y,<pane-id>
#   h-split: WxH,X,Y{child,child,...}   children side by side  (widths sum)
#   v-split: WxH,X,Y[child,child,...]   children stacked       (heights sum)
#
# check_layout "<cs,geom>"  -> returns 0 if all invariants hold, else 1 with
#                              the violation in $AL_ERR.
#
# Invariants enforced (these are what the zero-height bug violates):
#   - every box has W>=1 and H>=1            (FAIL LOUDLY on any 0)
#   - h-split: sum(child W) + (n-1) == W; every child H==node H, Y==node Y,
#              and children are contiguous left-to-right
#   - v-split: sum(child H) + (n-1) == H; every child W==node W, X==node X,
#              and children are contiguous top-to-bottom
#   - the leading checksum equals the tmux checksum recomputed over <geom>
#
# Bash 3.2 compatible.

AL_S=""
AL_P=0
AL_ERR=""
AL_NW=0
AL_NH=0
AL_NX=0
AL_NY=0
AL_RET=""

# tmux layout checksum (independent copy of the documented algorithm).
al_checksum() {
  local s="$1" cs=0 i ch code
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    printf -v code '%d' "'$ch"
    cs=$(((cs >> 1) + ((cs & 1) << 15)))
    cs=$(((cs + code) & 0xffff))
  done
  printf '%04x' "$cs"
}

al_readint() {
  local n="" ch
  while [ "$AL_P" -lt "${#AL_S}" ]; do
    ch="${AL_S:$AL_P:1}"
    case "$ch" in
      [0-9]) n="$n$ch"; AL_P=$((AL_P + 1)) ;;
      *) break ;;
    esac
  done
  AL_RET="$n"
}

# Parse one node at AL_P; validate it; leave its box in AL_NW/AL_NH/AL_NX/AL_NY.
# Returns 1 (and sets AL_ERR) on the first violation.
al_node() {
  local w h x y ch kind
  local sumw sumh n cx cy expect

  al_readint; w=$AL_RET; AL_P=$((AL_P + 1))   # skip 'x'
  al_readint; h=$AL_RET; AL_P=$((AL_P + 1))   # skip ','
  al_readint; x=$AL_RET; AL_P=$((AL_P + 1))   # skip ','
  al_readint; y=$AL_RET

  case "$w" in ''|*[!0-9]*) AL_ERR="bad width token near '${AL_S:$AL_P:12}'"; return 1 ;; esac
  case "$h" in ''|*[!0-9]*) AL_ERR="bad height token near '${AL_S:$AL_P:12}'"; return 1 ;; esac
  if [ "$w" -lt 1 ]; then AL_ERR="width<1 in box ${w}x${h},${x},${y}"; return 1; fi
  if [ "$h" -lt 1 ]; then AL_ERR="height<1 in box ${w}x${h},${x},${y}"; return 1; fi

  ch="${AL_S:$AL_P:1}"
  if [ "$ch" = "," ]; then
    # leaf: consume ,<pane-id>
    AL_P=$((AL_P + 1))
    al_readint
    AL_NW=$w; AL_NH=$h; AL_NX=$x; AL_NY=$y
    return 0
  fi

  if [ "$ch" != "{" ] && [ "$ch" != "[" ]; then
    AL_ERR="expected ','/'{'/'[' after box ${w}x${h},${x},${y}, got '${ch}'"
    return 1
  fi

  if [ "$ch" = "{" ]; then kind=h; else kind=v; fi
  AL_P=$((AL_P + 1))
  sumw=0; sumh=0; n=0; cx=$x; cy=$y
  while :; do
    al_node || return 1
    n=$((n + 1))
    if [ "$kind" = h ]; then
      if [ "$AL_NH" != "$h" ]; then AL_ERR="h-split child H=$AL_NH != node H=$h (box ${w}x${h},${x},${y})"; return 1; fi
      if [ "$AL_NY" != "$y" ]; then AL_ERR="h-split child Y=$AL_NY != node Y=$y"; return 1; fi
      if [ "$AL_NX" != "$cx" ]; then AL_ERR="h-split child X=$AL_NX not contiguous (expected $cx)"; return 1; fi
      sumw=$((sumw + AL_NW)); cx=$((cx + AL_NW + 1))
    else
      if [ "$AL_NW" != "$w" ]; then AL_ERR="v-split child W=$AL_NW != node W=$w (box ${w}x${h},${x},${y})"; return 1; fi
      if [ "$AL_NX" != "$x" ]; then AL_ERR="v-split child X=$AL_NX != node X=$x"; return 1; fi
      if [ "$AL_NY" != "$cy" ]; then AL_ERR="v-split child Y=$AL_NY not contiguous (expected $cy)"; return 1; fi
      sumh=$((sumh + AL_NH)); cy=$((cy + AL_NH + 1))
    fi
    ch="${AL_S:$AL_P:1}"
    if [ "$ch" = "," ]; then AL_P=$((AL_P + 1)); else AL_P=$((AL_P + 1)); break; fi  # consume close brace
  done

  if [ "$kind" = h ]; then
    expect=$((sumw + (n - 1)))
    if [ "$expect" != "$w" ]; then AL_ERR="h-split sum(child W)+borders=$expect != node W=$w (box ${w}x${h},${x},${y})"; return 1; fi
  else
    expect=$((sumh + (n - 1)))
    if [ "$expect" != "$h" ]; then AL_ERR="v-split sum(child H)+borders=$expect != node H=$h (box ${w}x${h},${x},${y})"; return 1; fi
  fi
  AL_NW=$w; AL_NH=$h; AL_NX=$x; AL_NY=$y
  return 0
}

# check_layout "<cs,geom>"
check_layout() {
  local full="$1" cs geom recs
  AL_ERR=""
  case "$full" in
    *,*) ;;
    *) AL_ERR="no checksum/comma in '$full'"; return 1 ;;
  esac
  cs="${full%%,*}"
  geom="${full#*,}"

  AL_S="$geom"; AL_P=0
  al_node || return 1
  if [ "$AL_P" -ne "${#AL_S}" ]; then
    AL_ERR="trailing garbage at offset $AL_P: '${AL_S:$AL_P:20}'"
    return 1
  fi

  recs=$(al_checksum "$geom")
  if [ "$recs" != "$cs" ]; then
    AL_ERR="checksum mismatch: header=$cs recomputed=$recs"
    return 1
  fi
  return 0
}

# Allow standalone use: bash assert_layout.sh '<layout>'
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "usage: assert_layout.sh '<cs,geom>'" >&2
    exit 2
  fi
  if check_layout "$1"; then
    echo "OK: $1"
    exit 0
  else
    echo "VIOLATION: $AL_ERR" >&2
    echo "  in: $1" >&2
    exit 1
  fi
fi
