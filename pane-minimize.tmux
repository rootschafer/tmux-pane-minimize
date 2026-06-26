#!/usr/bin/env bash
# tmux-pane-minimize — TPM entry point.
# Collapse a pane to a few lines and un-minimize it, keeping minimized panes pinned
# regardless of layout nesting. See README.md.
set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$CURRENT_DIR/scripts/tmux-min.sh"

# The layout math runs in a compiled Rust engine (engine-rs/ -> tmux-min-transform). Nix
# installs ship it prebuilt beside the scripts; TPM/manual installs build it on first load.
# If it isn't resolvable yet, build it in the BACKGROUND (installs Rust if needed — opt out
# with @minimize-auto-install-rust off) so tmux start isn't blocked. Minimize works once it
# finishes; until then toggling a pane is a no-op.
if [ -z "${TMUX_MIN_TRANSFORM:-}" ] \
   && [ ! -x "$CURRENT_DIR/scripts/tmux-min-transform" ] \
   && ! command -v tmux-min-transform >/dev/null 2>&1 \
   && [ ! -x "$CURRENT_DIR/target/release/tmux-min-transform" ]; then
  tmux run-shell -b "bash '$CURRENT_DIR/scripts/ensure-engine.sh'"
fi

opt() { # @name  default
  local v; v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# Install a GLOBAL event hook as a good citizen: APPEND (set-hook -a) so any hook the user or
# another plugin already set for that event keeps firing — `set-hook -g` would clobber it.
# `token` is a substring unique to our hook; if it's already present we skip, so re-sourcing
# the config never stacks duplicate copies (a plain -a would). Refreshing our own hook after a
# command change needs a server restart (or `set-hook -gu <event>`); that's the cost of not
# clobbering. Used for after-resize-pane/-window and pane-focus-in/out.
_add_hook() {  # event  token  command
  case "$(tmux show-hooks -g "$1" 2>/dev/null || true)" in
    *"$2"*) ;;                          # ours already installed -> don't duplicate
    *) tmux set-hook -a -g "$1" "$3" ;;
  esac
}

# Add one of resurrect's hook options without clobbering a value the user already set:
# resurrect runs the option via eval, so we chain ours after theirs with ';'. Idempotent on
# our $SCRIPT path so reloads don't re-chain.
_add_resurrect_hook() {  # option  command
  local cur; cur="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  case "$cur" in
    *"$SCRIPT"*) ;;                                  # already chained
    '')          tmux set-option -g "$1" "$2" ;;     # nothing there -> set ours
    *)           tmux set-option -g "$1" "$cur ; $2" ;;  # preserve theirs, append ours
  esac
}

# The border-marker builder (build_marker -> MARKER_FMT) lives in its own file; it needs
# opt() above and is invoked from the @minimize-marker block near the end.
# shellcheck source=/dev/null
. "$CURRENT_DIR/scripts/marker.sh"

KEY="$(opt @minimize-key 'C-t')"
HEIGHT="$(opt @minimize-height '3')"
MARKER="$(opt @minimize-marker 'on')"
PEEK="$(opt @minimize-peek 'on')"
MARKER_POS="$(opt @minimize-marker-position '')"   # empty = "respect the user's existing pane-border-status"
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

# Optional key to reset a fully-minimized group's custom WIDTH (set by side-border drag)
# back to @minimize-width. Opt-in. Suggested: set @minimize-minw-reset-key 'W'.
MINW_RESET_KEY="$(opt @minimize-minw-reset-key '')"
[ -n "$MINW_RESET_KEY" ] && tmux bind-key "$MINW_RESET_KEY" run-shell "$SCRIPT minw-reset #{pane_id}"

# Optional "minimize others" key (opt-in): minimize every pane except the active one; press
# again to restore the previous layout. Suggested: set @minimize-others-key 'M'.
OTHERS_KEY="$(opt @minimize-others-key '')"
[ -n "$OTHERS_KEY" ] && tmux bind-key "$OTHERS_KEY" run-shell "$SCRIPT minimize-others #{pane_id}"

# tmux-resurrect persistence (on by default; set @minimize-resurrect 'off' to disable).
# resurrect restores #{window_layout} (minimized geometry) but not our per-pane options,
# so we CHAIN onto resurrect's post-save/post-restore hooks. If you already set those hooks
# yourself, they're preserved (ours runs after, via resurrect's eval) — no need to disable.
if [ "$(opt @minimize-resurrect 'on')" = "on" ]; then
  _add_resurrect_hook @resurrect-hook-post-save-all    "bash '$SCRIPT' save-state"
  _add_resurrect_hook @resurrect-hook-post-restore-all "bash '$SCRIPT' restore-state"
fi

# Forget minimized state when the user resizes the ACTIVE pane taller themselves.
#  - keyboard / resize-pane command fires after-resize-pane
#  - @minimize_guard skips the plugin's own resizes
#  - gated on #{pane_active}: only the focused pane un-minimizes this way, so resizing
#    a NON-active minimized pane (mouse drag) sets its minimized height instead (dragend)
#  - only clear when clearly taller than minimized (tolerates the 1-row border nibble)
#  - also drop any per-pane custom minimized height (it's per-minimize-session)
_add_hook after-resize-pane '@minimize_active 0' \
  "if-shell -F '#{&&:#{!=:#{@minimize_guard},1},#{&&:#{pane_active},#{&&:#{&&:#{@minimize_active},#{!=:#{@minimize_peek},1}},#{>:#{pane_height},$GROW}}}}' 'set-option -p @minimize_active 0 ; set-option -pu @minimize_minh'"

