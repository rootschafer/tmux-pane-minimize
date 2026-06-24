#!/usr/bin/env bash
# tmux-pane-minimize — PURE layout-transform layer.
#
# This file contains ONLY the pure layout math: it has no tmux calls, no time, no
# randomness. `transform()` is a referentially-transparent function of
#   (layout, MINSET, SAVEDW, WPANE, WVAL, MINH)  [+ the MIN_H/MIN_W/BORDER_POS globals]
# which is exactly what makes the offline property suite exhaustive and deterministic.
#
# It is sourced by:
#   - scripts/tmux-min.sh    the tmux-IO layer (reads tmux state, calls transform, applies)
#   - tests/transform_props.sh   the offline property suite (drives transform directly)
#
# A "minimized" pane (MINSET membership) is pinned to MIN_H rows. Additionally, when
# EVERY pane in a vertically-stacked group is minimized, that whole group is shrunk to
# MIN_W columns and its horizontal neighbour widens to fill. Works for ARBITRARY nesting
# by rewriting the window layout tree directly, then re-serializing it for select-layout.
#
# No tmux command must ever run from this file (the word appears in comments only). Keep it pure.
set -u

# Defaults; the tmux-IO layer overrides these from @minimize-* options.
MIN_H="${MIN_H:-3}"          # comfortable minimized height (rows) when there's room
MIN_W="${MIN_W:-30}"         # width a fully-minimized column narrows to
ABS_MIN_H="${ABS_MIN_H:-1}"  # absolute floor: a minimized pane never shrinks below this
                             # (rows of content) when squeezed to fit a peek/expansion

# ---- layout tree (parallel arrays; node = index) ----
LS=""; POS=0; NN=0
declare -a NT NW NH NX NY NP NC WM FM
declare -a RC_SZ RC_FLEX RC_CID RC_FLOOR RC_MIN   # reconcile scratch (transient; copied to locals before recursion)
RC_N=0; RC_AVAIL=0
MINSET=" "          # " 1 4 7 " minimized pane numbers
SAVEDW=" "          # " 1:80 4:80 " pane-number:saved-width (pre-narrow widths)
MINH=" "            # " 1:5 4:8 " pane-number:custom minimized height (else global MIN_H)
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
  # Default NT to "leaf" up-front (like NC/NP default to ""). The if/elif below overrides it
  # for real splits; a leaf re-confirms it. This guarantees NT[$id] is ALWAYS set, so a cell
  # whose next char is neither ',' nor '{'/'[' (a malformed/edge layout, or one a different
  # tmux version emits unexpectedly) degrades to a leaf instead of leaving NT unset — which
  # `${NT[$id]}` then reads as an "unbound variable" CRASH under `set -u` on bash 4.4+/5.x
  # (bash 3.2 was lenient, which is why this hid for so long).
  NW[$id]=$w; NH[$id]=$h; NX[$id]=$x; NY[$id]=$y; NC[$id]=""; NP[$id]=""; NT[$id]="leaf"
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

# _minh_of: the minimized HEIGHT to pin node $1 at -> RET. A leaf with a per-pane
# custom height (@minimize_minh, carried in the MINH map) uses it; everything else
# (incl. non-leaf minimized blocks) falls back to the global MIN_H.
_minh_of() {
  local id=$1 n tmp
  RET=$MIN_H
  [ "${NT[$id]}" = "leaf" ] || return
  n=${NP[$id]}
  case "$MINH" in
    *" $n:"*) tmp="${MINH#* $n:}"; tmp="${tmp%% *}"; case "$tmp" in ''|*[!0-9]*) ;; *) RET=$tmp ;; esac ;;
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

