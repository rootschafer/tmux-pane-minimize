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

# Read both size options in ONE tmux round-trip (this runs on every engine invocation).
IFS='|' read -r MIN_H MIN_W <<<"$(tmux display-message -p '#{@minimize-height}|#{@minimize-width}' 2>/dev/null || true)"
case "$MIN_H" in ''|*[!0-9]*) MIN_H=3 ;; esac
case "$MIN_W" in ''|*[!0-9]*) MIN_W=30 ;; esac

# ---- layout tree (parallel arrays; node = index) ----
LS=""; POS=0; NN=0
declare -a NT NW NH NX NY NP NC WM FM
declare -a RC_SZ RC_FLEX RC_CID   # reconcile scratch (transient; copied to locals before recursion)
RC_N=0; RC_AVAIL=0
MINSET=" "          # " 1 4 7 " minimized pane numbers
SAVEDW=" "          # " 1:80 4:80 " pane-number:saved-width (pre-narrow widths)
MINH=" "            # " 1:5 4:8 " pane-number:custom minimized height (else global MIN_H)
WPANE=""; WVAL=0    # height restore weight override
BORDER_POS=off
RINT=0; RET=0

# ---- per-window mutex (atomic mkdir; portable — macOS has no flock) ----
# The focus/resize hooks invoke this engine with `run-shell -b`, so several copies
# can run at once. The old single global @minimize_guard was a check-then-set with a
# TOCTOU window, so concurrent peekin/peekout could both read guard=0 and apply
# conflicting layouts (verified: 47 overlapping applies under a focus ping-pong).
# An mkdir lock actually serializes them. A stale lock from a *dead* holder is
# reclaimed immediately via its recorded PID; a last-resort safety valve proceeds
# anyway after ~20s so an alive-but-wedged holder can never hang a keystroke forever
# (reconcile keeps even an unlucky concurrent apply well-formed regardless).
LOCKDIR=""
_lock() {
  local key d holder tmp n=0
  key=$(printf '%s' "${1:-global}" | tr -c 'A-Za-z0-9' '_')
  d="${TMPDIR:-/tmp}/tmux-min-$key.lock"
  while ! mkdir "$d" 2>/dev/null; do
    holder=$(cat "$d/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      # dead holder: capture the stale dir by ATOMIC rename (only one racer wins) then
      # drop it. rename — not a bare rmdir — so we can't delete a dir another racer
      # has just freshly re-acquired.
      tmp="$d.stale.$$.$n"
      mv "$d" "$tmp" 2>/dev/null && rm -rf "$tmp" 2>/dev/null
      continue
    fi
    n=$((n + 1)); [ "$n" -ge 1000 ] && break                         # ~20s last-resort valve
    sleep 0.02
  done
  # Publish our PID ATOMICALLY (write temp + rename) so a concurrent reader can never
  # see a partial/garbage value and mistake a live holder for a dead one.
  printf '%s' "$$" > "$d/.pid.$$" 2>/dev/null && mv -f "$d/.pid.$$" "$d/pid" 2>/dev/null
  LOCKDIR="$d"
}
_unlock() { [ -n "${LOCKDIR:-}" ] && rm -rf "$LOCKDIR" 2>/dev/null; LOCKDIR=""; }
trap _unlock EXIT

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

# reconcile: force RC_SZ[0..RC_N-1] to sum EXACTLY to RC_AVAIL with every entry >=1.
# This is the safety net that guarantees a split's children always tile their parent
# no matter what the size logic produced (tiny window where MIN_H/MIN_W can't fit,
# a stale @minimize_saved/_w larger than the now-smaller window, a degenerate WVAL).
# Without it the engine can emit a layout whose children don't sum to the parent, and
# tmux SILENTLY applies it — squishing a pane toward zero. Surplus goes to a flexible
# child; a deficit is shaved off the tallest (flexible first) so minimized panes keep
# MIN_H whenever the window can afford it. No-op when sizes already sum exactly.
reconcile() {
  local i s delta best bi
  i=0; while [ "$i" -lt "$RC_N" ]; do [ "${RC_SZ[$i]}" -lt 1 ] && RC_SZ[$i]=1; i=$((i+1)); done
  s=0; i=0; while [ "$i" -lt "$RC_N" ]; do s=$(( s + RC_SZ[i] )); i=$((i+1)); done
  delta=$(( RC_AVAIL - s ))
  if [ "$delta" -gt 0 ]; then
    bi=-1; i=0; while [ "$i" -lt "$RC_N" ]; do [ "${RC_FLEX[$i]}" = 1 ] && bi=$i; i=$((i+1)); done
    [ "$bi" -lt 0 ] && bi=$(( RC_N - 1 ))
    RC_SZ[$bi]=$(( RC_SZ[bi] + delta ))
  elif [ "$delta" -lt 0 ]; then
    delta=$(( -delta ))
    while [ "$delta" -gt 0 ]; do
      best=0; bi=-1; i=0          # prefer the tallest FLEX child >1
      while [ "$i" -lt "$RC_N" ]; do
        if [ "${RC_FLEX[$i]}" = 1 ] && [ "${RC_SZ[$i]}" -gt 1 ] && [ "${RC_SZ[$i]}" -gt "$best" ]; then best=${RC_SZ[$i]}; bi=$i; fi
        i=$((i+1))
      done
      if [ "$bi" -lt 0 ]; then    # none flexible left; shave the tallest fixed child >1
        i=0; while [ "$i" -lt "$RC_N" ]; do
          if [ "${RC_SZ[$i]}" -gt 1 ] && [ "${RC_SZ[$i]}" -gt "$best" ]; then best=${RC_SZ[$i]}; bi=$i; fi
          i=$((i+1))
        done
      fi
      [ "$bi" -lt 0 ] && break     # everything already at 1: window can't fit n panes
      RC_SZ[$bi]=$(( RC_SZ[bi] - 1 )); delta=$(( delta - 1 ))
    done
  fi
}

recompute() {
  local id=$1 X=$2 Y=$3 W=$4 H=$5 ot=$6 ob=$7
  NX[$id]=$X; NY[$id]=$Y; NW[$id]=$W; NH[$id]=$H
  case "${NT[$id]}" in
    leaf) ;;
    h) # distribute WIDTH; every child spans full height H at row Y.
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
         RC_SZ[$i]=$cw; RC_FLEX[$i]=$fl; RC_CID[$i]=$c; i=$((i+1))
       done
       RC_N=$n; RC_AVAIL=$avail; reconcile
       hSZ=( "${RC_SZ[@]}" ); hCID=( "${RC_CID[@]}" )   # copy out before recursion clobbers RC_*
       xx=$X; i=0
       while [ "$i" -lt "$n" ]; do
         recompute "${hCID[$i]}" "$xx" "$Y" "${hSZ[$i]}" "$H" "$ot" "$ob"
         xx=$(( xx + hSZ[i] + 1 )); i=$((i+1))
       done ;;
    v) # distribute HEIGHT; every child spans full width W at column X.
       local kids="${NC[$id]}" n i avail fixed fixmin wsum c weight hc rest assigned last yy wm otc obc allmin
       local rcount rtgt rfix isr first lastp cap rpresent fl eb
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
       # pass 0: minimized fixed height (fixmin) and count of other flex panes.
       fixmin=0; rcount=0; rpresent=0; i=0
       for c in $kids; do
         first=$([ $i -eq 0 ] && echo 1 || echo 0); lastp=$([ $i -eq $((n-1)) ] && echo 1 || echo 0)
         wants_min "$c"; wm=$RET; [ "$allmin" = 1 ] && wm=0
         if [ "$wm" = 1 ]; then
           _edge_bonus 1 "$first" "$lastp" "$ot" "$ob"; eb=$RET; _minh_of "$c"; fixmin=$(( fixmin + RET + eb ))
         elif [ "${NT[$c]}" = "leaf" ] && [ -n "$WPANE" ] && [ "${NP[$c]}" = "$WPANE" ] && [ "$WVAL" -gt 0 ]; then
           rpresent=1   # the restore pane is a direct child of THIS vertical node
         else rcount=$(( rcount + 1 )); fi
         i=$((i+1))
       done
       # Pin the restore pane to its saved height only when it is actually in this node
       # AND another flex pane can absorb the freed space. (rpresent guards against a
       # sibling column reserving height for a restore pane that isn't in it.)
       rfix=0; rtgt=0
       if [ "$rpresent" = 1 ] && [ "$rcount" -ge 1 ]; then
         rfix=1; rtgt=$WVAL; [ "$rtgt" -lt "$MIN_H" ] && rtgt=$MIN_H
         cap=$(( avail - fixmin - rcount )); [ "$rtgt" -gt "$cap" ] && rtgt=$cap   # leave >=1 per flex pane
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
       # pass 2: collect each child's height + flex flag + edge flags, then reconcile.
       # flex (fl=1) = proportional pane; minimized + pinned-restore panes are fl=0 so
       # reconcile preserves their MIN_H / saved height unless the window can't afford it.
       assigned=0; i=0
       for c in $kids; do
         otc=0; obc=0; [ "$i" -eq 0 ] && otc=$ot; [ "$i" -eq $((n-1)) ] && obc=$ob
         first=$([ $i -eq 0 ] && echo 1 || echo 0); lastp=$([ $i -eq $((n-1)) ] && echo 1 || echo 0)
         wants_min "$c"; wm=$RET; [ "$allmin" = 1 ] && wm=0
         isr=0; [ "$rfix" = 1 ] && [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && [ "$wm" = 0 ] && isr=1
         if [ "$wm" = 1 ]; then
           _edge_bonus 1 "$first" "$lastp" "$ot" "$ob"; eb=$RET; _minh_of "$c"; hc=$(( RET + eb )); fl=0
         elif [ "$isr" = 1 ]; then hc=$rtgt; fl=0
         elif [ "$c" = "$last" ]; then hc=$(( rest - assigned )); [ "$hc" -lt 1 ] && hc=1; fl=1
         else weight=${NH[$c]}; [ "${NT[$c]}" = "leaf" ] && [ "${NP[$c]}" = "$WPANE" ] && weight=$WVAL
              hc=$(( weight * rest / wsum )); [ "$hc" -lt 1 ] && hc=1; assigned=$(( assigned + hc )); fl=1; fi
         RC_SZ[$i]=$hc; RC_FLEX[$i]=$fl; RC_CID[$i]=$c; vOT[$i]=$otc; vOB[$i]=$obc
         i=$((i+1))
       done
       RC_N=$n; RC_AVAIL=$avail; reconcile
       vSZ=( "${RC_SZ[@]}" ); vCID=( "${RC_CID[@]}" )   # copy out before recursion clobbers RC_*
       yy=$Y; i=0
       while [ "$i" -lt "$n" ]; do
         recompute "${vCID[$i]}" "$X" "$yy" "$W" "${vSZ[$i]}" "${vOT[$i]}" "${vOB[$i]}"
         yy=$(( yy + vSZ[i] + 1 )); i=$((i+1))
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

# apply reads everything it needs in ONE tmux invocation (border + layout + per-pane
# state, chained with `\;`) and writes in one — instead of ~6 separate fork+exec+server
# round-trips. It also sets/clears @minimize_guard itself (chained into the same read
# and write calls), so callers don't pay extra round-trips for guarding. The guard
# suppresses the after-resize-pane hook during our own select-layout; chaining the unset
# onto select-layout keeps the suppression window as tight as possible.
apply() {
  local win="$1" wp="${2:-}" wv="${3:-0}" out new rid
  local n=0 f1 f2 f3 f4 f5 f6 zoomed layout minset=" " savedw=" " minh=" " actpane="" actmin=0
  out=$(tmux set-option -g @minimize_guard 1 \; \
        display-message -p -t "$win" '#{window_zoomed_flag}|#{pane-border-status}|#{window_layout}' \; \
        list-panes -t "$win" -F '#{pane_id}|#{?@minimize_active,1,0}|#{?@minimize_peek,1,0}|#{@minimize_saved_w}|#{@minimize_minh}|#{pane_active}')
  while IFS='|' read -r f1 f2 f3 f4 f5 f6; do
    n=$((n + 1))
    if [ "$n" = 1 ]; then zoomed=$f1; BORDER_POS=$f2; layout=$f3; continue; fi
    [ -z "$f1" ] && continue
    rid=$f1; f1=${f1#%}
    [ "$f2" = 1 ] && [ "$f3" != 1 ] && minset="$minset$f1 "
    [ -n "$f4" ] && savedw="$savedw$f1:$f4 "
    [ -n "$f5" ] && minh="$minh$f1:$f5 "
    if [ "$f6" = 1 ]; then actpane=$rid; { [ "$f2" = 1 ] && [ "$f3" != 1 ]; } && actmin=1; fi
  done <<EOF
$out
EOF
  case "$BORDER_POS" in top|bottom) ;; *) BORDER_POS=off ;; esac
  new=$(transform "$layout" "$minset" "$savedw" "$wp" "$wv" "$minh")
  tmux select-layout -t "$win" "$new" \; set-option -gu @minimize_guard
  # select-layout un-zooms the window. Preserve zoom (so a repin from a terminal resize,
  # or minimizing a background pane, doesn't kick you out of a zoom) — unless the active
  # pane itself just got minimized, where staying unzoomed is correct.
  [ "$zoomed" = 1 ] && [ "$actmin" != 1 ] && [ -n "$actpane" ] && tmux resize-pane -Z -t "$actpane"
}

