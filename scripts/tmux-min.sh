#!/usr/bin/env bash
# tmux-pane-minimize engine — tmux-IO orchestration layer.
#
# A "minimized" pane (per-pane option @minimize_active=1) is pinned to MIN_H rows.
# Additionally, when EVERY pane in a vertically-stacked group (a vertical split) is
# minimized, that whole group is shrunk to MIN_W columns and its horizontal
# neighbour widens to fill — restoring any pane widens the group back.
#
# The PURE layout math lives in the compiled Rust engine, tmux-min-transform (built from
# engine-rs/): parse -> recompute -> reconcile -> serialize, with no tmux/time/randomness.
# EVERYTHING in this file reads tmux state, calls the binary via _transform(), and applies
# the result atomically with select-layout. Keep that boundary: no layout math here.
# scripts/transform.sh is a byte-for-byte bash equivalent of the engine, kept ONLY as the
# differential-test oracle (tests/diff_test.sh) and offline property suite — not run here.
#
# Usage:
#   tmux-min toggle <pane_id>     toggle minimize state of <pane_id>
#   tmux-min repin  <window_id>   re-pin minimized panes (e.g. after a resize)
#   tmux-min selftest             offline layout-string transform check (no tmux)
set -u

# The pure layout math now lives in the compiled Rust engine, tmux-min-transform (built
# from engine-rs/). transform.sh is kept ONLY as the test oracle and is NOT sourced here.
# Resolve the binary via a BASH_SOURCE-relative path so a socket-patched test copy still
# works. Resolution order: explicit override (env), beside the scripts (Nix package),
# PATH, the downloaded prebuilt (ensure-engine.sh -> XDG data dir), then the dev build.
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_BIN="${TMUX_MIN_TRANSFORM:-}"
if [ -z "$_BIN" ]; then
  if [ -x "$_DIR/tmux-min-transform" ]; then
    _BIN="$_DIR/tmux-min-transform"                            # installed beside scripts (Nix package)
  elif command -v tmux-min-transform >/dev/null 2>&1; then
    _BIN="tmux-min-transform"                                  # on PATH
  elif [ -x "${XDG_DATA_HOME:-$HOME/.local/share}/tmux-pane-minimize/tmux-min-transform" ]; then
    _BIN="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-pane-minimize/tmux-min-transform"  # fetched prebuilt
  elif [ -x "$_DIR/../target/release/tmux-min-transform" ]; then
    _BIN="$_DIR/../target/release/tmux-min-transform"  # cargo dev build (workspace target/ at repo root)
  fi
fi

# Read the size options in ONE tmux round-trip (this runs on every engine invocation).
IFS='|' read -r MIN_H MIN_W ABS_MIN_H NARROW <<<"$(tmux display-message -p '#{@minimize-height}|#{@minimize-width}|#{@minimize-absolute-min-height}|#{@minimize-narrow}' 2>/dev/null || true)"
case "$MIN_H" in ''|*[!0-9]*) MIN_H=3 ;; esac
case "$MIN_W" in ''|*[!0-9]*) MIN_W=30 ;; esac
case "$ABS_MIN_H" in ''|*[!0-9]*) ABS_MIN_H=1 ;; esac
[ "$ABS_MIN_H" -lt 1 ] && ABS_MIN_H=1
[ "$ABS_MIN_H" -gt "$MIN_H" ] && ABS_MIN_H=$MIN_H   # the floor can't exceed the comfortable height
# Width-narrowing is opt-in (default off). Off passes MIN_W=0 to the engine as the "disabled"
# sentinel, so a fully-min group stays flexible instead of collapsing to a narrow column.
[ "$NARROW" != "on" ] && MIN_W=0
BORDER_POS="${BORDER_POS:-off}"   # apply() overrides this from tmux; default is for selftest