# reconcile: force RC_SZ[0..RC_N-1] to sum EXACTLY to RC_AVAIL, each entry >= its RC_FLOOR.
# This is the safety net that guarantees a split's children always tile their parent no
# matter what the size logic produced (tiny window, stale @minimize_saved/_w, degenerate
# WVAL). Without it the engine can emit a layout whose children don't sum to the parent and
# tmux SILENTLY applies it — squishing a pane toward zero.
#
# Per child the size logic supplies RC_FLOOR[i] (its minimum) and RC_MIN[i] (1 = a minimized
# pane, which YIELDS first). Surplus goes to a flexible child. A deficit is shaved in tiers:
# minimized panes (down to their floor) first, then flexible panes, then anything above its
# floor, and only as a last resort below the floors — so a peek/expansion borrows space from
# minimized panes (toward ABS_MIN_H) before the working/peek panes give anything up.
# No-op when sizes already sum exactly. With RC_FLOOR=1 and RC_MIN=0 this is identical to the
# original flex-first/floor-1 behaviour (the non-peek and horizontal paths).
reconcile() {
  local i s delta best bi
  i=0; while [ "$i" -lt "$RC_N" ]; do [ "${RC_SZ[$i]}" -lt "${RC_FLOOR[$i]}" ] && RC_SZ[$i]=${RC_FLOOR[$i]}; i=$((i+1)); done
  s=0; i=0; while [ "$i" -lt "$RC_N" ]; do s=$(( s + RC_SZ[i] )); i=$((i+1)); done
  delta=$(( RC_AVAIL - s ))
  if [ "$delta" -gt 0 ]; then
    bi=-1; i=0; while [ "$i" -lt "$RC_N" ]; do [ "${RC_FLEX[$i]}" = 1 ] && bi=$i; i=$((i+1)); done
    [ "$bi" -lt 0 ] && bi=$(( RC_N - 1 ))
    RC_SZ[$bi]=$(( RC_SZ[bi] + delta ))
  elif [ "$delta" -lt 0 ]; then
    delta=$(( -delta ))
    while [ "$delta" -gt 0 ]; do
      best=0; bi=-1; i=0          # tier 1: tallest MINIMIZED pane above its floor (yield first)
      while [ "$i" -lt "$RC_N" ]; do
        if [ "${RC_MIN[$i]}" = 1 ] && [ "${RC_SZ[$i]}" -gt "${RC_FLOOR[$i]}" ] && [ "${RC_SZ[$i]}" -gt "$best" ]; then best=${RC_SZ[$i]}; bi=$i; fi
        i=$((i+1))
      done
      if [ "$bi" -lt 0 ]; then    # tier 2: tallest FLEX pane above its floor
        i=0; while [ "$i" -lt "$RC_N" ]; do
          if [ "${RC_FLEX[$i]}" = 1 ] && [ "${RC_SZ[$i]}" -gt "${RC_FLOOR[$i]}" ] && [ "${RC_SZ[$i]}" -gt "$best" ]; then best=${RC_SZ[$i]}; bi=$i; fi
          i=$((i+1))
        done
      fi
      if [ "$bi" -lt 0 ]; then    # tier 3: tallest of anything above its floor
        i=0; while [ "$i" -lt "$RC_N" ]; do
          if [ "${RC_SZ[$i]}" -gt "${RC_FLOOR[$i]}" ] && [ "${RC_SZ[$i]}" -gt "$best" ]; then best=${RC_SZ[$i]}; bi=$i; fi
          i=$((i+1))
        done
      fi
      if [ "$bi" -lt 0 ]; then    # last resort: tallest above 1, breaking floors (window can't fit n panes)
        i=0; while [ "$i" -lt "$RC_N" ]; do
          if [ "${RC_SZ[$i]}" -gt 1 ] && [ "${RC_SZ[$i]}" -gt "$best" ]; then best=${RC_SZ[$i]}; bi=$i; fi
          i=$((i+1))
        done
      fi
      [ "$bi" -lt 0 ] && break     # everything already at 1
      RC_SZ[$bi]=$(( RC_SZ[bi] - 1 )); delta=$(( delta - 1 ))
    done
  fi
}

recompute() {
  local id=$1 X=$2 Y=$3 W=$4 H=$5 ot=$6 ob=$7
  NX[$id]=$X; NY[$id]=$Y; NW[$id]=$W; NH[$id]=$H
  case "${NT[$id]}" in
    leaf) ;;
    h) _recompute_h "$id" "$X" "$Y" "$W" "$H" "$ot" "$ob" ;;
    v) _recompute_v "$id" "$X" "$Y" "$W" "$H" "$ot" "$ob" ;;
  esac
}