toggle_pane() {
  local pane="$1" win num active saved h w
  IFS='|' read -r win num active saved h w <<<"$(tmux display-message -p -t "$pane" \
    '#{window_id}|#{pane_id}|#{?@minimize_active,1,0}|#{@minimize_saved}|#{pane_height}|#{pane_width}')"
  num=${num#%}
  _lock "$win"
  if [ "$active" = 1 ]; then
    case "$saved" in ''|*[!0-9]*) saved=$MIN_H ;; esac
    tmux set-option -t "$pane" -p @minimize_active 0 \; \
         set-option -t "$pane" -pu @minimize_peek \; \
         set-option -t "$pane" -pu @minimize_minh        # custom min height is per-session
    apply "$win" "$num" "$saved"
  else
    tmux set-option -t "$pane" -p @minimize_saved "$h" \; \
         set-option -t "$pane" -p @minimize_saved_w "$w" \; \
         set-option -t "$pane" -p @minimize_active 1
    apply "$win"
  fi
  _unlock
}

# peekin/peekout serialize on the window lock, then RE-CHECK live state so the result
# matches reality regardless of which queued hook wins the lock: only peek a pane that
# is still minimized, not already peeking, AND currently the active pane; only collapse
# a pane that is peeking and no longer active. This makes a rapid focus ping-pong
# converge deterministically to the final-focus state instead of a last-writer race.
peekin() {
  local pane="$1" win="${2:-}" num active peek pa saved
  [ -z "$win" ] && win=$(tmux display-message -p -t "$pane" '#{window_id}')
  _lock "$win"
  IFS='|' read -r active peek pa num saved <<<"$(tmux display-message -p -t "$pane" \
    '#{?@minimize_active,1,0}|#{?@minimize_peek,1,0}|#{pane_active}|#{pane_id}|#{@minimize_saved}')"
  if [ "$active" = 1 ] && [ "$peek" != 1 ] && [ "$pa" = 1 ]; then
    num=${num#%}
    case "$saved" in ''|*[!0-9]*) saved=$MIN_H ;; esac
    tmux set-option -t "$pane" -p @minimize_peek 1
    apply "$win" "$num" "$saved"
  fi
  _unlock
}

