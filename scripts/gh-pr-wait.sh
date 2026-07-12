#!/usr/bin/env bash
#
# Wait for a GitHub pull request's CI checks and Copilot code
# review to complete, then print a verdict with the recommended
# next step. Distinguishes a real review from the "quota
# exhausted" placeholder that github-copilot[bot] leaves when
# it cannot review the PR.
#
# This is the reusable core of the GitHub PR workflow described
# in the global AGENTS.md. It is project-agnostic: it works on
# any repository where `gh` is authenticated and can see the PR.
#
# Usage:
#   gh-pr-wait.sh <pr-number>
#   gh-pr-wait.sh <pr-number> --max-ci <seconds>
#   gh-pr-wait.sh <pr-number> --max-review <seconds>
#   gh-pr-wait.sh <pr-number> --no-review
#   gh-pr-wait.sh --help
#
# Defaults:
#   --max-ci      600  (10 minutes)
#   --max-review  300  (5 minutes; returns early on the
#                       "quota exhausted" placeholder)
#
# Output (stdout, structured):
#   - "=== PHASE 1: CI ===" with progress lines
#   - "=== PHASE 2: COPILOT REVIEW ===" with progress lines
#   - "=== VERDICT ===" with PR number, CI state, review state,
#     and a recommended next step.
#
# Exit codes:
#   0  CI green AND review received (real or quota-exhausted)
#   1  Invalid arguments
#   2  Prerequisites missing (gh, auth, PR not found, not open)
#   3  CI failed or was cancelled
#   4  Timed out waiting for CI
#   5  Timed out waiting for Copilot review
#   6  Copilot requested changes (no mergeable verdict)
#
# Requirements:
#   * gh (GitHub CLI), authenticated (`gh auth status`).
#   * python3, for JSON parsing.
#   * A Git repository with a GitHub `origin` remote and the
#     PR must be open.

set -euo pipefail

MAX_CI=600
MAX_REVIEW=300
SKIP_REVIEW=0
PR_NUMBER=""

usage() {
    # Print the top-of-file header (the contiguous comment block
    # after the shebang) with the leading `#` and optional space
    # stripped. Stops at the first non-comment line so internal
    # section headers below are not pulled in. Robust against
    # edits that change the header length.
    awk 'NR == 1 {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --max-ci) MAX_CI="$2"; shift 2 ;;
        --max-review) MAX_REVIEW="$2"; shift 2 ;;
        --no-review) SKIP_REVIEW=1; shift ;;
        --) shift; break ;;
        -*) echo "error: unknown flag: $1" >&2; usage 1 ;;
        *)
            if [[ -z "$PR_NUMBER" ]]; then
                PR_NUMBER="$1"
            else
                echo "error: unexpected extra argument: $1" >&2; usage 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$PR_NUMBER" ]]; then
    echo "error: PR number required" >&2
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

# Use --json so we do not trigger gh's default-text-view GraphQL
# deprecation warning for Projects (classic). Doing both the
# existence check and the state fetch in a single --json call
# also halves the GraphQL round-trips we make before phase 1.
pr_state=$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>/dev/null || echo "")
if [[ -z "$pr_state" ]]; then
    echo "error: PR #$PR_NUMBER not found in this repository" >&2
    exit 2
fi
if [[ "$pr_state" != "OPEN" ]]; then
    echo "error: PR #$PR_NUMBER is $pr_state (not open)" >&2
    exit 2
fi

# --- helpers ---

# Reads the PR's status check rollup and prints one line per
# check in "<name>|<state>" format. If there are no checks
# configured for the PR, prints "NO_CHECKS" and exits 0.
# On failure (gh error, malformed JSON, etc.) prints a
# diagnostic to stderr and exits 9 so the caller can abort
# instead of silently treating the empty stdout as "no CI".
ci_state() {
    if ! out=$(gh pr view "$PR_NUMBER" --json statusCheckRollup 2>&1); then
        echo "ci_state: gh pr view failed:" >&2
        echo "$out" >&2
        return 9
    fi
    if ! parsed=$(printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rollup = d.get("statusCheckRollup") or []
if not rollup:
    print("NO_CHECKS")
    sys.exit(0)
for c in rollup:
    name = c.get("name") or c.get("context") or "unknown"
    state = (c.get("conclusion") or c.get("state") or "-").upper()
    print(f"{name}|{state}")
' 2>&1); then
        echo "ci_state: failed to parse statusCheckRollup:" >&2
        echo "$parsed" >&2
        return 9
    fi
    printf '%s\n' "$parsed"
}

# Reads the PR's reviews and prints the most recent Copilot
# review state. Recognises the "quota exhausted" placeholder
# that github-copilot[bot] leaves when it cannot review.
# Same failure-mode contract as ci_state: writes a diagnostic
# to stderr and returns 9 on failure.
#
# Implementation note: the Python source is passed via a quoted
# heredoc inside command substitution (`$(cat <<'PYEOF' ... PYEOF)`)
# so the single quotes inside the f-string (`'state'`, `'COMMENTED'`)
# survive intact. Naively using `python3 -c '...'` with a single-quoted
# bash string would have bash strip those inner single quotes, and
# Python would then see `r.get(state, COMMENTED)` and raise
# `NameError: name 'state' is not defined`. This bit me once;
# keep the heredoc form.
review_state() {
    if ! out=$(gh pr view "$PR_NUMBER" --json reviews 2>&1); then
        echo "review_state: gh pr view failed:" >&2
        echo "$out" >&2
        return 9
    fi
    parsed=$(printf '%s' "$out" | python3 -c "$(cat <<'PYEOF'
import json, sys
d = json.load(sys.stdin)
for r in d.get("reviews") or []:
    login = r["author"]["login"].lower()
    if "copilot" not in login:
        continue
    body = (r.get("body") or "").lower()
    if "quota" in body and "limit" in body:
        print("COPILOT_QUOTA")
    else:
        print(f"COPILOT_{r.get('state', 'COMMENTED').upper()}")
    sys.exit(0)
print("NO_REVIEW")
PYEOF
)" 2>&1) || {
        echo "review_state: failed to parse reviews:" >&2
        echo "$parsed" >&2
        return 9
    }
    printf '%s\n' "$parsed"
}

