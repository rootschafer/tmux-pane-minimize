#!/usr/bin/env bash
# tmux-pane-minimize engine.
#
# A "minimized" pane (per-pane option @minimize_active=1) is pinned to MIN_H rows.
# Additionally, when EVERY pane in a vertically-stacked group (a vertical split) is
# minimized, that whole group is shrunk to MIN_W columns and its horizontal
# neighbour widens to fill — restoring any pane widens the group back.
#
# Works for ARBITRARY nesting by rewriting the window layout tree directly: heights
# are redistributed within vertical splits, widths within horizontal splits, then
# the result is applied atomically with select-layout.
#
# Usage:
#   tmux-min toggle <pane_id>     toggle minimize state of <pane_id>
#   tmux-min repin  <window_id>   re-pin minimized panes (e.g. after a resize)
#   tmux-min selftest             offline layout-string transform check (no tmux)
set -u

MIN_H=$(tmux show-option -gqv @minimize-height 2>/dev/null || true); case "$MIN_H" in ''|*[!0-9]*) MIN_H=3 ;; esac
MIN_W=$(tmux show-option -gqv @minimize-width  2>/dev/null || true); case "$MIN_W" in ''|*[!0-9]*) MIN_W=15 ;; esac

# ---- layout tree (parallel arrays; node = index) ----
LS=""; POS=0; NN=0
declare -a NT NW NH NX NY NP NC WM FM
MINSET=" "          # " 1 4 7 " minimized pane numbers
SAVEDW=" "          # " 1:80 4:80 " pane-number:saved-width (pre-narrow widths)
WPANE=""; WVAL=0    # height restore weight override
BORDER_POS=off
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

# wants_min: should this node collapse in HEIGHT? leaf flagged; row(h) any child;
# stack(v) all children. (Unchanged height semantics.)
wants_min() {
  local id=$1 r child
  if [ "${WM[$id]:-x}" != "x" ]; then RET=${WM[$id]}; return; fi
  case "${NT[$id]}" in
    leaf) r=0; case "$MINSET" in *" ${NP[$id]} "*) r=1;; esac ;;
    h)    r=0; for child in ${NC[$id]}; do wants_min "$child"; [ "$RET" = 1 ] && r=1; done ;;
    v)    r=1; for child in ${NC[$id]}; do wants_min "$child"; [ "$RET" = 0 ] && r=0; done ;;
  esac
  WM[$id]=$r; RET=$r
}

# fully_min: is EVERY leaf under this node minimized? (gate for width-narrowing)
fully_min() {
  local id=$1 r child
  if [ "${FM[$id]:-x}" != "x" ]; then RET=${FM[$id]}; return; fi
  case "${NT[$id]}" in
    leaf) r=0; case "$MINSET" in *" ${NP[$id]} "*) r=1;; esac ;;
    h|v)  r=1; for child in ${NC[$id]}; do fully_min "$child"; [ "$RET" = 0 ] && r=0; done ;;
  esac
  FM[$id]=$r; RET=$r
}

# _savedw_of: searches all leaves under node for a saved width
_savedw_of() {
  local id=$1 n tmp child
  case "${NT[$id]}" in
    leaf) n=${NP[$id]}; case "$SAVEDW" in *" $n:"*) tmp="${SAVEDW#* $n:}"; RET="${tmp%% *}";; *) RET="";; esac ;;
    *)    for child in ${NC[$id]}; do _savedw_of "$child"; [ -n "$RET" ] && return; done; RET="" ;;
  esac
}

_edge_bonus() {  # $1 wm  $2 first  $3 last  $4 ot  $5 ob -> RET
  RET=0; [ "$1" = 1 ] || return
  [ "$4" = 1 ] && [ "$2" = 1 ] && [ "$BORDER_POS" = top ] && RET=$((RET+1))
  [ "$5" = 1 ] && [ "$3" = 1 ] && [ "$BORDER_POS" = bottom ] && RET=$((RET+1))
}

# A node gets a FIXED width in a horizontal split when it is a vertical stack that
# is either fully minimized (-> MIN_W) or currently narrowed and being restored
# (-> its saved width). Returns RET=fixed-width, or -1 if the node is flexible.
_fixed_width() {
  local id=$1 sw
  [ "${NT[$id]}" = "v" ] || { RET=-1; return; }
  fully_min "$id"
  if [ "$RET" = 1 ]; then RET=$MIN_W; return; fi
  if [ "${NW[$id]}" -le $((MIN_W + 2)) ]; then
    _savedw_of "$id"; sw=$RET
    case "$sw" in ''|*[!0-9]*) ;; *) RET=$sw; return;; esac
  fi
  RET=-1
}