# _transform: call the Rust engine with the SAME six positional inputs the bash transform()
# took, plus the four globals it read (MIN_H MIN_W ABS_MIN_H BORDER_POS). Prints the new
# layout string to stdout. Hard-fails (no bash fallback) if the binary can't be found.
_transform() {  # LAYOUT MINSET SAVEDW WPANE WVAL MINH MINW WSET
  [ -n "$_BIN" ] || { echo "tmux-pane-minimize: tmux-min-transform binary not found (build engine-rs or set TMUX_MIN_TRANSFORM)" >&2; return 1; }
  "$_BIN" "$MIN_H" "$MIN_W" "$ABS_MIN_H" "$BORDER_POS" "$@"
}

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

# apply reads everything it needs in ONE tmux invocation (border + layout + per-pane
# state, chained with `\;`) and writes in one — instead of ~6 separate fork+exec+server
# round-trips. It also sets/clears @minimize_guard itself (chained into the same read
# and write calls), so callers don't pay extra round-trips for guarding. The guard
# suppresses the after-resize-pane hook during our own select-layout; chaining the unset
# onto select-layout keeps the suppression window as tight as possible.
apply() {
  local win="$1" wp="${2:-}" wv="${3:-0}" ws="${4:-0}" out new rid
  local n=0 f1 f2 f3 f4 f5 f6 f7 zoomed layout minset=" " savedw=" " minh=" " minw=" " actpane="" actmin=0
  out=$(tmux set-option -g @minimize_guard 1 \; \
        display-message -p -t "$win" '#{window_zoomed_flag}|#{pane-border-status}|#{window_layout}' \; \
        list-panes -t "$win" -F '#{pane_id}|#{?@minimize_active,1,0}|#{?@minimize_peek,1,0}|#{@minimize_saved_w}|#{@minimize_minh}|#{pane_active}|#{@minimize_minw}')
  while IFS='|' read -r f1 f2 f3 f4 f5 f6 f7; do
    n=$((n + 1))
    if [ "$n" = 1 ]; then zoomed=$f1; BORDER_POS=$f2; layout=$f3; continue; fi
    [ -z "$f1" ] && continue
    rid=$f1; f1=${f1#%}
    [ "$f2" = 1 ] && [ "$f3" != 1 ] && minset="$minset$f1 "
    [ -n "$f4" ] && savedw="$savedw$f1:$f4 "
    [ -n "$f5" ] && minh="$minh$f1:$f5 "
    [ -n "$f7" ] && minw="$minw$f1:$f7 "
    if [ "$f6" = 1 ]; then actpane=$rid; { [ "$f2" = 1 ] && [ "$f3" != 1 ]; } && actmin=1; fi
  done <<EOF
$out
EOF
  case "$BORDER_POS" in top|bottom) ;; *) BORDER_POS=off ;; esac
  if ! new=$(_transform "$layout" "$minset" "$savedw" "$wp" "$wv" "$minh" "$minw" "$ws"); then
    tmux set-option -gu @minimize_guard   # don't leave the resize-hook guard stuck on
    return 1
  fi
  # No-op guard: transform reproduces an already-correct layout byte-for-byte, so if `new`
  # equals the current #{window_layout} there is nothing to do — and calling select-layout
  # anyway would needlessly resize every pane (each gets a SIGWINCH, churning shell prompts)
  # and un-zoom the window. Skip it; the zoom is already intact, so just clear the guard.
  # The compare is a single cheap string test against data we already have.
  if [ "$new" = "$layout" ]; then
    tmux set-option -gu @minimize_guard
    return 0
  fi
  tmux select-layout -t "$win" "$new" \; set-option -gu @minimize_guard
  _rezoom "$zoomed" "$actpane" "$actmin"
  return 0   # explicit: _rezoom's status is incidental — callers rely on apply's success/fail
}

# select-layout un-zooms the window. Re-zoom the active pane so a repin (terminal resize
# while zoomed), a background minimize, or a minimize-others restore doesn't kick you out of a
# zoom — unless the active pane itself was the one minimized, where staying unzoomed is
# correct. Shared by apply() and minimize_others() so both preserve zoom identically.
_rezoom() {  # $1 was-zoomed  $2 active-pane-id  $3 active-pane-was-minimized
  [ "$1" = 1 ] && [ "$3" != 1 ] && [ -n "$2" ] && tmux resize-pane -Z -t "$2"
}