peekout() {
  local pane="$1" win="${2:-}" peek pa
  [ -z "$win" ] && win=$(tmux display-message -p -t "$pane" '#{window_id}')
  _lock "$win"
  IFS='|' read -r peek pa <<<"$(tmux display-message -p -t "$pane" '#{?@minimize_peek,1,0}|#{pane_active}')"
  if [ "$peek" = 1 ] && [ "$pa" != 1 ]; then
    tmux set-option -t "$pane" -pu @minimize_peek
    apply "$win"
  fi
  _unlock
}

# dragend: handle a mouse border-drag release for a whole window. For each pane:
#  - peeking pane resized        -> remember the new height as its saved/peek height
#  - NON-active minimized pane    -> that dragged height becomes its custom minimized
#    height (@minimize_minh); does NOT un-minimize it.
# We compare against the pane's current effective min height with a 1-row tolerance so
# the border-status edge nibble and untouched panes don't trigger a spurious update.
dragend() {
  local win="$1" id a h p act mh cur d need=0
  _lock "$win"
  while read -r id a h p act mh; do
    if [ "$a" = 1 ] && [ "$p" = 1 ]; then
      tmux set-option -t "$id" -p @minimize_saved "$h"
    elif [ "$a" = 1 ] && [ "$p" != 1 ] && [ "$act" != 1 ]; then
      case "$mh" in ''|*[!0-9]*) cur=$MIN_H ;; *) cur=$mh ;; esac
      d=$(( h - cur )); [ "$d" -lt 0 ] && d=$(( -d ))
      if [ "$d" -gt 1 ]; then tmux set-option -t "$id" -p @minimize_minh "$h"; need=1; fi
    fi
  done <<EOF