recompute() {
  local id=$1 X=$2 Y=$3 W=$4 H=$5 ot=$6 ob=$7
  NX[$id]=$X; NY[$id]=$Y; NW[$id]=$W; NH[$id]=$H
  case "${NT[$id]}" in
    leaf) ;;
    h) # distribute WIDTH; every child spans full height H at row Y.
       local kids="${NC[$id]}" n avail c fw flexsum rest assigned last xx cw
       set -- $kids; n=$#
       avail=$(( W - (n - 1) ))
       flexsum=0; assigned=0; last=""
       for c in $kids; do
         _fixed_width "$c"; fw=$RET
         if [ "$fw" -ge 0 ]; then assigned=$(( assigned + fw ))
         else flexsum=$(( flexsum + NW[c] )); last=$c; fi
       done
       rest=$(( avail - assigned )); [ "$rest" -lt 0 ] && rest=0
       [ -z "$last" ] && { flexsum=$avail; }   # all fixed: fall back to proportional over all
       [ "$flexsum" -le 0 ] && flexsum=1
       xx=$X; assigned=0
       for c in $kids; do
         _fixed_width "$c"; fw=$RET
         if [ "$fw" -ge 0 ] && [ -n "$last" ]; then cw=$fw
         elif [ "$c" = "$last" ]; then cw=$(( rest - assigned )); [ "$cw" -lt 1 ] && cw=1
         else cw=$(( NW[c] * rest / flexsum )); [ "$cw" -lt 1 ] && cw=1; assigned=$(( assigned + cw )); fi
         recompute "$c" "$xx" "$Y" "$cw" "$H" "$ot" "$ob"; xx=$(( xx + cw + 1 ))
       done ;;
    v) # distribute HEIGHT; every child spans full width W at column X.
       local kids="${NC[$id]}" n i avail fixed wsum c weight hc rest assigned last yy wm bonus otc obc allmin
       set -- $kids; n=$#
       avail=$(( H - (n - 1) ))
       wsum=0; for c in $kids; do wants_min "$c"; [ "$RET" = 0 ] && wsum=$((wsum+1)); done
       allmin=0; [ "$wsum" -eq 0 ] && allmin=1   # whole stack minimized: fill height proportionally
       fixed=0; wsum=0; last=""; i=0
       for c in $kids; do
         wants_min "$c"; wm=$RET; [ "$allmin" = 1 ] && wm=0
         if [ "$wm" = 1 ]; then
           _edge_bonus 1 "$([ $i -eq 0 ] && echo 1 || echo 0)" "$([ $i -eq $((n-1)) ] && echo 1 || echo 0)" "$ot" "$ob"
           fixed=$(( fixed + MIN_H + RET ))
         else weight=${NH[$c]}; [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && weight=$WVAL
              wsum=$(( wsum + weight )); last=$c; fi
         i=$((i+1))
       done
       rest=$(( avail - fixed )); [ "$rest" -lt 0 ] && rest=0
       [ "$wsum" -le 0 ] && wsum=1
       assigned=0; yy=$Y; i=0
       for c in $kids; do
         otc=0; obc=0; [ "$i" -eq 0 ] && otc=$ot; [ "$i" -eq $((n-1)) ] && obc=$ob
         wants_min "$c"; wm=$RET; [ "$allmin" = 1 ] && wm=0
         if [ "$wm" = 1 ]; then
           _edge_bonus 1 "$([ $i -eq 0 ] && echo 1 || echo 0)" "$([ $i -eq $((n-1)) ] && echo 1 || echo 0)" "$ot" "$ob"
           hc=$(( MIN_H + RET ))
         elif [ "$c" = "$last" ]; then hc=$(( rest - assigned )); [ "$hc" -lt 1 ] && hc=1
         else weight=${NH[$c]}; [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && weight=$WVAL
              hc=$(( weight * rest / wsum )); [ "$hc" -lt 1 ] && hc=1; assigned=$(( assigned + hc )); fi
         recompute "$c" "$X" "$yy" "$W" "$hc" "$otc" "$obc"; yy=$(( yy + hc + 1 ))
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
  local layout="$1"; MINSET="$2"; SAVEDW="${3:- }"; WPANE="${4:-}"; WVAL="${5:-0}"
  LS="${layout#*,}"; POS=0; NN=0; NT=(); NW=(); NH=(); NX=(); NY=(); NP=(); NC=(); WM=(); FM=()
  parse_cell
  recompute 0 "${NX[0]}" "${NY[0]}" "${NW[0]}" "${NH[0]}" 1 1
  serialize 0; local geom=$RET
  echo "$(checksum "$geom"),$geom"
}

apply() {
  local win="$1" wp="${2:-}" wv="${3:-0}" layout minset savedw new
  BORDER_POS=$(tmux show-options -gqv pane-border-status 2>/dev/null || true)
  case "$BORDER_POS" in top|bottom) ;; *) BORDER_POS=off ;; esac
  layout=$(tmux display-message -p -t "$win" '#{window_layout}')
  minset=" $(tmux list-panes -t "$win" -F '#{?@minimize_active,#{pane_id},}' | tr -d '%' | tr '\n' ' ')"
  savedw=" $(tmux list-panes -t "$win" -F '#{?@minimize_saved_w,#{pane_id}:#{@minimize_saved_w},}' | tr -d '%' | tr '\n' ' ')"
  new=$(transform "$layout" "$minset" "$savedw" "$wp" "$wv")
  tmux select-layout -t "$win" "$new"
}