toggle_pane() {
  local pane="$1" win num active saved h w sset
  IFS='|' read -r win num active saved h w sset <<<"$(tmux display-message -p -t "$pane" \
    '#{window_id}|#{pane_id}|#{?@minimize_active,1,0}|#{@minimize_saved}|#{pane_height}|#{pane_width}|#{?@minimize_saved_set,1,0}')"
  num=${num#%}
  _lock "$win"
  if [ "$active" = 1 ]; then
    case "$saved" in ''|*[!0-9]*) saved=$MIN_H ;; esac
    tmux set-option -t "$pane" -p @minimize_active 0 \; \
         set-option -t "$pane" -pu @minimize_peek \; \
         set-option -t "$pane" -pu @minimize_saved_set \; \
         set-option -t "$pane" -pu @minimize_minh        # custom min height is per-session
    # Roll back to minimized if the layout couldn't be applied, so the pane never ends up
    # marked un-minimized while still collapsed (or vice versa).
    apply "$win" "$num" "$saved" "$sset" || tmux set-option -t "$pane" -p @minimize_active 1
  else
    # @minimize_saved_w is the NARROW feature's memory (the width a narrowed group widens
    # back to). It must exist ONLY while narrowing is on: with narrow off the engine would
    # otherwise pin a fully-minimized stack to it on every apply, snapping back any width
    # the user drags. When off, also drop a stale value left by an earlier narrow-on session.
    # @minimize_saved is only a SNAPSHOT of the height this pane happened to have — it can be
    # far larger than the pane could ever occupy in the stack it ends up in (minimize a pane
    # while it is alone in its column, then split it). Clear @minimize_saved_set so the engine
    # treats it as a hint that must not squeeze minimized siblings below MIN_H; only an
    # explicit user resize (dragend / resize-while-peeked) marks it as deliberate.
    if [ "$NARROW" = on ]; then
      tmux set-option -t "$pane" -p @minimize_saved "$h" \; \
           set-option -t "$pane" -pu @minimize_saved_set \; \
           set-option -t "$pane" -p @minimize_saved_w "$w" \; \
           set-option -t "$pane" -p @minimize_active 1
    else
      tmux set-option -t "$pane" -p @minimize_saved "$h" \; \
           set-option -t "$pane" -pu @minimize_saved_set \; \
           set-option -t "$pane" -pu @minimize_saved_w \; \
           set-option -t "$pane" -p @minimize_active 1
    fi
    apply "$win" || tmux set-option -t "$pane" -p @minimize_active 0 \; \
         set-option -t "$pane" -pu @minimize_saved \; set-option -t "$pane" -pu @minimize_saved_w
  fi
  _unlock
}

# peekin/peekout serialize on the window lock, then RE-CHECK live state so the result
# matches reality regardless of which queued hook wins the lock: only peek a pane that
# is still minimized, not already peeking, AND currently the active pane; only collapse
# a pane that is peeking and no longer active. This makes a rapid focus ping-pong
# converge deterministically to the final-focus state instead of a last-writer race.
peekin() {
  local pane="$1" win="${2:-}" num active peek pa saved sset
  [ -z "$win" ] && win=$(tmux display-message -p -t "$pane" '#{window_id}')
  _lock "$win"
  IFS='|' read -r active peek pa num saved sset <<<"$(tmux display-message -p -t "$pane" \
    '#{?@minimize_active,1,0}|#{?@minimize_peek,1,0}|#{pane_active}|#{pane_id}|#{@minimize_saved}|#{?@minimize_saved_set,1,0}')"
  if [ "$active" = 1 ] && [ "$peek" != 1 ] && [ "$pa" = 1 ]; then
    num=${num#%}
    case "$saved" in ''|*[!0-9]*) saved=$MIN_H ;; esac
    tmux set-option -t "$pane" -p @minimize_peek 1
    # sset tells the engine whether $saved is a deliberate user size (honour it, siblings may
    # yield to their floor) or just a snapshot (a hint that must spare siblings their MIN_H).
    apply "$win" "$num" "$saved" "$sset" || tmux set-option -t "$pane" -pu @minimize_peek   # roll back
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
    apply "$win" || tmux set-option -t "$pane" -p @minimize_peek 1   # roll back
  fi
  _unlock
}

