#!/usr/bin/env bash
# tmux-pane-minimize — border-marker builder.
#
# Builds the right-aligned "pill"/"flat" marker that minimized panes show on their pane
# border line, and exposes it as MARKER_FMT for pane-minimize.tmux to drop into
# pane-border-format. Factored out of the entry point because it's a self-contained
# chunk of presentation logic (colour math + glyphs) that runs once at load.
#
# Contract: source this file, then `MARKER_FMT="$(build_marker)"`. It requires opt() (the
# entry point's option reader) to already be defined, reads the @minimize-marker-* options
# itself, and PRINTS the marker format to stdout. No tmux state is mutated here.
#
# The marker is two FontAwesome chevrons: inactive/minimized points INWARD ">  <"
# (collapsed); active/peeked points OUTWARD "<  >" (expanded). Two styles:
#   flat (default) — chevrons in fg=default, which on a pane border IS the border-line
#     colour tmux already swaps per active/inactive pane, so they match it for free and
#     stay transparent. A leading space gaps them off the line.
#   pill — rounded caps + a background in the derived border colour; chevrons drawn via
#     #[reverse] ('cutout') so they punch through in the terminal bg (theme-agnostic),
#     or in an explicit/auto contrast colour.

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

# build_marker: read the @minimize-marker-* options and set MARKER_FMT (the format a
# minimized pane appends to its border line). Default glyphs are UTF-8 byte escapes
# (printf '\xHH') so no multi-byte chars live in the source (bash-3.2 safe; no $'\u').
# chevron-left = U+F053 (\xef\x81\x93), chevron-right = U+F054 (\xef\x81\x94).
build_marker() {
  local MARKER_STYLE MARKER_ICON MARKER_ICON_ACTIVE _icdef MARKER_ICON_COLOR MARKER_DEFAULT
  local MARKER_WIDTH MARKER_BG MARKER_BG_ACTIVE MPAD MARKER_LCAP MARKER_RCAP ICONFG ICONFG_ACTIVE MARKER_FMT
  MARKER_STYLE="$(opt @minimize-marker-style 'flat')"        # 'flat' (transparent) or 'pill'
  MARKER_ICON="$(opt @minimize-marker-icon "$(printf '\xef\x81\x94 \xef\x81\x93')")"
  MARKER_ICON_ACTIVE="$(opt @minimize-marker-icon-active "$(printf '\xef\x81\x93 \xef\x81\x94')")"
  # Icon-colour default depends on style. FLAT: 'default' — on a pane border, fg=default IS
  # the border line colour, which tmux already swaps per active/inactive pane, so the
  # chevrons match the border for free and stay transparent. PILL: 'cutout' — the chevrons
  # are drawn in the terminal background colour so they look punched out of the coloured
  # pill (theme-agnostic; needs no per-bg contrast guess).
  case "$MARKER_STYLE" in pill) _icdef='cutout' ;; *) _icdef='default' ;; esac
  MARKER_ICON_COLOR="$(opt @minimize-marker-icon-color "$_icdef")"

  if [ "$MARKER_STYLE" = "pill" ]; then
    MARKER_WIDTH="$(opt @minimize-marker-width '3')"          # 3 (snug) or 5 (padded)
    MARKER_BG="$(opt @minimize-marker-bg "$(_border_fg pane-border-style)")"
    MARKER_BG_ACTIVE="$(opt @minimize-marker-bg-active "$(_border_fg pane-active-border-style)")"
    [ -z "$MARKER_BG" ] && MARKER_BG='colour238'              # fallback when no border style set
    [ -z "$MARKER_BG_ACTIVE" ] && MARKER_BG_ACTIVE='colour110'
    case "$MARKER_WIDTH" in 3) MPAD='' ;; *) MPAD=' ' ;; esac
    MARKER_LCAP="$(opt @minimize-marker-left  "$(printf '\xee\x82\xb6')")"   # rounded caps U+E0B6/E0B4
    MARKER_RCAP="$(opt @minimize-marker-right "$(printf '\xee\x82\xb4')")"
    # SINGLE-attribute #[...] blocks (no commas) so the pill nests safely inside #{?...}.
    if [ "$MARKER_ICON_COLOR" = "cutout" ]; then
      # cutout: fg=bg-colour then #[reverse] -> the chevrons render in the terminal default
      # background (cut out of the pill) regardless of theme; caps stay solid bg-coloured.
      _pill() {  # $1 bg  $2 icon  ($3 unused)
        printf '#[fg=%s]%s#[reverse]%s%s%s#[noreverse]#[fg=%s]%s' \
          "$1" "$MARKER_LCAP" "$MPAD" "$2" "$MPAD" "$1" "$MARKER_RCAP"
      }
    else
      # explicit / auto: solid pill with the icon in ICONFG ('auto' -> black/white by bg).
      _pill() {  # $1 bg  $2 icon  $3 icon-fg
        printf '#[fg=%s]%s#[bg=%s]#[fg=%s]%s%s%s#[bg=default]#[fg=%s]%s' \
          "$1" "$MARKER_LCAP" "$1" "$3" "$MPAD" "$2" "$MPAD" "$1" "$MARKER_RCAP"
      }
    fi
    ICONFG="$MARKER_ICON_COLOR"; ICONFG_ACTIVE="$MARKER_ICON_COLOR"
    if [ "$MARKER_ICON_COLOR" = "auto" ]; then
      ICONFG="$(_contrast_fg "$MARKER_BG")"; ICONFG_ACTIVE="$(_contrast_fg "$MARKER_BG_ACTIVE")"
    fi
    MARKER_DEFAULT="#[align=right]#{?pane_active,$(_pill "$MARKER_BG_ACTIVE" "$MARKER_ICON_ACTIVE" "$ICONFG_ACTIVE"),$(_pill "$MARKER_BG" "$MARKER_ICON" "$ICONFG")}#[default]"
  else
    # flat: just the chevrons in the icon colour (default == the border line colour). No pill
    # background to hide them; transparent and self-matching per active/inactive state. The
    # leading space puts a gap between the border line and the chevrons.
    MARKER_DEFAULT="#[align=right]#[fg=${MARKER_ICON_COLOR}] #{?pane_active,${MARKER_ICON_ACTIVE},${MARKER_ICON}} #[default]"
  fi
  MARKER_FMT="$(opt @minimize-marker-format "$MARKER_DEFAULT")"
  printf '%s' "$MARKER_FMT"
}