# _recompute_h: distribute WIDTH among a horizontal split's children; every child
# spans the full height H at row Y. (Body extracted from recompute's `h)` branch.)
_recompute_h() {
  local id=$1 X=$2 Y=$3 W=$4 H=$5 ot=$6 ob=$7
  local kids="${NC[$id]}" n avail c fw flexsum rest assigned last xx cw allfix fl i
  local -a hSZ hCID
  set -- $kids; n=$#
  avail=$(( W - (n - 1) ))
  flexsum=0; assigned=0; last=""
  for c in $kids; do
    _fixed_width "$c"; fw=$RET
    if [ "$fw" -ge 0 ]; then assigned=$(( assigned + fw ))
    else flexsum=$(( flexsum + NW[c] )); last=$c; fi
  done
  # If EVERY child is fixed-width (e.g. all columns fully minimized) there is no
  # flexible neighbour to absorb the freed width. Don't strand it: treat every
  # child as flexible and distribute the FULL row width proportionally by original
  # width, with the last child taking the remainder so the row sum stays exact.
  # (The old code reused `rest` = avail-fixed and had no remainder pane, so it
  # lost ~sum(MIN_W) columns -> a malformed layout tmux silently squished.)
  allfix=0
  if [ -z "$last" ]; then
    allfix=1; flexsum=0
    for c in $kids; do flexsum=$(( flexsum + NW[c] )); last=$c; done
    rest=$avail
  else
    rest=$(( avail - assigned )); [ "$rest" -lt 0 ] && rest=0
  fi
  [ "$flexsum" -le 0 ] && flexsum=1
  # collect each child's width + a "flexible" flag (fixed columns -> 0)
  assigned=0; i=0
  for c in $kids; do
    _fixed_width "$c"; fw=$RET
    if [ "$allfix" != 1 ] && [ "$fw" -ge 0 ]; then cw=$fw; fl=0
    elif [ "$c" = "$last" ]; then cw=$(( rest - assigned )); [ "$cw" -lt 1 ] && cw=1; fl=1
    else cw=$(( NW[c] * rest / flexsum )); [ "$cw" -lt 1 ] && cw=1; assigned=$(( assigned + cw )); fl=1; fi
    RC_SZ[$i]=$cw; RC_FLEX[$i]=$fl; RC_CID[$i]=$c; RC_FLOOR[$i]=1; RC_MIN[$i]=0; i=$((i+1))
  done
  RC_N=$n; RC_AVAIL=$avail; reconcile
  hSZ=( "${RC_SZ[@]}" ); hCID=( "${RC_CID[@]}" )   # copy out before recursion clobbers RC_*
  xx=$X; i=0
  while [ "$i" -lt "$n" ]; do
    recompute "${hCID[$i]}" "$xx" "$Y" "${hSZ[$i]}" "$H" "$ot" "$ob"
    xx=$(( xx + hSZ[i] + 1 )); i=$((i+1))
  done
}