# dragend: handle a mouse border-drag release for a whole window. Three effects:
#  - peeking pane resized          -> remember the new height as its saved/peek height
#  - NON-active minimized pane      -> that dragged HEIGHT becomes its custom minimized
#    height (@minimize_minh); does NOT un-minimize it.
#  - fully-minimized vertical GROUP (>=2 stacked panes, all minimized, none active) whose
#    WIDTH was dragged -> that width becomes the group's custom minimized width
#    (@minimize_minw on every member); persists until those panes change. A horizontal drag
#    changes width; a vertical drag changes height — we detect which from what actually moved.
# Tolerance of >1 so the border-status edge nibble and untouched panes don't trigger a change.
dragend() {
  local win="$1" id a h p act mh cur d need=0 table cols width cmw swany cids hold
  _lock "$win"
  table=$(tmux list-panes -t "$win" -F '#{pane_id}|#{?@minimize_active,1,0}|#{pane_height}|#{?@minimize_peek,1,0}|#{pane_active}|#{@minimize_minh}|#{pane_width}|#{pane_left}|#{@minimize_minw}|#{@minimize_saved_w}|#{pane_top}')
  # A column whose panes are ALL minimized still has to fill its height, so the engine hands
  # the BOTTOM-most pane whatever is left over (see the allmin path in the engine). That
  # height is engine-assigned, not dragged, and it is nowhere near MIN_H — without this the
  # height check below would mistake it for a deliberate drag and pin it as that pane's
  # custom minimized height for the rest of the minimize session. Collect those panes.
  hold=" $(printf '%s\n' "$table" | awk -F'|' '
    $1=="" { next }
    { L=$8; cnt[L]++; if ($2!=1) notmin[L]=1; if ($5==1) act[L]=1
      if (!(L in bt) || $11+0 > bt[L]) { bt[L]=$11+0; bid[L]=$1 } }
    END { for (L in cnt) if (cnt[L]>=2 && notmin[L]!=1 && act[L]!=1) print bid[L] }' | tr '\n' ' ') "
  # per-pane: peek-save + custom minimized HEIGHT (width fields are handled by the awk pass below)
  while IFS='|' read -r id a h p act mh _; do
    [ -z "$id" ] && continue
    if [ "$a" = 1 ] && [ "$p" = 1 ]; then
      # The user dragged this pane's border while it was peeked -> a DELIBERATE size. Mark it
      # so the engine honours it exactly on later peeks (see @minimize_saved_set in STATE.md).
      tmux set-option -t "$id" -p @minimize_saved "$h" \; \
           set-option -t "$id" -p @minimize_saved_set 1
    elif [ "$a" = 1 ] && [ "$p" != 1 ] && [ "$act" != 1 ]; then
      case "$hold" in *" $id "*) continue ;; esac   # engine-assigned remainder, not a drag
      case "$mh" in ''|*[!0-9]*) cur=$MIN_H ;; *) cur=$mh ;; esac
      d=$(( h - cur )); [ "$d" -lt 0 ] && d=$(( -d ))
      if [ "$d" -gt 1 ]; then tmux set-option -t "$id" -p @minimize_minh "$h"; need=1; fi
    fi
  done <<EOF
