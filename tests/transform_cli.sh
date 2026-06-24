#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/transform.sh
. "$DIR/../scripts/transform.sh"

MIN_H="$1"
MIN_W="$2"
ABS_MIN_H="$3"
BORDER_POS="$4"
LAYOUT="$5"
MINSET="$6"
SAVEDW="$7"
WPANE="$8"
WVAL="$9"
MINH="${10}"

transform "$LAYOUT" "$MINSET" "$SAVEDW" "$WPANE" "$WVAL" "$MINH"
