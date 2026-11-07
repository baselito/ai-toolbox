#!/bin/bash
# loop-config.sh — resolve the numeric loop contract for the current project.
#
# Output is deliberately a single scalar selected by --value. Callers consume
# it as data; no value from PROJECT.md is ever evaluated as shell code.

set -uo pipefail

# PROJECT.md is untrusted input. Keep awk and every other helper on fixed
# system locations so a checkout cannot replace the resolver itself.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin"
export PATH

DEFAULT_TURNS=25
MAX_TURNS=60
DEFAULT_NO_PROGRESS=2
MAX_NO_PROGRESS=5
DEFAULT_SPEND="2.00"
MAX_SPEND="10.00"

die() {
  echo "loop-config: $1" >&2
  exit 2
}

read_loop_value() {
  local file="$1" key="$2"
  awk -v wanted="$key" '
    /^loop:[[:space:]]*$/ { inside=1; next }
    inside && /^[^[:space:]]/ { exit }
    inside && $0 ~ "^[[:space:]]+" wanted ":[[:space:]]*" {
      value=$0
      sub("^[[:space:]]+" wanted ":[[:space:]]*", "", value)
      sub("[[:space:]]+#.*$", "", value)
      print value
      exit
    }
  ' "$file"
}

positive_integer_or_default() {
  local raw="$1" fallback="$2" ceiling="$3"
  if [[ "$raw" =~ ^[0-9]+$ ]] && (( 10#${raw:-0} > 0 )); then
    if (( 10#$raw > ceiling )); then
      echo "$ceiling"
    else
      echo "$((10#$raw))"
    fi
  else
    echo "$fallback"
  fi
}

positive_decimal_or_default() {
  local raw="$1" fallback="$2" ceiling="$3"
  if [[ "$raw" =~ ^([0-9]+)(\.[0-9]+)?$ ]] \
    && awk -v n="$raw" 'BEGIN { exit !(n > 0) }'; then
    if awk -v n="$raw" -v max="$ceiling" 'BEGIN { exit !(n > max) }'; then
      printf '%s\n' "$ceiling"
    else
      printf '%s\n' "$raw"
    fi
  else
    printf '%s\n' "$fallback"
  fi
}

VALUE=""
if [[ "${1-}" == "--value" && $# -eq 2 ]]; then
  VALUE="$2"
else
  die "usage: $0 --value max_turns|no_progress_after|max_spend_usd"
fi

PROJECT_FILE=".claude/PROJECT.md"
if [[ -e "$PROJECT_FILE" && ! -f "$PROJECT_FILE" ]]; then
  die "$PROJECT_FILE exists but is not a regular file"
fi
if [[ -e "$PROJECT_FILE" && ! -r "$PROJECT_FILE" ]]; then
  die "$PROJECT_FILE is not readable"
fi

RAW=""
if [[ -f "$PROJECT_FILE" ]]; then
  RAW=$(read_loop_value "$PROJECT_FILE" "$VALUE")
fi

case "$VALUE" in
  max_turns)
    positive_integer_or_default "$RAW" "$DEFAULT_TURNS" "$MAX_TURNS"
    ;;
  no_progress_after)
    positive_integer_or_default "$RAW" "$DEFAULT_NO_PROGRESS" "$MAX_NO_PROGRESS"
    ;;
  max_spend_usd)
    positive_decimal_or_default "$RAW" "$DEFAULT_SPEND" "$MAX_SPEND"
    ;;
  *)
    die "unknown value: $VALUE"
    ;;
esac