$table
EOF
  # per fully-minimized column: group panes by pane_left (stacked panes share it). A column
  # of >=2 panes that are ALL minimized and NONE active is a narrowed group; if its width no
  # longer matches its recorded minw (or MIN_W), the user dragged it -> persist as @minimize_minw.
  # With narrow OFF the engine ignores minw, so recording it would be noise; instead a drag
  # clears any stale @minimize_saved_w on the column (left by a narrow-on session or a config
  # flip), because the engine pins a fully-min group to saved_w and would snap the drag back.
  cols=$(printf '%s\n' "$table" | awk -F'|' '
    $1=="" { next }
    { L=$8; cnt[L]++; if ($2!=1) notmin[L]=1; if ($5==1) act[L]=1; wd[L]=$7; mw[L]=$9;
      if ($10!="") sw[L]=1; ids[L]=ids[L]" "$1 }
    END { for (L in cnt) if (cnt[L]>=2 && notmin[L]!=1 && act[L]!=1) print wd[L]"|"mw[L]"|"sw[L]"|"ids[L] }')
  while IFS='|' read -r width cmw swany cids; do
    [ -z "$width" ] && continue
    if [ "$NARROW" = on ]; then
      case "$cmw" in ''|*[!0-9]*) cur=$MIN_W ;; *) cur=$cmw ;; esac
      d=$(( width - cur )); [ "$d" -lt 0 ] && d=$(( -d ))
      if [ "$d" -gt 1 ]; then
        for id in $cids; do tmux set-option -t "$id" -p @minimize_minw "$width"; done
        need=1
      fi
    elif [ "$swany" = 1 ]; then
      for id in $cids; do tmux set-option -t "$id" -pu @minimize_saved_w; done
      need=1
    fi
  done <<EOF
$cols
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

# narrow_toggle: flip @minimize-narrow (on|off) globally and re-pin every window so the change
# takes effect immediately — turning it on narrows every currently fully-minimized group,
# turning it off widens each of them back to its saved pre-narrow width. We update MIN_W in
# this process directly (from what we just set) instead of re-querying tmux — cheaper and
# it's the same value.
narrow_toggle() {
  local cur w turned_off=0 id pw
  local -a cmd
  cur=$(tmux show-option -gqv @minimize-narrow 2>/dev/null || true)
  case "$cur" in
    on) tmux set-option -g @minimize-narrow off; MIN_W=0; turned_off=1 ;;
    *)  tmux set-option -g @minimize-narrow on
        # Restore the configured @minimize-width; MIN_W was clamped to 0 at load if narrow was off.
        MIN_W=$(tmux show-option -gqv @minimize-width 2>/dev/null || true)
        case "$MIN_W" in ''|*[!0-9]*) MIN_W=30 ;; esac
        # Turning ON: capture every minimized pane's CURRENT width as its pre-narrow
        # width, so a group narrowed by the repin below can widen back to it later.
        # (saved_w exists only while narrow is on; nothing recorded it while off.)
        cmd=()
        while read -r id pw; do
          [ -z "$id" ] && continue
          [ -z "$pw" ] && continue
          [ "${#cmd[@]}" -gt 0 ] && cmd+=( ';' )
          cmd+=( set-option -t "$id" -p @minimize_saved_w "$pw" )
        done <<EOF
$(tmux list-panes -a -F '#{pane_id} #{?@minimize_active,#{pane_width},}' 2>/dev/null || true)
EOF
        [ "${#cmd[@]}" -gt 0 ] && tmux "${cmd[@]}" ;;
  esac
  while read -r w; do
    [ -z "$w" ] && continue
    _lock "$w"; apply "$w"; _unlock
  done <<EOF
$(tmux list-windows -a -F '#{window_id}' 2>/dev/null || true)
EOF
  # Turning OFF: the repins above just widened every narrowed group back to its saved_w —
  # that memory is now consumed. Clear it everywhere, or the engine would keep pinning
  # fully-minimized stacks to it (snapping back user drags) while narrow is off.
  if [ "$turned_off" = 1 ]; then
    cmd=()
    while read -r id; do
      [ -z "$id" ] && continue
      [ "${#cmd[@]}" -gt 0 ] && cmd+=( ';' )
      cmd+=( set-option -t "$id" -pu @minimize_saved_w )
    done <<EOF