# If the user resizes a pane *while it is peeked* (expanded for inspection), remember
# the new height as its saved size so future peeks / un-minimize use it. set-option
# does NOT expand #{pane_height}, so capture it through run-shell (which does).
_add_hook after-resize-pane '@minimize_saved' \
  "if-shell -F '#{&&:#{!=:#{@minimize_guard},1},#{&&:#{@minimize_active},#{@minimize_peek}}}' 'run-shell -b \"tmux set-option -t #{pane_id} -p @minimize_saved #{pane_height}\"'"

# Terminal/window resize rescales panes (fires after-resize-window, not
# after-resize-pane) -> re-pin every minimized pane.
_add_hook after-resize-window "$SCRIPT" "run-shell -b \"$SCRIPT repin #{window_id}\""

# Mouse: a border drag resizes internally (no per-step hook); MouseDragEnd1Border
# fires on release. The engine's `dragend` then: saves a peeked pane's new height, and
# turns a dragged NON-active minimized pane's new height into its custom minimized
# height (without un-minimizing it). ': ok' forces exit 0 so run-shell never dumps a
# non-zero exit into the pane.
tmux bind-key -T root MouseDragEnd1Border run-shell -b "$SCRIPT dragend #{window_id} ; : ok"

# Peek-on-focus: temporarily expand a minimized pane while selected. Gated on
# @minimize-peek (default on). Requires focus-events on (already set in dotfiles).
if [ "$PEEK" = "on" ]; then
  # Append (idempotent) so a user's existing pane-focus-in/out hooks keep firing; _add_hook
  # skips re-adding ours (keyed on $SCRIPT) so a reload doesn't stack duplicate copies.
  _add_hook pane-focus-in  "$SCRIPT" "if -F '#{&&:#{@minimize_active},#{!=:#{@minimize_peek},1}}' 'run-shell -b \"$SCRIPT peekin #{pane_id} #{window_id}\"'"
  _add_hook pane-focus-out "$SCRIPT" "if -F '#{@minimize_peek}' 'run-shell -b \"$SCRIPT peekout #{pane_id} #{window_id}\"'"
fi

# Minimized-pane indicator. @minimize-marker-style is flat | pill | none; @minimize-marker
# off (or style none) disables it. The computed indicator is ALWAYS published to the
# @minimize-indicator option so you can place it in YOUR OWN pane-border-format and keep full
# control of your border styling:
#     set -g pane-border-format '… #{?@minimize_active,#{E:#{@minimize-indicator}},}'
# If your pane-border-format already references @minimize-indicator, the plugin leaves your
# border options untouched (you're placing it). Otherwise — for a zero-config install — it
# AUGMENTS the existing pane-border-format with the indicator on minimized panes.
MARKER_STYLE="$(opt @minimize-marker-style 'flat')"
if [ "$MARKER" = "on" ] && [ "$MARKER_STYLE" != "none" ]; then
  MARKER_FMT="$(build_marker)"   # reads @minimize-marker-* -> the minimized-pane indicator
  tmux set-option -g @minimize-indicator "$MARKER_FMT"
  case "$(tmux show-option -gqv pane-border-format)" in
    *@minimize-indicator*) : ;;   # user places the indicator themselves -> don't touch borders
    *)
      # Zero-config augment: remember the user's ORIGINAL pane-border-format exactly once
      # (@minimize_marker_installed guards re-entry so a reload doesn't double the marker),
      # then append the marker. tmux reports its built-in default for an unset option, so a
      # user who set nothing keeps tmux's native border plus our marker. Override the left
      # content with @minimize-marker-left-format ('#[align=left] #{pane_index} ' for an
      # index-only border), or set your own pane-border-format with @minimize-indicator.
      if [ "$(tmux show-option -gqv @minimize_marker_installed)" != 1 ]; then
        tmux set-option -g @minimize_orig_format "$(tmux show-option -gqv pane-border-format)"
        tmux set-option -g @minimize_marker_installed 1
      fi
      MARKER_LEFT="$(opt @minimize-marker-left-format "$(tmux show-option -gqv @minimize_orig_format)")"
      # Respect the user's existing border position; only enable it (at
      # @minimize-marker-position, default top) when off, since the marker needs a border line.
      if [ -z "$MARKER_POS" ]; then
        case "$(tmux show-option -gqv pane-border-status)" in
          top|bottom) MARKER_POS="$(tmux show-option -gqv pane-border-status)" ;;
          *)          MARKER_POS=top ;;
        esac
      fi
      case "$MARKER_POS" in top|bottom) ;; *) MARKER_POS=top ;; esac
      tmux set-option -g pane-border-status "$MARKER_POS"
      tmux set-option -g pane-border-format "${MARKER_LEFT}#{?@minimize_active,${MARKER_FMT},}"
      ;;
  esac
else
  tmux set-option -gu @minimize-indicator 2>/dev/null || true   # disabled: clear the indicator
fi
