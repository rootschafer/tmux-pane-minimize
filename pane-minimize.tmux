#!/usr/bin/env bash
# tmux-pane-minimize — TPM entry point.
# Collapse a pane to a few lines and restore it, keeping minimized panes pinned
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
MARKER="$(opt @minimize-marker 'off')"
MENU="$(opt @minimize-menu 'off')"
MARKER_POS="$(opt @minimize-marker-position 'top')"
MARKER_FMT="$(opt @minimize-marker-format '#[align=right]#[fg=colour214]#[bold]  󰘖 #[default]')"
GROW=$(( HEIGHT + 1 ))   # "manually resized" threshold: taller than this => forget

# Toggle key (prefix table).
tmux bind-key "$KEY" run-shell "$SCRIPT toggle #{pane_id}"

# Right-click menu (opt-in). This is the reliable click path: a pane mouse event
# resolves #{pane_id} to the exact moused pane (border clicks do not, and a content
# click would steal a cell from child TUIs). The menu's first item toggles minimize;
# the rest mirror handy defaults so right-click stays useful. The whole display-menu
# is one quoted string so tmux parses the item triples as the bound command.
if [ "$MENU" = "on" ]; then
  tmux bind-key -T root MouseDown3Pane "display-menu -t = -x M -y M -T \"#[align=centre]#{pane_index}\" \"#{?@minimize_active,Un-Minimize,Minimize}\" m \"run-shell '$SCRIPT toggle #{pane_id}'\" \"\" \"#{?window_zoomed_flag,Unzoom,Zoom}\" z \"resize-pane -Z\" \"Swap Up\" u \"swap-pane -U\" \"Swap Down\" d \"swap-pane -D\" \"\" \"Kill\" X \"kill-pane\""
fi

# Forget minimized state when the user resizes a pane themselves.
#  - keyboard / resize-pane command fires after-resize-pane
#  - @minimize_guard skips the plugin's own resizes
#  - only clear when the pane is clearly taller than minimized (tolerates the
#    1-row border-status nibble on an edge pane)
tmux set-hook -g after-resize-pane \
  "if-shell -F '#{&&:#{!=:#{@minimize_guard},1},#{&&:#{@minimize_active},#{>:#{pane_height},$GROW}}}' 'set-option -p @minimize_active 0'"

# Terminal/window resize rescales panes (fires after-resize-window, not
# after-resize-pane) -> re-pin every minimized pane.
tmux set-hook -g after-resize-window "run-shell -b \"$SCRIPT repin #{window_id}\""

# Mouse: a border drag resizes internally (no per-step hook); MouseDragEnd1Border
# fires on release. Forget any minimized pane that was dragged clearly taller.
# The trailing ': ok' forces exit 0 — otherwise the loop's last failed &&-test
# would make run-shell report a non-zero exit and dump the command into the pane.
tmux bind-key -T root MouseDragEnd1Border run-shell -b \
  "tmux list-panes -t '#{window_id}' -F '##{pane_id} ##{?@minimize_active,1,0} ##{pane_height}' | while read id a h; do { [ \"\$a\" = 1 ] && [ \"\$h\" -gt $GROW ]; } && tmux set-option -t \"\$id\" -p @minimize_active 0; done; : ok"

# Opt-in marker: only when @minimize-marker is "on" do we touch pane-border-*.
# Minimized panes show MARKER_FMT (a state indicator); normal panes show nothing.
if [ "$MARKER" = "on" ]; then
  case "$MARKER_POS" in top|bottom) ;; *) MARKER_POS=top ;; esac  # pane-border-status only takes top|bottom
  tmux set-option -g pane-border-status "$MARKER_POS"
  tmux set-option -g pane-border-format "#{?@minimize_active,${MARKER_FMT},}"
fi