$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || true)
EOF
    [ "${#cmd[@]}" -gt 0 ] && tmux "${cmd[@]}"
  fi
}

# reset_minw: clear a fully-minimized group's custom width, snapping it back to @minimize-width.
# The width is shared across the group (stored on every member), so clear @minimize_minw on
# every pane in the target's column (panes in a vertical stack share pane_left), then re-pin.
reset_minw() {
  local pane="$1" win left id l
  win=$(tmux display-message -p -t "$pane" '#{window_id}')
  left=$(tmux display-message -p -t "$pane" '#{pane_left}')
  _lock "$win"
  while read -r id l; do
    [ -z "$id" ] && continue
    [ "$l" = "$left" ] && tmux set-option -t "$id" -pu @minimize_minw
  done <<EOF
$(tmux list-panes -t "$win" -F '#{pane_id} #{pane_left}')
EOF
  apply "$win"
  _unlock
}

# minimize_others: toggle a "focus" view — minimize every pane in the window EXCEPT the
# active one, then a second invocation restores the previous layout exactly.
#  - ENTER: save the window layout to @minimize_others_layout, then minimize every
#    pane that isn't the active one and isn't already minimized, flagging each with
#    @minimize_others so we know which ones WE minimized (user-minimized panes are
#    left as-is and survive the round trip).
#  - EXIT (saved layout present): clear flags on the minimized-others panes and restore the
#    saved layout verbatim, so panes return to their exact prior sizes. Falls back to a
#    normal recompute if the saved layout no longer fits (a pane was added/closed).
minimize_others() {
  local pane="$1" win saved id pa ma ph pw dz dap dam
  local -a cmd
  win=$(tmux display-message -p -t "$pane" '#{window_id}')
  _lock "$win"
  tmux set-option -g @minimize_guard 1
  saved=$(tmux show-options -wqv @minimize_others_layout 2>/dev/null || true)
  if [ -n "$saved" ]; then
    # EXIT: clear the flags WE set, then restore the saved layout. Coalesced — all the
    # per-pane unsets go out in ONE chained tmux call (was 4 round-trips per pane).
    cmd=()
    while read -r id; do
      [ -z "$id" ] && continue
      [ "${#cmd[@]}" -gt 0 ] && cmd+=( ';' )
      cmd+=( set-option -t "$id" -p @minimize_active 0 ';'
             set-option -t "$id" -pu @minimize_peek ';'
             set-option -t "$id" -pu @minimize_minh ';'
             set-option -t "$id" -pu @minimize_others )
    done <<EOF
$(tmux list-panes -t "$win" -F '#{?@minimize_others,#{pane_id},}')
EOF
    [ "${#cmd[@]}" -gt 0 ] && tmux "${cmd[@]}"
    tmux set-option -wu @minimize_others_layout
    # Restore the exact prior layout verbatim (NOT via apply()'s recompute, which would
    # re-derive sizes). Read zoom + active-pane state in one call so we can preserve zoom
    # the same way apply() does. Fall back to a recompute if the saved layout no longer
    # fits (a pane was added/closed). The guard is held throughout, so the rezoom's
    # resize-pane can't trip the after-resize hook.
    IFS='|' read -r dz dap dam <<<"$(tmux display-message -p -t "$win" \
      '#{window_zoomed_flag}|#{pane_id}|#{?@minimize_active,1,0}')"
    if tmux select-layout -t "$win" "$saved" 2>/dev/null; then
      _rezoom "$dz" "$dap" "$dam"
    else
      apply "$win"
    fi
  else
    # ENTER: save the layout, then minimize every pane that is neither the active one nor
    # already user-minimized (those survive the round trip). Coalesced — read all pane
    # state in ONE list-panes (was 3 display-messages per pane) and set all the flags in
    # ONE chained tmux call (was 4 set-options per pane).
    tmux set-option -w @minimize_others_layout "$(tmux display-message -p -t "$win" '#{window_layout}')"
    cmd=()
    while IFS='|' read -r id pa ma ph pw; do
      [ -z "$id" ] && continue
      [ "$pa" = 1 ] && continue          # keep the active pane
      [ "$ma" = 1 ] && continue          # leave user-minimized panes as-is
      [ "${#cmd[@]}" -gt 0 ] && cmd+=( ';' )
      # saved_w only while narrow is on (see toggle_pane) — when off, also heal a stale one.
      if [ "$NARROW" = on ]; then
        cmd+=( set-option -t "$id" -p @minimize_saved_w "$pw" ';' )
      else
        cmd+=( set-option -t "$id" -pu @minimize_saved_w ';' )
      fi
      # As in toggle_pane: this @minimize_saved is an incidental snapshot, so clear
      # @minimize_saved_set — the engine must treat it as a hint, not a deliberate size.
      cmd+=( set-option -t "$id" -p @minimize_saved "$ph" ';'
             set-option -t "$id" -pu @minimize_saved_set ';'
             set-option -t "$id" -p @minimize_active 1 ';'
             set-option -t "$id" -p @minimize_others 1 )
    done <<EOF
$(tmux list-panes -t "$win" -F '#{pane_id}|#{pane_active}|#{?@minimize_active,1,0}|#{pane_height}|#{pane_width}')
EOF
    [ "${#cmd[@]}" -gt 0 ] && tmux "${cmd[@]}"
    if ! apply "$win"; then
      # Roll back the flags we just set so a failed apply doesn't leave a half-entered
      # minimize-others view (panes marked minimized but full-size, with a stale saved layout).
      cmd=()
      while read -r id; do
        [ -z "$id" ] && continue
        [ "${#cmd[@]}" -gt 0 ] && cmd+=( ';' )
        cmd+=( set-option -t "$id" -p @minimize_active 0 ';'
               set-option -t "$id" -pu @minimize_saved ';'
               set-option -t "$id" -pu @minimize_saved_w ';'
               set-option -t "$id" -pu @minimize_others )
      done <<EOF
$(tmux list-panes -t "$win" -F '#{?@minimize_others,#{pane_id},}')
EOF
      [ "${#cmd[@]}" -gt 0 ] && tmux "${cmd[@]}"
      tmux set-option -wu @minimize_others_layout
    fi
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
# hooks. Transient peek + minimize-others grouping are intentionally not persisted.
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
  # One '|'-separated line per minimized pane:
  #   win pane saved saved_w minh minw saved_set sess
  # NOT tab-separated: tmux <= 3.4 sanitizes control chars (incl. TAB) in format output
  # to '_', which silently corrupted the sidecar. The session name goes LAST so a name
  # containing '|' still parses (read assigns the remainder to the final field).
  tmux list-panes -a -F '#{?@minimize_active,#{window_index}|#{pane_index}|#{@minimize_saved}|#{@minimize_saved_w}|#{@minimize_minh}|#{@minimize_minw}|#{?@minimize_saved_set,1,0}|#{session_name},}' \
    | grep -v '^$' > "$f" 2>/dev/null || true
}
restore_state() {
  local f="${1:-}" sess win pane saved savedw minh minw tgt wid k v w wins="" panemap
  local -a cmd
  [ -z "$f" ] && f=$(_state_file)
  [ -f "$f" ] || return 0
  # Read every live pane ONCE into a "window_id|target" table, so each saved entry is
  # resolved (does the pane still exist? which window?) by an in-shell lookup instead of
  # two display-message round-trips per entry. Then set all the per-pane options in ONE
  # chained tmux call (same coalescing as minimize_others()).
  # window_id comes FIRST so the target (which embeds the session NAME) is the read's last
  # field and keeps any '|' a session name contains — the other order silently failed to
  # match those sessions, dropping their minimized state.
  panemap=$(tmux list-panes -a -F '#{window_id}|#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
  cmd=()
  while IFS='|' read -r win pane saved savedw minh minw sset sess; do
    # Back-compat: a sidecar written before @minimize_saved_set existed has no flag field, so
    # what lands in `sset` is really the session name. Two shapes to unshift: an empty `sess`
    # (the common case), or a `sset` that isn't the 0/1 flag (session name containing '|',
    # which `read` split across the last two fields).
    if [ -z "$sess" ]; then
      sess=$sset; sset=0
    else
      case "$sset" in 0|1) ;; *) sess="$sset|$sess"; sset=0 ;; esac
    fi
    [ -z "$sess" ] && continue
    tgt="${sess}:${win}.${pane}"
    wid=""
    while IFS='|' read -r v k; do [ "$k" = "$tgt" ] && { wid="$v"; break; }; done <<EOF
