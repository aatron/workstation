#!/usr/bin/env bash
#
# review-post-comments.sh
# Post a review-make post-plan as Azure DevOps PR threads (anchored code comments
# or replies). Deterministic: the plan JSON is the only input; no LLM here.
#
# usage:
#   review-post-comments.sh <post-plan.json>
#   review-post-comments.sh --list-threads <pr-id>
#
# Plan schema (review-{id}-post-plan.json):
# {
#   "workItemId": 23597,
#   "comments": [
#     {
#       "prId": 9291,
#       "category": "major",
#       "filePath": "/src/Foo.cs",
#       "line": 42,
#       "body": "**[major]** …",
#       "replyToThreadId": null
#     }
#   ]
# }
#
# filePath + line => new anchored thread on the right (modified) side.
# replyToThreadId set => reply into that thread (no new anchor).
#
set -euo pipefail

AZ_CMD="${WT_REVIEW_AZ:-az}"
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need jq; need python3
[[ -n "${WT_REVIEW_AZ:-}" ]] || need az

usage() {
  echo "usage: review-post-comments.sh <post-plan.json>" >&2
  echo "       review-post-comments.sh --list-threads <pr-id>" >&2
  exit 1
}

# Resolve org/project/repoId for a PR id.
pr_meta() {   # pr_meta <prId> -> prId\tproject\trepoId\tstatus
  local prId="$1" json
  json="$("$AZ_CMD" repos pr show --id "$prId" -o json)" || {
    echo "could not read PR ${prId}" >&2
    return 1
  }
  jq -r '[.pullRequestId, .repository.project.name, .repository.id, .status] | @tsv' <<<"$json"
}

list_threads() {
  local prId="$1" project repoId status meta
  meta="$(pr_meta "$prId")" || return 1
  IFS=$'\t' read -r _ project repoId status <<<"$meta"
  if [[ "$status" != "active" ]]; then
    echo "WARNING: PR ${prId} status is ${status} (threads may be read-only)" >&2
  fi
  "$AZ_CMD" devops invoke \
    --area git \
    --resource pullRequestThreads \
    --route-parameters "project=${project}" "repositoryId=${repoId}" "pullRequestId=${prId}" \
    --api-version 7.1 \
    --http-method GET \
    -o json
}

post_one() {
  local prId="$1" category="$2" filePath="$3" line="$4" body="$5" replyTo="${6:-}"
  local project repoId status meta bodyfile route resource http
  meta="$(pr_meta "$prId")" || return 1
  IFS=$'\t' read -r _ project repoId status <<<"$meta"
  if [[ "$status" != "active" ]]; then
    echo "refusing to post on PR ${prId}: status is ${status}, not active" >&2
    return 1
  fi

  # Leading slash is what the ADO UI expects for file paths in threadContext.
  if [[ -n "$filePath" && "$filePath" != /* ]]; then
    filePath="/${filePath}"
  fi

  bodyfile="$(mktemp)"
  if [[ -n "$replyTo" && "$replyTo" != "null" ]]; then
    python3 - "$body" <<'PY' > "$bodyfile"
import json, sys
print(json.dumps({
    "content": sys.argv[1],
    "parentCommentId": 1,
    "commentType": "text",
}))
PY
    "$AZ_CMD" devops invoke \
      --area git \
      --resource pullRequestThreadComments \
      --route-parameters "project=${project}" "repositoryId=${repoId}" \
        "pullRequestId=${prId}" "threadId=${replyTo}" \
      --api-version 7.1 \
      --http-method POST \
      --in-file "$bodyfile" \
      -o json >/dev/null
    echo "-> replied on PR ${prId} thread ${replyTo} [${category}]"
  else
    python3 - "$body" "$filePath" "$line" <<'PY' > "$bodyfile"
import json, sys
body, path, line_s = sys.argv[1], sys.argv[2], sys.argv[3]
thread = {
    "comments": [{"parentCommentId": 0, "content": body, "commentType": "text"}],
    "status": "active",
}
if path and line_s and line_s not in ("", "null"):
    line = int(line_s)
    thread["threadContext"] = {
        "filePath": path,
        "rightFileStart": {"line": line, "offset": 1},
        "rightFileEnd": {"line": line, "offset": 1},
    }
print(json.dumps(thread))
PY
    "$AZ_CMD" devops invoke \
      --area git \
      --resource pullRequestThreads \
      --route-parameters "project=${project}" "repositoryId=${repoId}" \
        "pullRequestId=${prId}" \
      --api-version 7.1 \
      --http-method POST \
      --in-file "$bodyfile" \
      -o json >/dev/null
    if [[ -n "$filePath" && -n "$line" && "$line" != "null" ]]; then
      echo "-> posted on PR ${prId} ${filePath}:${line} [${category}]"
    else
      echo "-> posted PR-level comment on PR ${prId} [${category}]"
    fi
  fi
  rm -f "$bodyfile"
}

if [[ "${1:-}" == "--list-threads" ]]; then
  [[ -n "${2:-}" ]] || usage
  list_threads "$2"
  exit 0
fi

PLAN="${1:-}"
[[ -n "$PLAN" && -f "$PLAN" ]] || usage

jq -e '.comments | type == "array"' "$PLAN" >/dev/null || {
  echo "plan must have a comments array: ${PLAN}" >&2
  exit 1
}

count="$(jq '.comments | length' "$PLAN")"
echo "-> posting ${count} comment(s) from ${PLAN}"
posted=0
failed=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  prId="$(jq -r '.prId' <<<"$row")"
  category="$(jq -r '.category // "medium"' <<<"$row")"
  filePath="$(jq -r '.filePath // empty' <<<"$row")"
  line="$(jq -r '.line // empty' <<<"$row")"
  body="$(jq -r '.body // empty' <<<"$row")"
  replyTo="$(jq -r '.replyToThreadId // empty' <<<"$row")"
  if [[ -z "$body" ]]; then
    echo "WARNING: skipping empty body for PR ${prId}" >&2
    failed=$((failed + 1))
    continue
  fi
  # Always include category in the posted markdown when the body omitted it.
  if ! grep -qF "[${category}]" <<<"$body"; then
    body="**[${category}]** ${body}"
  fi
  if post_one "$prId" "$category" "$filePath" "$line" "$body" "$replyTo"; then
    posted=$((posted + 1))
  else
    failed=$((failed + 1))
  fi
done < <(jq -c '.comments[]' "$PLAN")

echo "-> done: ${posted} posted, ${failed} failed"
(( failed == 0 )) || exit 1
exit 0
