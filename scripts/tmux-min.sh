#!/usr/bin/env bash
# tmux-pane-minimize engine — tmux-IO orchestration layer.
#
# A "minimized" pane (per-pane option @minimize_active=1) is pinned to MIN_H rows.
# Additionally, when EVERY pane in a vertically-stacked group (a vertical split) is
# minimized, that whole group is shrunk to MIN_W columns and its horizontal
# neighbour widens to fill — restoring any pane widens the group back.
#
# The PURE layout math lives in transform.sh (sourced below): parse -> recompute ->
# reconcile -> serialize, with no tmux/time/randomness. EVERYTHING in this file reads
# tmux state, calls transform(), and applies the result atomically with select-layout.
# Keep that boundary: no layout math here, no `tmux ` in transform.sh.
#
# Usage:
#   tmux-min toggle <pane_id>     toggle minimize state of <pane_id>
#   tmux-min repin  <window_id>   re-pin minimized panes (e.g. after a resize)
#   tmux-min selftest             offline layout-string transform check (no tmux)
set -u

# Source the pure transform layer from THIS script's directory. Resolving via BASH_SOURCE
# (not a relative path) is what lets the test harness run a socket-patched copy from a
# scratch dir: it places transform.sh alongside the patched engine, so this still finds it.
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_DIR/transform.sh"

# Read both size options in ONE tmux round-trip (this runs on every engine invocation),
# overriding transform.sh's defaults.
IFS='|' read -r MIN_H MIN_W <<<"$(tmux display-message -p '#{@minimize-height}|#{@minimize-width}' 2>/dev/null || true)"
case "$MIN_H" in ''|*[!0-9]*) MIN_H=3 ;; esac
case "$MIN_W" in ''|*[!0-9]*) MIN_W=30 ;; esac

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