toggle_pane() {
  local pane="$1" win num saved
  win=$(tmux display-message -p -t "$pane" '#{window_id}')
  num=$(tmux display-message -p -t "$pane" '#{pane_id}' | tr -d '%')
  tmux set-option -g @minimize_guard 1
  if [ "$(tmux display-message -p -t "$pane" '#{?@minimize_active,1,0}')" = 1 ]; then
    tmux set-option -t "$pane" -p @minimize_active 0
    saved=$(tmux display-message -p -t "$pane" '#{@minimize_saved}'); case "$saved" in ''|*[!0-9]*) saved=$MIN_H ;; esac
    apply "$win" "$num" "$saved"
  else
    tmux set-option -t "$pane" -p @minimize_saved   "$(tmux display-message -p -t "$pane" '#{pane_height}')"
    tmux set-option -t "$pane" -p @minimize_saved_w "$(tmux display-message -p -t "$pane" '#{pane_width}')"
    tmux set-option -t "$pane" -p @minimize_active 1
    apply "$win"
  fi
  tmux set-option -gu @minimize_guard
}

# handle_click <window_id> <mouse_x> <mouse_y>
# Toggle the pane whose marker hit-region — the right HIT_W columns of its
# pane-border-status line — contains the click. A minimized pane is always
# restored; a normal pane is minimized only when @minimize-button is "on" (so a
# stray border click can't collapse a pane when the button feature is disabled).
handle_click() {
  local win="$1" mx="$2" my="$3" bpos button HIT_W panes pid pl pt pw ph act row right lo target tact
  case "$mx" in ''|*[!0-9]*) return;; esac
  case "$my" in ''|*[!0-9]*) return;; esac
  bpos=$(tmux show-options -gqv pane-border-status 2>/dev/null || true)
  case "$bpos" in top|bottom) ;; *) return ;; esac   # no border line => no marker to click
  button=$(tmux show-options -gqv @minimize-button 2>/dev/null || true)
  HIT_W=3
  panes=$(tmux list-panes -t "$win" -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{?@minimize_active,1,0}')
  target=""; tact=0
  while read -r pid pl pt pw ph act; do
    [ -z "${pid:-}" ] && continue
    if [ "$bpos" = top ]; then row=$(( pt - 1 )); else row=$(( pt + ph )); fi
    [ "$my" -eq "$row" ] || continue
    right=$(( pl + pw - 1 )); lo=$(( right - HIT_W + 1 ))
    [ "$mx" -ge "$lo" ] && [ "$mx" -le "$right" ] || continue
    target="$pid"; tact="$act"; break
  done <<< "$panes"
  [ -z "$target" ] && return
  if [ "$tact" = 1 ]; then toggle_pane "$target"
  elif [ "$button" = "on" ]; then toggle_pane "$target"; fi
}

case "${1:-}" in
  toggle) toggle_pane "$2" ;;
  click)  handle_click "$2" "${3:-}" "${4:-}" ;;
  repin)
    tmux set-option -g @minimize_guard 1; apply "$2"; tmux set-option -gu @minimize_guard ;;
  selftest)
    L='02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}'
    echo "in : $L"
    echo "height-only (96,97 min, 98 not -> 96/97=3, 95 untouched):"
    echo "  $(transform "$L" ' 96 97 ')"
    echo "full stack min (96,98,97 all min -> right column narrows to MIN_W=$MIN_W, 95 widens):"
    echo "  $(transform "$L" ' 96 98 97 ')" ;;
esac