$panemap
EOF
    [ -z "$wid" ] && continue          # a pane from the saved state no longer exists
    [ "${#cmd[@]}" -gt 0 ] && cmd+=( ';' )
    cmd+=( set-option -t "$tgt" -p @minimize_active 1 )
    case "$saved"  in ''|*[!0-9]*) ;; *) cmd+=( ';' set-option -t "$tgt" -p @minimize_saved   "$saved"  ) ;; esac
    # saved_w exists only while narrow is on — replaying it with narrow off would make
    # the engine pin fully-minimized stacks to it (the width snap-back bug).
    if [ "$NARROW" = on ]; then
      case "$savedw" in ''|*[!0-9]*) ;; *) cmd+=( ';' set-option -t "$tgt" -p @minimize_saved_w "$savedw" ) ;; esac
    fi
    case "$minh"   in ''|*[!0-9]*) ;; *) cmd+=( ';' set-option -t "$tgt" -p @minimize_minh    "$minh"   ) ;; esac
    # Only a deliberate height carries the flag; without it @minimize_saved stays a hint.
    case "$sset"   in 1) cmd+=( ';' set-option -t "$tgt" -p @minimize_saved_set 1 ) ;; esac
    case "$minw"   in ''|*[!0-9]*) ;; *) cmd+=( ';' set-option -t "$tgt" -p @minimize_minw    "$minw"   ) ;; esac
    case " $wins " in *" $wid "*) ;; *) wins="$wins $wid" ;; esac
  done < "$f"
  [ "${#cmd[@]}" -gt 0 ] && tmux "${cmd[@]}"
  for w in $wins; do
    _lock "$w"; apply "$w"; _unlock
  done
}

