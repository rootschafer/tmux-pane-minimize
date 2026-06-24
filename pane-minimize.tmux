#!/usr/bin/env bash
# tmux-pane-minimize — TPM entry point.
# Collapse a pane to a few lines and un-minimize it, keeping minimized panes pinned
# regardless of layout nesting. See README.md.
set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$CURRENT_DIR/scripts/tmux-min.sh"

opt() { # @name  default
  local v; v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# The border-marker builder (build_marker -> MARKER_FMT) lives in its own file; it needs
# opt() above and is invoked from the @minimize-marker block near the end.
# shellcheck source=/dev/null
. "$CURRENT_DIR/scripts/marker.sh"

KEY="$(opt @minimize-key 'C-t')"
HEIGHT="$(opt @minimize-height '3')"
MARKER="$(opt @minimize-marker 'on')"
PEEK="$(opt @minimize-peek 'on')"
MARKER_POS="$(opt @minimize-marker-position 'top')"
GROW=$(( HEIGHT + 1 ))   # "manually resized" threshold: taller than this => forget

# Toggle key (prefix table).
tmux bind-key "$KEY" run-shell "$SCRIPT toggle #{pane_id}"

# Optional keys to set the focused pane's custom minimized height (opt-in — only bound
# when you set the option). grow/shrink step by @minimize-minh-step rows; reset clears
# back to the global @minimize-height. The custom height lasts until the pane is
# un-minimized (then it resets). You can also set it by mouse-dragging a non-active
# minimized pane's border. Suggested: set @minimize-minh-grow-key '+' etc.
MINH_STEP="$(opt @minimize-minh-step '1')"
GROW_KEY="$(opt @minimize-minh-grow-key '')"
SHRINK_KEY="$(opt @minimize-minh-shrink-key '')"
RESET_KEY="$(opt @minimize-minh-reset-key '')"
[ -n "$GROW_KEY" ]   && tmux bind-key "$GROW_KEY"   run-shell "$SCRIPT minh-grow #{pane_id} $MINH_STEP"
[ -n "$SHRINK_KEY" ] && tmux bind-key "$SHRINK_KEY" run-shell "$SCRIPT minh-shrink #{pane_id} $MINH_STEP"
[ -n "$RESET_KEY" ]  && tmux bind-key "$RESET_KEY"  run-shell "$SCRIPT minh-reset #{pane_id}"

# Optional "dashboard" key (opt-in): minimize every pane except the active one; press
# again to restore the previous layout. Suggested: set @minimize-dashboard-key 'M'.
DASH_KEY="$(opt @minimize-dashboard-key '')"
[ -n "$DASH_KEY" ] && tmux bind-key "$DASH_KEY" run-shell "$SCRIPT dashboard #{pane_id}"

# tmux-resurrect persistence (on by default; set @minimize-resurrect 'off' to disable).
# resurrect restores #{window_layout} (minimized geometry) but not our per-pane options,
# so we persist them via resurrect's post-save/post-restore hooks. NOTE: this SETS those
# two hooks — if you already use @resurrect-hook-post-save-all / -post-restore-all
# yourself, set @minimize-resurrect 'off' and call `tmux-min.sh save-state`/`restore-state`
# from your own hooks instead.
if [ "$(opt @minimize-resurrect 'on')" = "on" ]; then
  tmux set-option -g @resurrect-hook-post-save-all    "bash '$SCRIPT' save-state"
  tmux set-option -g @resurrect-hook-post-restore-all "bash '$SCRIPT' restore-state"
fi

# Forget minimized state when the user resizes the ACTIVE pane taller themselves.
#  - keyboard / resize-pane command fires after-resize-pane
#  - @minimize_guard skips the plugin's own resizes
#  - gated on #{pane_active}: only the focused pane un-minimizes this way, so resizing
#    a NON-active minimized pane (mouse drag) sets its minimized height instead (dragend)
#  - only clear when clearly taller than minimized (tolerates the 1-row border nibble)
#  - also drop any per-pane custom minimized height (it's per-minimize-session)
tmux set-hook -g after-resize-pane \
  "if-shell -F '#{&&:#{!=:#{@minimize_guard},1},#{&&:#{pane_active},#{&&:#{&&:#{@minimize_active},#{!=:#{@minimize_peek},1}},#{>:#{pane_height},$GROW}}}}' 'set-option -p @minimize_active 0 ; set-option -pu @minimize_minh'"

# If the user resizes a pane *while it is peeked* (expanded for inspection), remember
# the new height as its saved size so future peeks / un-minimize use it. set-option
# does NOT expand #{pane_height}, so capture it through run-shell (which does).
tmux set-hook -a -g after-resize-pane \
  "if-shell -F '#{&&:#{!=:#{@minimize_guard},1},#{&&:#{@minimize_active},#{@minimize_peek}}}' 'run-shell -b \"tmux set-option -t #{pane_id} -p @minimize_saved #{pane_height}\"'"

# Terminal/window resize rescales panes (fires after-resize-window, not
# after-resize-pane) -> re-pin every minimized pane.
tmux set-hook -g after-resize-window "run-shell -b \"$SCRIPT repin #{window_id}\""

# Mouse: a border drag resizes internally (no per-step hook); MouseDragEnd1Border
# fires on release. The engine's `dragend` then: saves a peeked pane's new height, and
# turns a dragged NON-active minimized pane's new height into its custom minimized
# height (without un-minimizing it). ': ok' forces exit 0 so run-shell never dumps a
# non-zero exit into the pane.
tmux bind-key -T root MouseDragEnd1Border run-shell -b "$SCRIPT dragend #{window_id} ; : ok"

# Peek-on-focus: temporarily expand a minimized pane while selected. Gated on
# @minimize-peek (default on). Requires focus-events on (already set in dotfiles).
if [ "$PEEK" = "on" ]; then
  # set-hook -g (replace), NOT -a (append): appending re-adds a copy on every plugin
  # reload, so the hook would fire N times. Replace keeps exactly one. (We own the
  # pane-focus-in/out hooks; the after-resize-pane chain above is reset the same way.)
  tmux set-hook -g pane-focus-in  "if -F '#{&&:#{@minimize_active},#{!=:#{@minimize_peek},1}}' 'run-shell -b \"$SCRIPT peekin #{pane_id} #{window_id}\"'"
  tmux set-hook -g pane-focus-out "if -F '#{@minimize_peek}' 'run-shell -b \"$SCRIPT peekout #{pane_id} #{window_id}\"'"
fi

# Opt-in marker: only when @minimize-marker is "on" do we touch pane-border-*.
# Every pane shows @minimize-marker-left-format (e.g. your pane index/title); minimized
# panes additionally get the right-aligned pill. Set the left-format to keep your own
# border contents while letting the plugin own the marker.
if [ "$MARKER" = "on" ]; then
  MARKER_FMT="$(build_marker)"   # reads @minimize-marker-* -> the minimized-pane pill format
  # Left of the marker we show the pane index by default (overridable / set '' for a
  # pill-only border); minimized panes also get the right-aligned pill.
  MARKER_LEFT="$(opt @minimize-marker-left-format '#[align=left] #{pane_index} ')"
  case "$MARKER_POS" in top|bottom) ;; *) MARKER_POS=top ;; esac  # pane-border-status only takes top|bottom
  tmux set-option -g pane-border-status "$MARKER_POS"
  tmux set-option -g pane-border-format "${MARKER_LEFT}#{?@minimize_active,${MARKER_FMT},}"
fi