# --- phase 1: CI ---

echo "=== PHASE 1: CI ==="
ci_lines=()
ci_start=$SECONDS
while true; do
    if ! ci_out=$(ci_state); then
        echo "  ci_state failed; aborting (the helper already printed a diagnostic to stderr)" >&2
        exit 2
    fi
    mapfile -t ci_lines <<< "$ci_out"
    if [[ ${#ci_lines[@]} -eq 0 ]] || [[ "${ci_lines[0]}" == "NO_CHECKS" ]]; then
        echo "  no CI checks configured for this PR; skipping phase 1"
        ci_lines=()
        break
    fi
    failed=0
    pending=0
    for line in "${ci_lines[@]}"; do
        IFS='|' read -r _ state <<< "$line"
        case "$state" in
            SUCCESS) ;;
            FAILURE|CANCELLED|TIMED_OUT|SKIPPED) failed=1 ;;
            *) pending=1 ;;
        esac
    done
    if [[ $failed -eq 1 ]]; then
        echo "  CI FAILED:"
        printf '    %s\n' "${ci_lines[@]}"
        exit 3
    fi
    if [[ $pending -eq 0 ]]; then
        echo "  CI green:"
        printf '    %s\n' "${ci_lines[@]}"
        break
    fi
    elapsed=$((SECONDS - ci_start))
    if [[ $elapsed -ge $MAX_CI ]]; then
        echo "  timed out after ${elapsed}s waiting for CI:" >&2
        printf '    %s\n' "${ci_lines[@]}" >&2
        exit 4
    fi
    echo "  [${elapsed}s] ${ci_lines[*]}"
    sleep 15
done

# --- phase 2: review ---

if [[ $SKIP_REVIEW -eq 1 ]]; then
    state="SKIPPED"
    echo
    echo "=== PHASE 2: COPILOT REVIEW ==="
    echo "  --no-review set; skipping phase 2"
else
    echo
    echo "=== PHASE 2: COPILOT REVIEW ==="
    review_start=$SECONDS
    while true; do
        if ! state=$(review_state); then
            echo "  review_state failed; aborting (the helper already printed a diagnostic to stderr)" >&2
            exit 2
        fi
        case "$state" in
            COPILOT_QUOTA)
                echo "  github-copilot[bot] left a 'quota exhausted' placeholder; no actionable review."
                break
                ;;
            COPILOT_APPROVED|COPILOT_CHANGES_REQUESTED|COPILOT_COMMENTED)
                echo "  github-copilot[bot] posted a review: $state"
                break
                ;;
            NO_REVIEW)
                elapsed=$((SECONDS - review_start))
                if [[ $elapsed -ge $MAX_REVIEW ]]; then
                    echo "  timed out after ${elapsed}s waiting for Copilot review" >&2
                    exit 5
                fi
                echo "  [${elapsed}s] waiting..."
                sleep 15
                ;;
        esac
    done
fi

# --- verdict ---

echo
echo "=== VERDICT ==="
echo "PR:     #$PR_NUMBER"
if [[ ${#ci_lines[@]} -eq 0 ]]; then
    echo "CI:     (no checks configured)"
else
    echo "CI:     ${ci_lines[*]}"
fi
echo "Review: $state"
echo
case "$state" in
    SKIPPED)
        cat <<'EOF'
Next step:
  --no-review was set; no Copilot review is expected on this
  repo. Proceed directly to `gh pr merge <N> --squash
  --delete-branch` (or, for a FORK, hand the merge to the
  upstream maintainer).
EOF
        ;;
    COPILOT_QUOTA)
        cat <<'EOF'
Next step:
  github-copilot[bot] left a "quota exhausted" placeholder
  instead of a real review. Leave a brief PR comment
  acknowledging the quota limitation (e.g. "Copilot was unable
  to review (quota limit); proceeding to merge"), then proceed
  to `gh pr merge <N> --squash --delete-branch` (or, for a
  FORK, hand the merge to the upstream maintainer).
EOF
        ;;
    COPILOT_APPROVED|COPILOT_COMMENTED)
        cat <<'EOF'
Next step:
  Read the review comments with
  `gh api /repos/<owner>/<repo>/pulls/<N>/comments` (and the
  review body via `gh pr view <N> --json reviews`). For each
  comment: address it (commit/push if applying), then post a
  reply explaining the resolution and resolve the thread with
  `~/.config/opencode/scripts/gh-pr-resolve-thread.sh <N>
   <comment-id> "<reply-body>"`. When every thread is resolved,
  merge with `gh pr merge <N> --squash --delete-branch`.
EOF
        ;;
    COPILOT_CHANGES_REQUESTED)
        cat <<'EOF'
Next step:
  Address the requested changes, push follow-up commits,
  then for each outstanding review comment post a reply
  explaining the resolution and resolve the thread with
  `~/.config/opencode/scripts/gh-pr-resolve-thread.sh <N>
   <comment-id> "<reply-body>"`. Re-run this script to
  re-check CI and the new review state.
EOF
        exit 6
        ;;
    *)
        cat <<'EOF'
Next step:
  Unexpected review state; inspect the PR manually with
  `gh pr view <N> --json state,reviews,statusCheckRollup`
  and decide.
EOF
        exit 1
        ;;
esac

exit 0