$(tmux list-panes -t "$win" -F '#{pane_id} #{?@minimize_active,1,0} #{pane_height} #{?@minimize_peek,1,0} #{pane_active} #{@minimize_minh}')
EOF
  [ "$need" = 1 ] && apply "$win"
  _unlock
}

# Explicit per-pane minimized-height control (keyboard). set/adjust/reset @minimize_minh
# on a pane and re-pin (apply) so it takes effect immediately. Clamped >=1.
set_minh() {
  local pane="$1" h="$2" win
  case "$h" in ''|*[!0-9]*) return 0 ;; esac
  [ "$h" -lt 1 ] && h=1
  win=$(tmux display-message -p -t "$pane" '#{window_id}')
  _lock "$win"
  tmux set-option -t "$pane" -p @minimize_minh "$h"
  apply "$win"
  _unlock
}
adjust_minh() {
  local pane="$1" delta="$2" cur new
  cur=$(tmux show-options -t "$pane" -pqv @minimize_minh 2>/dev/null || true)
  case "$cur" in ''|*[!0-9]*) cur=$MIN_H ;; esac
  new=$(( cur + delta )); [ "$new" -lt 1 ] && new=1
  set_minh "$pane" "$new"
}
reset_minh() {
  local pane="$1" win
  win=$(tmux display-message -p -t "$pane" '#{window_id}')
  _lock "$win"
  tmux set-option -t "$pane" -pu @minimize_minh
  apply "$win"
  _unlock
}