# _recompute_v: distribute HEIGHT among a vertical split's children; every child
# spans the full width W at column X. This is where minimized panes get pinned to
# MIN_H and the un-minimize/peek restore pane to its saved height. (Body extracted
# from recompute's `v)` branch.)
_recompute_v() {
  local id=$1 X=$2 Y=$3 W=$4 H=$5 ot=$6 ob=$7
  local kids="${NC[$id]}" n i avail fixed fixmin wsum c weight hc rest assigned last yy wm otc obc allmin
  local rcount rtgt rfix isr first lastp cap rpresent fl eb fixf fill flo mn
  local -a vSZ vCID vOT vOB
  set -- $kids; n=$#
  avail=$(( H - (n - 1) ))
  wsum=0; for c in $kids; do wants_min "$c"; [ "$RET" = 0 ] && wsum=$((wsum+1)); done
  allmin=0; [ "$wsum" -eq 0 ] && allmin=1   # whole stack minimized: fill height proportionally
  # The "restore pane" (#{WPANE}, saved height WVAL) is the pane being
  # un-minimized or peeked. Pin it to its EXACT saved height (like minimized
  # panes are pinned to MIN_H) so it returns to its prior size instead of a
  # skewed proportional share — but only when another flexible pane exists to
  # absorb the remainder; otherwise it stays the flexible pane that fills.
  # pass 0: minimized comfortable-height sum (fixmin) and floor-height sum (fixf, each at
  # ABS_MIN_H + the same edge bonus), the minimized count (nmin), the count of genuine flex
  # panes (rcount), and whether the restore/peek pane is a direct child here (rpresent).
  fixmin=0; fixf=0; rcount=0; rpresent=0; i=0
  for c in $kids; do
    first=$([ $i -eq 0 ] && echo 1 || echo 0); lastp=$([ $i -eq $((n-1)) ] && echo 1 || echo 0)
    wants_min "$c"; wm=$RET; [ "$allmin" = 1 ] && wm=0
    if [ "$wm" = 1 ]; then
      _edge_bonus 1 "$first" "$lastp" "$ot" "$ob"; eb=$RET; _minh_of "$c"
      fixmin=$(( fixmin + RET + eb )); fixf=$(( fixf + ABS_MIN_H + eb ))
    elif [ "${NT[$c]}" = "leaf" ] && [ -n "$WPANE" ] && [ "${NP[$c]}" = "$WPANE" ] && [ "$WVAL" -gt 0 ]; then
      rpresent=1   # the restore pane is a direct child of THIS vertical node
    else rcount=$(( rcount + 1 )); fi
    i=$((i+1))
  done
  # The restore/peek pane (being un-minimized or focused) gets its saved height WVAL. It
  # takes that space from the MINIMIZED panes, which may shrink from their comfortable MIN_H
  # toward ABS_MIN_H — but no further: rtgt is capped so every minimized pane keeps at least
  # its floor (fixf in total) and every genuine flex/working pane keeps at least MIN_H. Past
  # that, the expansion just can't grow more. If it is the ONLY non-minimized pane here
  # (rcount=0) it also fills any space above the minimized panes' comfortable heights.
  # (rpresent guards against a sibling column reserving height for a pane that isn't in it.)
  rfix=0; rtgt=0
  if [ "$rpresent" = 1 ]; then
    rfix=1; rtgt=$WVAL; [ "$rtgt" -lt "$MIN_H" ] && rtgt=$MIN_H
    if [ "$rcount" -eq 0 ]; then fill=$(( avail - fixmin )); [ "$rtgt" -lt "$fill" ] && rtgt=$fill; fi
    cap=$(( avail - fixf - rcount * MIN_H ))                      # leave minimized at floor + flex at MIN_H
    [ "$cap" -lt "$MIN_H" ] && cap=$(( avail - fixf - rcount ))   # super tight: flex >=1 each
    [ "$rtgt" -gt "$cap" ] && rtgt=$cap
    [ "$rtgt" -lt 1 ] && rtgt=1
  fi
  fixed=$fixmin; [ "$rfix" = 1 ] && fixed=$(( fixed + rtgt ))
  # pass 1: flex weight sum (flex = non-min, and not the pinned restore pane)
  wsum=0; last=""; i=0
  for c in $kids; do
    wants_min "$c"; wm=$RET; [ "$allmin" = 1 ] && wm=0
    isr=0; [ "$rfix" = 1 ] && [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && [ "$wm" = 0 ] && isr=1
    if [ "$wm" != 1 ] && [ "$isr" != 1 ]; then
      weight=${NH[$c]}; [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && weight=$WVAL
      wsum=$(( wsum + weight )); last=$c
    fi
    i=$((i+1))
  done
  rest=$(( avail - fixed )); [ "$rest" -lt 0 ] && rest=0
  [ "$wsum" -le 0 ] && wsum=1
  # pass 2: collect each child's height + flex flag + floor + minimized flag, then reconcile.
  #  - minimized panes start at their comfortable height; their floor is ABS_MIN_H (+edge) and
  #    they are flagged RC_MIN=1 so reconcile shrinks THEM first to feed a peek (only in the
  #    peek case, rfix=1; otherwise floor stays 1 / RC_MIN=0 = original behaviour).
  #  - the restore/peek pane (isr) is pinned to rtgt; when it is the sole non-min pane it also
  #    absorbs surplus (fl=1) so it fills the column.
  #  - genuine flex/working panes get floor MIN_H in the peek case so they stay usable.
  assigned=0; i=0
  for c in $kids; do
    otc=0; obc=0; [ "$i" -eq 0 ] && otc=$ot; [ "$i" -eq $((n-1)) ] && obc=$ob
    first=$([ $i -eq 0 ] && echo 1 || echo 0); lastp=$([ $i -eq $((n-1)) ] && echo 1 || echo 0)
    wants_min "$c"; wm=$RET; [ "$allmin" = 1 ] && wm=0
    isr=0; [ "$rfix" = 1 ] && [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && [ "$wm" = 0 ] && isr=1
    flo=1; mn=0
    if [ "$wm" = 1 ]; then
      _edge_bonus 1 "$first" "$lastp" "$ot" "$ob"; eb=$RET; _minh_of "$c"; hc=$(( RET + eb )); fl=0
      if [ "$rfix" = 1 ]; then flo=$(( ABS_MIN_H + eb )); [ "$flo" -gt "$hc" ] && flo=$hc; mn=1; fi
    elif [ "$isr" = 1 ]; then hc=$rtgt; fl=0; [ "$rcount" -eq 0 ] && fl=1
    elif [ "$c" = "$last" ]; then hc=$(( rest - assigned )); [ "$hc" -lt 1 ] && hc=1; fl=1; [ "$rfix" = 1 ] && flo=$MIN_H
    else weight=${NH[$c]}; [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && weight=$WVAL
         hc=$(( weight * rest / wsum )); [ "$hc" -lt 1 ] && hc=1; assigned=$(( assigned + hc )); fl=1; [ "$rfix" = 1 ] && flo=$MIN_H; fi
    RC_SZ[$i]=$hc; RC_FLEX[$i]=$fl; RC_CID[$i]=$c; RC_FLOOR[$i]=$flo; RC_MIN[$i]=$mn; vOT[$i]=$otc; vOB[$i]=$obc
    i=$((i+1))
  done
  RC_N=$n; RC_AVAIL=$avail; reconcile
  vSZ=( "${RC_SZ[@]}" ); vCID=( "${RC_CID[@]}" )   # copy out before recursion clobbers RC_*
  yy=$Y; i=0
  while [ "$i" -lt "$n" ]; do
    recompute "${vCID[$i]}" "$X" "$yy" "$W" "${vSZ[$i]}" "${vOT[$i]}" "${vOB[$i]}"
    yy=$(( yy + vSZ[i] + 1 )); i=$((i+1))
  done
}

serialize() {
  local id=$1
  local s="${NW[$id]}x${NH[$id]},${NX[$id]},${NY[$id]}" c parts=""
  case "${NT[$id]}" in
    leaf) s="$s,${NP[$id]}" ;;
    h|v)  for c in ${NC[$id]}; do serialize "$c"; parts="$parts,$RET"; done
          parts="${parts#,}"
          if [ "${NT[$id]}" = "h" ]; then s="${s}{$parts}"; else s="${s}[$parts]"; fi ;;
  esac
  RET=$s
}

checksum() { local s="$1" cs=0 i ch code
  for ((i=0; i<${#s}; i++)); do ch="${s:i:1}"; printf -v code '%d' "'$ch"
    cs=$(( (cs >> 1) + ((cs & 1) << 15) )); cs=$(( (cs + code) & 0xffff )); done
  printf '%04x' "$cs"; }

transform() {
  local layout="$1"; MINSET="$2"; SAVEDW="${3:- }"; WPANE="${4:-}"; WVAL="${5:-0}"; MINH="${6:- }"
  LS="${layout#*,}"; POS=0; NN=0; NT=(); NW=(); NH=(); NX=(); NY=(); NP=(); NC=(); WM=(); FM=()
  parse_cell
  recompute 0 "${NX[0]}" "${NY[0]}" "${NW[0]}" "${NH[0]}" 1 1
  serialize 0; local geom=$RET
  echo "$(checksum "$geom"),$geom"
}
