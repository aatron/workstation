#!/usr/bin/env bash
#
# review-wait-ready.sh
# Block until every given file exists, is large enough, and contains a marker
# line. Used by the review pipeline between stages (findings → cross → reconcile).
#
# usage:
#   review-wait-ready.sh --marker 'Verified sound' [--min-bytes 100] FILE...
#
# Exit 0 when all files are ready. Exit 1 on timeout or bad args.
# Env: WT_REVIEW_WAIT_SECONDS (default 1800 = 30 min), WT_REVIEW_WAIT_POLL (default 10).
#
set -euo pipefail

usage() {
  echo "usage: review-wait-ready.sh --marker TEXT [--min-bytes N] FILE..." >&2
  exit 1
}

marker=""
min_bytes=100
files=()
while (($# > 0)); do
  case "$1" in
    --marker) [[ $# -ge 2 ]] || usage; marker="$2"; shift 2 ;;
    --min-bytes) [[ $# -ge 2 ]] || usage; min_bytes="$2"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; files+=("$@"); break ;;
    *) files+=("$1"); shift ;;
  esac
done

[[ -n "$marker" ]] || usage
((${#files[@]} >= 1)) || usage
max_sec="${WT_REVIEW_WAIT_SECONDS:-1800}"
poll_sec="${WT_REVIEW_WAIT_POLL:-10}"
(( max_sec > 0 && poll_sec > 0 && min_bytes >= 0 )) || {
  echo "WT_REVIEW_WAIT_* / --min-bytes must be non-negative; wait seconds > 0" >&2
  exit 1
}

ready() {
  local f="$1" n
  [[ -f "$f" ]] || return 1
  n="$(wc -c <"$f" | tr -d '[:space:]')"
  (( n >= min_bytes )) || return 1
  # Case-insensitive: models often write "Verified Sound" vs "Verified sound".
  grep -qiF "$marker" "$f"
}

elapsed=0
while (( elapsed <= max_sec )); do
  all=1
  for f in "${files[@]}"; do
    ready "$f" || { all=0; break; }
  done
  if (( all )); then
    echo "Ready (${elapsed}s): ${files[*]}"
    exit 0
  fi
  parts=()
  for f in "${files[@]}"; do
    n=0
    [[ -f "$f" ]] && n="$(wc -c <"$f" | tr -d '[:space:]')"
    parts+=("$(basename "$f")=${n}b")
  done
  echo "Waiting: ${parts[*]} (${elapsed}s / ${max_sec}s)"
  sleep "$poll_sec"
  elapsed=$((elapsed + poll_sec))
done

echo "Timeout after ${max_sec}s waiting for marker '${marker}' in:" >&2
printf '  %s\n' "${files[@]}" >&2
exit 1
