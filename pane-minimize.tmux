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

KEY="$(opt @minimize-key 'C-t')"
HEIGHT="$(opt @minimize-height '3')"
MARKER="$(opt @minimize-marker 'on')"
PEEK="$(opt @minimize-peek 'on')"
MARKER_POS="$(opt @minimize-marker-position 'top')"
GROW=$(( HEIGHT + 1 ))   # "manually resized" threshold: taller than this => forget

# --- Marker "pill": a rounded background with a centred icon (opt-in via @minimize-marker).
# Pull the fg= colour out of a pane-border style so the pill can default to the user's
# border colours (inactive vs active).
_border_fg() {
  local s; s="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  case "$s" in *fg=*) s="${s#*fg=}"; printf '%s' "${s%%[, ]*}" ;; *) printf '' ;; esac
}
# _xterm_rgb N -> sets R/G/B for a 0-255 palette index (16 base + 6x6x6 cube + greys).
_xterm_rgb() {
  local n=$1 m ri gi bi v
  if [ "$n" -lt 16 ]; then
    case "$n" in
      0) R=0;G=0;B=0;; 1) R=128;G=0;B=0;; 2) R=0;G=128;B=0;; 3) R=128;G=128;B=0;;
      4) R=0;G=0;B=128;; 5) R=128;G=0;B=128;; 6) R=0;G=128;B=128;; 7) R=192;G=192;B=192;;
      8) R=128;G=128;B=128;; 9) R=255;G=0;B=0;; 10) R=0;G=255;B=0;; 11) R=255;G=255;B=0;;
      12) R=0;G=0;B=255;; 13) R=255;G=0;B=255;; 14) R=0;G=255;B=255;; *) R=255;G=255;B=255;;
    esac
  elif [ "$n" -ge 232 ]; then
    v=$(( (n - 232) * 10 + 8 )); R=$v; G=$v; B=$v
  else
    m=$(( n - 16 )); ri=$(( m / 36 )); gi=$(( (m % 36) / 6 )); bi=$(( m % 6 ))
    [ "$ri" -eq 0 ] && R=0 || R=$(( ri * 40 + 55 ))
    [ "$gi" -eq 0 ] && G=0 || G=$(( gi * 40 + 55 ))
    [ "$bi" -eq 0 ] && B=0 || B=$(( bi * 40 + 55 ))
  fi
}
# _contrast_fg BG -> a readable icon colour for that bg: black (colour16) on light
# backgrounds, white (colour231) on dark ones (perceived-luminance threshold). Falls back
# to terminal 'default' when the bg is a named/unknown colour we can't resolve to RGB.
_contrast_fg() {
  local c="$1" lum
  case "$c" in
    '#'*) c="${c#\#}"; R=$(( 16#${c:0:2} )); G=$(( 16#${c:2:2} )); B=$(( 16#${c:4:2} )) ;;
    colour[0-9]*) _xterm_rgb "${c#colour}" ;;
    color[0-9]*)  _xterm_rgb "${c#color}" ;;
    [0-9]*) _xterm_rgb "$c" ;;
    *) printf 'default'; return ;;
  esac
  lum=$(( (R * 299 + G * 587 + B * 114) / 1000 ))
  [ "$lum" -gt 140 ] && printf 'colour16' || printf 'colour231'
}
# Default glyphs are UTF-8 byte escapes (printf '\xHH') so no multi-byte chars live in the
# source (bash-3.2 safe; no $'\u'). Inactive icon = nf-md-unfold_less_horizontal (U+F054E);
# the active/peeked pane shows nf-md-unfold_more_horizontal (U+F054F).
MARKER_ICON="$(opt @minimize-marker-icon "$(printf '\xf3\xb0\x95\x8e')")"
MARKER_ICON_ACTIVE="$(opt @minimize-marker-icon-active "$(printf '\xf3\xb0\x95\x8f')")"
MARKER_WIDTH="$(opt @minimize-marker-width '5')"           # 3 or 5
MARKER_ICON_COLOR="$(opt @minimize-marker-icon-color 'auto')"   # 'auto' = black/white by bg luminance
MARKER_BG="$(opt @minimize-marker-bg "$(_border_fg pane-border-style)")"
MARKER_BG_ACTIVE="$(opt @minimize-marker-bg-active "$(_border_fg pane-active-border-style)")"
[ -z "$MARKER_BG" ] && MARKER_BG='colour238'               # fallback when no border style set
[ -z "$MARKER_BG_ACTIVE" ] && MARKER_BG_ACTIVE='colour110'
case "$MARKER_WIDTH" in 3) MPAD='' ;; *) MPAD=' ' ;; esac   # 5 => one space each side; 3 => snug
# Rounded end-caps (Powerline half-circles U+E0B6 / U+E0B4); override for square/flat/etc.
MARKER_LCAP="$(opt @minimize-marker-left  "$(printf '\xee\x82\xb6')")"
MARKER_RCAP="$(opt @minimize-marker-right "$(printf '\xee\x82\xb4')")"
# Resolve icon colour per state: 'auto' picks black/white from each state's bg; an
# explicit colour is used as-is for both.
ICONFG="$MARKER_ICON_COLOR"; ICONFG_ACTIVE="$MARKER_ICON_COLOR"
if [ "$MARKER_ICON_COLOR" = "auto" ]; then
  ICONFG="$(_contrast_fg "$MARKER_BG")"
  ICONFG_ACTIVE="$(_contrast_fg "$MARKER_BG_ACTIVE")"
fi
# A pill: rounded left cap (drawn in the bg colour on the default background), the icon on
# the bg, then the right cap. Uses SINGLE-attribute #[...] blocks (no commas) so it can be
# safely nested inside #{?pane_active,...} / #{?@minimize_active,...} — a comma inside a
# style like #[bg=x,fg=y] would split the surrounding conditional.
_pill() {  # $1 bg  $2 icon  $3 icon-fg
  printf '#[fg=%s]%s#[bg=%s]#[fg=%s]%s%s%s#[bg=default]#[fg=%s]%s' \
    "$1" "$MARKER_LCAP" "$1" "$3" "$MPAD" "$2" "$MPAD" "$1" "$MARKER_RCAP"
}
# Default marker = active/inactive pill; @minimize-marker-format still wins if set (override).
MARKER_PILL="#[align=right]#{?pane_active,$(_pill "$MARKER_BG_ACTIVE" "$MARKER_ICON_ACTIVE" "$ICONFG_ACTIVE"),$(_pill "$MARKER_BG" "$MARKER_ICON" "$ICONFG")}#[default]"
MARKER_FMT="$(opt @minimize-marker-format "$MARKER_PILL")"

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
  # Left of the marker we show the pane index by default (overridable / set '' for a
  # pill-only border); minimized panes also get the right-aligned pill.
  MARKER_LEFT="$(opt @minimize-marker-left-format '#[align=left] #{pane_index} ')"
  case "$MARKER_POS" in top|bottom) ;; *) MARKER_POS=top ;; esac  # pane-border-status only takes top|bottom
  tmux set-option -g pane-border-status "$MARKER_POS"
  tmux set-option -g pane-border-format "${MARKER_LEFT}#{?@minimize_active,${MARKER_FMT},}"
fi