# dashboard: toggle a "focus" view — minimize every pane in the window EXCEPT the
# active one, then a second invocation restores the previous layout exactly.
#  - ENTER: save the window layout to @minimize_dashboard_layout, then minimize every
#    pane that isn't the active one and isn't already minimized, flagging each with
#    @minimize_dashboard so we know which ones WE minimized (user-minimized panes are
#    left as-is and survive the round trip).
#  - EXIT (saved layout present): clear flags on the dashboard panes and restore the
#    saved layout verbatim, so panes return to their exact prior sizes. Falls back to a
#    normal recompute if the saved layout no longer fits (a pane was added/closed).
dashboard() {
  local pane="$1" win active saved id
  win=$(tmux display-message -p -t "$pane" '#{window_id}')
  _lock "$win"
  tmux set-option -g @minimize_guard 1
  saved=$(tmux show-options -wqv @minimize_dashboard_layout 2>/dev/null || true)
  if [ -n "$saved" ]; then
    while read -r id; do
      [ -z "$id" ] && continue
      tmux set-option -t "$id" -p @minimize_active 0
      tmux set-option -t "$id" -pu @minimize_peek
      tmux set-option -t "$id" -pu @minimize_minh
      tmux set-option -t "$id" -pu @minimize_dashboard
    done <<EOF
$(tmux list-panes -t "$win" -F '#{?@minimize_dashboard,#{pane_id},}')
EOF
    tmux set-option -wu @minimize_dashboard_layout
    tmux select-layout -t "$win" "$saved" 2>/dev/null || apply "$win"
  else
    active=$(tmux display-message -p -t "$pane" '#{pane_id}')
    tmux set-option -w @minimize_dashboard_layout "$(tmux display-message -p -t "$win" '#{window_layout}')"
    while read -r id; do
      [ -z "$id" ] && continue
      [ "$id" = "$active" ] && continue
      [ "$(tmux display-message -p -t "$id" '#{?@minimize_active,1,0}')" = 1 ] && continue
      tmux set-option -t "$id" -p @minimize_saved   "$(tmux display-message -p -t "$id" '#{pane_height}')"
      tmux set-option -t "$id" -p @minimize_saved_w "$(tmux display-message -p -t "$id" '#{pane_width}')"
      tmux set-option -t "$id" -p @minimize_active 1
      tmux set-option -t "$id" -p @minimize_dashboard 1
    done <<EOF
$(tmux list-panes -t "$win" -F '#{pane_id}')
EOF
    apply "$win"
  fi
  tmux set-option -gu @minimize_guard
  _unlock
}