case "${1:-}" in
  toggle)    toggle_pane "$2" ;;
  peekin)    peekin "$2" "${3:-}" ;;
  peekout)   peekout "$2" "${3:-}" ;;
  dragend)   dragend "$2" ;;
  minimize-others) minimize_others "$2" ;;
  save-state)    save_state "${2:-}" ;;
  restore-state) restore_state "${2:-}" ;;
  minh-set)    set_minh "$2" "$3" ;;
  minh-grow)   adjust_minh "$2" "$3" ;;
  minh-shrink) adjust_minh "$2" "-$3" ;;
  minh-reset)  reset_minh "$2" ;;
  minw-reset)  reset_minw "$2" ;;
  narrow-toggle) narrow_toggle ;;
  repin)
    _lock "$2"; apply "$2"; _unlock ;;
  selftest)
    L='02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}'
    echo "in : $L"
    echo "height-only (96,97 min, 98 not -> 96/97=3, 95 untouched):"
    echo "  $(_transform "$L" ' 96 97 ' ' ' '' 0 ' ')"
    echo "full stack min (96,98,97 all min -> right column narrows to MIN_W=$MIN_W, 95 widens):"
    echo "  $(_transform "$L" ' 96 98 97 ' ' ' '' 0 ' ')"
    echo "peek: 96 min, 98 peeking (excluded from MINSET) -> 98 expands among flex panes:"
    echo "  $(_transform "$L" ' 96 ' ' ' '' 0 ' ')"
    echo "per-pane height: 96,97 min, 96 pinned to custom @minimize_minh=10 (97 -> MIN_H):"
    echo "  $(_transform "$L" ' 96 97 ' ' ' '' 0 ' 96:10 ')" ;;
esac
