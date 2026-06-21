#!/usr/bin/env bash
# tmux-pane-minimize engine.
#
# A "minimized" pane (per-pane option @minimize_active=1) is pinned to MIN_H rows.
# Works for ARBITRARY nesting by rewriting the window layout tree directly: every
# minimized pane's cell is forced to MIN_H and, within each vertical split, the
# remaining height is shared among the other children in proportion to their
# current heights. A pane that lives in a horizontal (side-by-side) split collapses
# its whole row, since heights are shared across a row. The result is applied with
# select-layout, so it is correct regardless of how panes are split or nested.
#
# Usage:
#   tmux-min toggle <pane_id>     toggle minimize state of <pane_id>
#   tmux-min repin  <window_id>   re-pin minimized panes (e.g. after a resize)
#   tmux-min selftest             offline layout-string transform check (no tmux)
set -u

# Minimized height is configurable via @minimize-height (default 3).
MIN_H=$(tmux show-option -gqv @minimize-height 2>/dev/null || true)
case "$MIN_H" in ''|*[!0-9]*) MIN_H=3 ;; esac

# ---- layout tree (parallel arrays; node = index) ----
LS=""; POS=0; NN=0
declare -a NT NW NH NX NY NP NC WM
MINSET=" "          # " 1 4 7 " space-delimited minimized pane numbers
WPANE=""; WVAL=0    # restore weight override
BORDER_POS=off      # pane-border-status: top|bottom|off (for the edge-row fix)
RINT=0; RET=0

_read_int() { RINT=""; local ch
  while [ "$POS" -lt "${#LS}" ]; do ch="${LS:$POS:1}"; case "$ch" in
    [0-9]) RINT="$RINT$ch"; POS=$((POS+1));; *) break;; esac
  done; }

parse_cell() {
  local id=$NN; NN=$((NN+1)); local w h x y ch
  _read_int; w=$RINT; POS=$((POS+1))
  _read_int; h=$RINT; POS=$((POS+1))
  _read_int; x=$RINT; POS=$((POS+1))
  _read_int; y=$RINT
  NW[$id]=$w; NH[$id]=$h; NX[$id]=$x; NY[$id]=$y; NC[$id]=""; NP[$id]=""
  ch="${LS:$POS:1}"
  if [ "$ch" = "," ]; then
    POS=$((POS+1)); _read_int; NP[$id]=$RINT; NT[$id]="leaf"
  elif [ "$ch" = "{" ] || [ "$ch" = "[" ]; then
    if [ "$ch" = "{" ]; then NT[$id]="h"; else NT[$id]="v"; fi
    POS=$((POS+1)); local kids="" cid
    while :; do
      parse_cell; cid=$RET; kids="$kids $cid"
      if [ "${LS:$POS:1}" = "," ]; then POS=$((POS+1)); else POS=$((POS+1)); break; fi
    done
    NC[$id]="$kids"
  fi
  RET=$id
}

# Does node want to collapse to MIN_H?  leaf: flagged. row(h): any child does.
# stack(v): only if all children do.
wants_min() {
  local id=$1 r c
  if [ "${WM[$id]:-x}" != "x" ]; then RET=${WM[$id]}; return; fi
  case "${NT[$id]}" in
    leaf) r=0; case "$MINSET" in *" ${NP[$id]} "*) r=1;; esac ;;
    h)    r=0; for c in ${NC[$id]}; do wants_min "$c"; [ "$RET" = 1 ] && r=1; done ;;
    v)    r=1; for c in ${NC[$id]}; do wants_min "$c"; [ "$RET" = 0 ] && r=0; done ;;
  esac
  WM[$id]=$r; RET=$r
}

# A minimized cell touching the window's border-status edge renders 1 row short
# (the status line overlays that row), so give it +1 there. ot/ob = does this
# node touch the window top/bottom edge.
_edge_bonus() {  # $1 wants_min(0/1)  $2 is_first  $3 is_last  $4 ot  $5 ob -> RET
  RET=0; [ "$1" = 1 ] || return
  [ "$4" = 1 ] && [ "$2" = 1 ] && [ "$BORDER_POS" = top ] && RET=$((RET+1))
  [ "$5" = 1 ] && [ "$3" = 1 ] && [ "$BORDER_POS" = bottom ] && RET=$((RET+1))
}

