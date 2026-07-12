#!/usr/bin/env bash
#
# Post a reply to a PR review comment thread and resolve the thread.
# Used by the GitHub PR workflow (see ~/.config/opencode/AGENTS.md
# and ~/.config/opencode/skills/github_pr_workflow/SKILL.md) to
# close the loop on each Copilot review comment: after addressing
# (or rejecting) the feedback, the agent posts a reply explaining
# what was done and resolves the conversation, so the PR's
# "unresolved conversations" count stays at zero.
#
# Usage:
#   gh-pr-resolve-thread.sh <pr-number> <review-comment-id> "<reply-body>"
#   gh-pr-resolve-thread.sh --help
#
# Arguments:
#   pr-number         The PR number (e.g. 42).
#   review-comment-id The integer database id of the review
#                     comment (the `id` field in the response of
#                     `gh api /repos/<owner>/<repo>/pulls/<N>/comments`).
#   reply-body        The body of the reply to post. The script
#                     does not interpret it. Pass a clear
#                     explanation of what was done (or why the
#                     comment is not being applied), ideally
#                     referencing the commit SHA, file, and line.
#
# Example:
#   gh-pr-resolve-thread.sh 42 1234567890 \
#     "Fixed in abc1234: extracted the validation into a separate
#      function in src/foo.rs:42; this also lets us test it
#      in isolation."
#
# The script is idempotent: if the thread is already resolved,
# it exits 0 without re-posting the reply.
#
# Requirements:
#   * gh CLI, authenticated (`gh auth status` must succeed).
#   * python3, for JSON parsing.
#   * The PR must be open and accessible.
#
# Exit codes:
#   0  Reply posted and thread resolved (or thread was already resolved)
#   1  Invalid arguments
#   2  Prerequisites missing
#   3  Comment not found in any review thread on the PR
#   4  GraphQL query failed (e.g. auth, network, or returned
#      an `errors` envelope). Distinct from "not found" so the
#      agent does not silently re-label a real bug as a missing
#      comment id.
#   5  REST/GraphQL mutation failed (reply post or thread resolve)

set -euo pipefail

usage() {
    awk 'NR == 1 {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

PR_NUMBER=""
COMMENT_DB_ID=""
REPLY_BODY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --) shift; break ;;
        -*) echo "error: unknown flag: $1" >&2; usage 1 ;;
        *)
            if [[ -z "${PR_NUMBER}" ]]; then
                PR_NUMBER="$1"
            elif [[ -z "${COMMENT_DB_ID}" ]]; then
                COMMENT_DB_ID="$1"
            elif [[ -z "${REPLY_BODY}" ]]; then
                REPLY_BODY="$1"
            else
                echo "error: unexpected extra argument: $1" >&2; usage 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${PR_NUMBER}" ]] || [[ -z "${COMMENT_DB_ID}" ]] || [[ -z "${REPLY_BODY}" ]]; then
    echo "error: PR number, review comment id, and reply body are all required" >&2
    usage 1
fi

# --- prerequisites ---

if ! command -v gh >/dev/null 2>&1; then
    echo "error: 'gh' CLI not found; install from https://cli.github.com/" >&2
    exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: 'python3' not found; required for JSON parsing" >&2
    exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "error: 'gh' is not authenticated; run 'gh auth login'" >&2
    exit 2
fi

OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
if [[ -z "${OWNER_REPO}" ]]; then
    echo "error: could not determine owner/repo from 'origin'" >&2
    exit 2
fi

# --- 1. find the review thread that contains the comment ---

# The REST API exposes comment database ids but not thread node
# ids, and the resolveReviewThread mutation requires a thread
# node id (a global id of the form "PRRT_..."). We go through
# GraphQL to translate.
#
# Exit-code contract for the python step below:
#   0  comment id matched a thread; stdout is "<thread_id> <resolved>"
#   1  comment id did not match any thread in the PR
#   2  the GraphQL response itself was an error (auth, network,
#      `errors` envelope). The bash wrapper MUST surface this as
#      a distinct error and NOT re-label it as "comment not found"
#      — that conflation is what masked the previous bug.
# shellcheck disable=SC2016  # $owner/$name/$prNumber are GraphQL vars, not bash vars
THREAD_INFO=$(gh api graphql \
    -F owner="${OWNER_REPO%/*}" \
    -F name="${OWNER_REPO#*/}" \
    -F prNumber="${PR_NUMBER}" \
    -f query='query($owner: String!, $name: String!, $prNumber: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 50) {
            nodes { databaseId }
          }
        }
      }
    }
  }
}' 2>/dev/null | python3 -c "
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError as e:
    print('graphql: malformed JSON in response:', e, file=sys.stderr)
    sys.exit(2)
errs = d.get('errors')
if errs:
    for e in errs:
        msg = e.get('message') if isinstance(e, dict) else str(e)
        print('graphql:', msg, file=sys.stderr)
    sys.exit(2)
threads = d.get('data', {}).get('repository', {}).get('pullRequest', {}).get('reviewThreads', {}).get('nodes', [])
if not threads and 'data' not in d:
    print('graphql: response had no data field', file=sys.stderr)
    sys.exit(2)
target = str(sys.argv[1])
for t in threads:
    for c in t.get('comments', {}).get('nodes', []):
        if str(c.get('databaseId')) == target:
            print(t['id'], '1' if t.get('isResolved') else '0')
            sys.exit(0)
sys.exit(1)
" "${COMMENT_DB_ID}")
gh_rc=$?
if [[ $gh_rc -eq 0 ]]; then
    :
elif [[ $gh_rc -eq 1 ]]; then
    echo "error: comment ${COMMENT_DB_ID} not found in any review thread on PR #${PR_NUMBER}" >&2
    exit 3
else
    echo "error: GraphQL query for PR #${PR_NUMBER} failed (rc=${gh_rc}); see stderr above" >&2
    exit 4
fi

THREAD_ID=$(echo "${THREAD_INFO}" | awk '{print $1}')
RESOLVED=$(echo "${THREAD_INFO}" | awk '{print $2}')

if [[ "${RESOLVED}" == "1" ]]; then
    echo "thread ${THREAD_ID} (comment ${COMMENT_DB_ID}) is already resolved; nothing to do"
    exit 0
fi

# --- 2. post the reply ---

echo "posting reply to comment ${COMMENT_DB_ID} on PR #${PR_NUMBER}..."
if ! gh api -X POST \
    "/repos/${OWNER_REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_DB_ID}/replies" \
    -f body="${REPLY_BODY}" >/dev/null; then
    echo "error: failed to post reply on comment ${COMMENT_DB_ID}" >&2
    exit 5
fi

# --- 3. resolve the thread ---

echo "resolving thread ${THREAD_ID}..."
# shellcheck disable=SC2016  # $threadId is a GraphQL var, not a bash var
if ! gh api graphql \
    -F threadId="${THREAD_ID}" \
    -f query='mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}' >/dev/null; then
    echo "error: reply posted, but failed to resolve thread ${THREAD_ID}" >&2
    echo "       run this script again to resolve the thread (it is idempotent on the resolve step)" >&2
    exit 5
fi

echo "done: reply posted and thread ${THREAD_ID} resolved"