# ---- tmux-resurrect persistence ----
# resurrect saves/restores #{window_layout}, so the minimized GEOMETRY already survives
# a restart — but the per-pane @minimize_* options (which tell the plugin a pane IS
# minimized, and its pre-minimize size) are user options resurrect doesn't touch.
# save-state/restore-state persist them in a sidecar keyed by session:window.pane_index
# (the same stable identity resurrect uses), wired via resurrect's post-save/restore
# hooks. Transient peek + dashboard grouping are intentionally not persisted.
_state_file() {
  local d
  d=$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)
  [ -z "$d" ] && d="$HOME/.tmux/resurrect"
  printf '%s/tmux-pane-minimize.state' "$d"
}
save_state() {
  local f="${1:-}"
  [ -z "$f" ] && f=$(_state_file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  # one TAB-separated line per minimized pane: sess win pane saved saved_w minh
  tmux list-panes -a -F '#{?@minimize_active,#{session_name}	#{window_index}	#{pane_index}	#{@minimize_saved}	#{@minimize_saved_w}	#{@minimize_minh},}' \
    | grep -v '^$' > "$f" 2>/dev/null || true
}
restore_state() {
  local f="${1:-}" sess win pane saved savedw minh tgt w wins=""
  [ -z "$f" ] && f=$(_state_file)
  [ -f "$f" ] || return 0
  while IFS='	' read -r sess win pane saved savedw minh; do
    [ -z "$sess" ] && continue
    tgt="${sess}:${win}.${pane}"
    tmux display-message -p -t "$tgt" '#{pane_id}' >/dev/null 2>&1 || continue
    tmux set-option -t "$tgt" -p @minimize_active 1
    case "$saved"  in ''|*[!0-9]*) ;; *) tmux set-option -t "$tgt" -p @minimize_saved   "$saved"  ;; esac
    case "$savedw" in ''|*[!0-9]*) ;; *) tmux set-option -t "$tgt" -p @minimize_saved_w "$savedw" ;; esac
    case "$minh"   in ''|*[!0-9]*) ;; *) tmux set-option -t "$tgt" -p @minimize_minh    "$minh"   ;; esac
    w=$(tmux display-message -p -t "$tgt" '#{window_id}')
    case " $wins " in *" $w "*) ;; *) wins="$wins $w" ;; esac
  done < "$f"
  for w in $wins; do
    _lock "$w"; apply "$w"; _unlock
  done
}

case "${1:-}" in
  toggle)    toggle_pane "$2" ;;
  peekin)    peekin "$2" "${3:-}" ;;
  peekout)   peekout "$2" "${3:-}" ;;
  dragend)   dragend "$2" ;;
  dashboard) dashboard "$2" ;;
  save-state)    save_state "${2:-}" ;;
  restore-state) restore_state "${2:-}" ;;
  minh-set)    set_minh "$2" "$3" ;;
  minh-grow)   adjust_minh "$2" "$3" ;;
  minh-shrink) adjust_minh "$2" "-$3" ;;
  minh-reset)  reset_minh "$2" ;;
  repin)
    _lock "$2"; apply "$2"; _unlock ;;
  selftest)
    L='02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}'
    echo "in : $L"
    echo "height-only (96,97 min, 98 not -> 96/97=3, 95 untouched):"
    echo "  $(transform "$L" ' 96 97 ')"
    echo "full stack min (96,98,97 all min -> right column narrows to MIN_W=$MIN_W, 95 widens):"
    echo "  $(transform "$L" ' 96 98 97 ')"
    echo "peek: 96 min, 98 peeking (excluded from MINSET) -> 98 expands among flex panes:"
    echo "  $(transform "$L" ' 96 ')"
    echo "per-pane height: 96,97 min, 96 pinned to custom @minimize_minh=10 (97 -> MIN_H):"
    echo "  $(transform "$L" ' 96 97 ' ' ' '' 0 ' 96:10 ')" ;;
esac