recompute() {
  local id=$1 H=$2 Y=$3 ot=$4 ob=$5
  NH[$id]=$H; NY[$id]=$Y
  case "${NT[$id]}" in
    leaf) ;;
    h) local c; for c in ${NC[$id]}; do recompute "$c" "$H" "$Y" "$ot" "$ob"; done ;;  # row spans full height -> same edges
    v) local kids="${NC[$id]}" n i avail fixed wsum c w hc rest assigned last yy wm bonus otc obc
       set -- $kids; n=$#
       avail=$(( H - (n - 1) ))
       fixed=0; wsum=0; last=""; i=0
       for c in $kids; do
         wants_min "$c"; wm=$RET
         if [ "$wm" = 1 ]; then
           _edge_bonus 1 "$([ $i -eq 0 ] && echo 1 || echo 0)" "$([ $i -eq $((n-1)) ] && echo 1 || echo 0)" "$ot" "$ob"
           fixed=$(( fixed + MIN_H + RET ))
         else w=${NH[$c]}; [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && w=$WVAL
              wsum=$(( wsum + w )); last=$c; fi
         i=$((i+1))
       done
       rest=$(( avail - fixed )); [ "$rest" -lt 0 ] && rest=0
       [ "$wsum" -le 0 ] && wsum=1
       assigned=0; yy=$Y; i=0
       for c in $kids; do
         otc=0; obc=0; [ "$i" -eq 0 ] && otc=$ot; [ "$i" -eq $((n-1)) ] && obc=$ob
         wants_min "$c"; wm=$RET
         if [ "$wm" = 1 ]; then
           _edge_bonus 1 "$([ $i -eq 0 ] && echo 1 || echo 0)" "$([ $i -eq $((n-1)) ] && echo 1 || echo 0)" "$ot" "$ob"
           hc=$(( MIN_H + RET ))
         elif [ "$c" = "$last" ]; then hc=$(( rest - assigned )); [ "$hc" -lt 1 ] && hc=1
         else w=${NH[$c]}; [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && w=$WVAL
              hc=$(( w * rest / wsum )); [ "$hc" -lt 1 ] && hc=1; assigned=$(( assigned + hc )); fi
         recompute "$c" "$hc" "$yy" "$otc" "$obc"; yy=$(( yy + hc + 1 ))
         i=$((i+1))
       done ;;
  esac
}

serialize() {
  local id=$1
  local s="${NW[$id]}x${NH[$id]},${NX[$id]},${NY[$id]}" c parts=""
  case "${NT[$id]}" in
    leaf) s="$s,${NP[$id]}" ;;
    h|v)  for c in ${NC[$id]}; do serialize "$c"; parts="$parts,$RET"; done
          parts="${parts#,}"
          if [ "${NT[$id]}" = "h" ]; then s="$s{$parts}"; else s="$s[$parts]"; fi ;;
  esac
  RET=$s
}

checksum() { local s="$1" cs=0 i ch code
  for ((i=0; i<${#s}; i++)); do ch="${s:i:1}"; printf -v code '%d' "'$ch"
    cs=$(( (cs >> 1) + ((cs & 1) << 15) )); cs=$(( (cs + code) & 0xffff )); done
  printf '%04x' "$cs"; }

transform() {
  local layout="$1"; MINSET="$2"; WPANE="${3:-}"; WVAL="${4:-0}"
  LS="${layout#*,}"; POS=0; NN=0; NT=(); NW=(); NH=(); NX=(); NY=(); NP=(); NC=(); WM=()
  parse_cell
  recompute 0 "${NH[0]}" "${NY[0]}" 1 1     # root touches both top & bottom edges
  serialize 0; local geom=$RET
  echo "$(checksum "$geom"),$geom"
}

apply() {
  local win="$1" wp="${2:-}" wv="${3:-0}" layout minset new
  BORDER_POS=$(tmux show-options -gqv pane-border-status 2>/dev/null || true)
  case "$BORDER_POS" in top|bottom) ;; *) BORDER_POS=off ;; esac
  layout=$(tmux display-message -p -t "$win" '#{window_layout}')
  minset=" $(tmux list-panes -t "$win" -F '#{?@minimize_active,#{pane_id},}' | tr -d '%' | tr '\n' ' ')"
  new=$(transform "$layout" "$minset" "$wp" "$wv")
  tmux select-layout -t "$win" "$new"
}

case "${1:-}" in
  toggle)
    pane="$2"; win=$(tmux display-message -p -t "$pane" '#{window_id}')
    num=$(tmux display-message -p -t "$pane" '#{pane_id}' | tr -d '%')
    tmux set-option -g @minimize_guard 1
    if [ "$(tmux display-message -p -t "$pane" '#{?@minimize_active,1,0}')" = 1 ]; then
      tmux set-option -t "$pane" -p @minimize_active 0
      saved=$(tmux display-message -p -t "$pane" '#{@minimize_saved}'); case "$saved" in ''|*[!0-9]*) saved=$MIN_H ;; esac
      apply "$win" "$num" "$saved"
    else
      tmux set-option -t "$pane" -p @minimize_saved "$(tmux display-message -p -t "$pane" '#{pane_height}')"
      tmux set-option -t "$pane" -p @minimize_active 1
      apply "$win"
    fi
    tmux set-option -gu @minimize_guard
    ;;
  repin)
    tmux set-option -g @minimize_guard 1; apply "$2"; tmux set-option -gu @minimize_guard ;;
  selftest)
    L='02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}'
    echo "in : $L"
    echo "out: $(transform "$L" ' 96 97 ')"
    echo "(expect 96 & 97 -> height 3, 98 absorbs, left pane 95 unchanged 127x67)" ;;
esac
