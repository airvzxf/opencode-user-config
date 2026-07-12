#!/usr/bin/env bash
#
# Classify the current project so the agent can pick the right
# GitHub protocol (OWNER, FORK, or READ_ONLY) without the user
# having to spell it out every time.
#
# Background:
#   The user works on three kinds of GitHub projects and was tired
#   of the agent asking which one each session:
#
#     1. OWNER     — repo under their own account. Branch, push,
#                    open issue, open PR, wait for CI + review,
#                    squash-merge. Full 10-step protocol.
#     2. FORK      — repo under their own account but forked from
#                    someone else's project. Same protocol up to
#                    and including opening the PR, but DO NOT
#                    auto-merge: the upstream owner has to approve
#                    and merge it.
#     3. READ_ONLY — repo they cloned to test something quickly.
#                    viewerPermission is READ or NONE (or `gh` is
#                    not authenticated against it). No commits,
#                    no PR, no issue. Local edits only.
#
#   Anything that is not on github.com (or not a git repo at all)
#   falls out of the protocol entirely; the script reports that
#   and exits a distinct code so the caller can branch.
#
# Usage:
#   gh-project-classify.sh                # human-readable output
#   gh-project-classify.sh --json         # machine-readable output
#   gh-project-classify.sh --help
#
# Output (stdout):
#   A short block of "key: value" lines followed by a one-line
#   protocol hint. With --json the same data is emitted as a single
#   JSON object on one line so the agent can parse it with
#   `python3 -c "import json, sys; ..."`.
#
# Exit codes (chosen so the caller can `case` on them safely
# without colliding with common Unix codes):
#   0   OWNER         — repo under the user's account, not a fork
#   10  FORK          — repo under the user's account, fork of an
#                       upstream project. PR, no auto-merge.
#   20  READ_ONLY     — repo the user cannot push to. Local edits
#                       only, no commits, no PRs.
#   30  NOT_GITHUB    — origin does not point at github.com (or
#                       `gh` cannot see the repo). Out of scope
#                       for the GitHub protocol.
#   40  NOT_GIT       — not inside a Git working tree.
#
# Requirements:
#   * git, on PATH.
#   * gh (GitHub CLI) only required when the project IS a GitHub
#     repo. The script tolerates its absence for the NOT_GITHUB
#     and NOT_GIT paths.

set -euo pipefail

JSON=0

usage() {
    awk 'NR == 1 {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --json) JSON=1; shift ;;
        --) shift; break ;;
        -*) echo "error: unknown flag: $1" >&2; usage 1 ;;
        *) echo "error: unexpected extra argument: $1" >&2; usage 1 ;;
    esac
done

# --- 1. is this a git working tree? ---

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ $JSON -eq 1 ]]; then
        python3 -c "
import json, sys
print(json.dumps({'type': 'NOT_GIT', 'reason': 'not inside a Git working tree'}))
"
    else
        echo "type:     NOT_GIT"
        echo "reason:   not inside a Git working tree"
        echo "protocol: none (not a Git project)"
    fi
    exit 40
fi

# --- 2. does the origin point at GitHub? ---

origin=$(git remote get-url origin 2>/dev/null || true)
if [[ -z "$origin" ]] || ! echo "$origin" | grep -qE 'github\.com[/:]'; then
    if [[ $JSON -eq 1 ]]; then
        python3 -c "
import json, sys
print(json.dumps({'type': 'NOT_GITHUB', 'origin': sys.argv[1]}))
" "${origin:-}"
    else
        echo "type:     NOT_GITHUB"
        echo "origin:   ${origin:-<none>}"
        echo "protocol: none (not a GitHub project; the GitHub protocol"
        echo "          does not apply; fall back to project-local rules)"
    fi
    exit 30
fi

# --- 3. is `gh` available and authenticated against this repo? ---

if ! command -v gh >/dev/null 2>&1; then
    if [[ $JSON -eq 1 ]]; then
        python3 -c "
import json, sys
print(json.dumps({
    'type': 'NOT_GITHUB',
    'origin': sys.argv[1],
    'reason': 'gh CLI not installed',
}))
" "$origin"
    else
        echo "type:     NOT_GITHUB"
        echo "origin:   $origin"
        echo "reason:   gh CLI is not installed; cannot determine the"
        echo "          GitHub-side permissions"
        echo "protocol: none until gh is installed and authenticated"
    fi
    exit 30
fi

if ! gh auth status >/dev/null 2>&1; then
    if [[ $JSON -eq 1 ]]; then
        python3 -c "
import json, sys
print(json.dumps({
    'type': 'NOT_GITHUB',
    'origin': sys.argv[1],
    'reason': 'gh not authenticated',
}))
" "$origin"
    else
        echo "type:     NOT_GITHUB"
        echo "origin:   $origin"
        echo "reason:   gh is not authenticated; cannot determine the"
        echo "          GitHub-side permissions"
        echo "protocol: none until gh is authenticated"
    fi
    exit 30
fi

# --- 4. fetch viewerPermission, nameWithOwner, parent ---

if ! metadata=$(gh repo view --json viewerPermission,nameWithOwner,parent 2>/dev/null); then
    if [[ $JSON -eq 1 ]]; then
        python3 -c "
import json, sys
print(json.dumps({
    'type': 'NOT_GITHUB',
    'origin': sys.argv[1],
    'reason': 'gh repo view failed (repo may be private and inaccessible)',
}))
" "$origin"
    else
        echo "type:     NOT_GITHUB"
        echo "origin:   $origin"
        echo "reason:   gh repo view failed; the repo may be private and"
        echo "          inaccessible to the authenticated user"
        echo "protocol: none until the user can see the repo"
    fi
    exit 30
fi

# The viewerPermission, nameWithOwner, and parent fields are
# simple scalars or small objects; parse with python3 because
# the JSON may contain nested quotes and we want to avoid any
# bash quoting pitfalls (the same one the gh-pr-wait.sh heredoc
# note warns about).
#
# We emit the three fields on separate lines with a tag prefix
# rather than whitespace-separated values, because `read` with
# the default IFS collapses runs of whitespace and the empty
# parent case (FORK absent) would shift fields into the wrong
# variables. One tagged line per field is unambiguous.
#
# The python source is passed via a quoted heredoc inside
# command substitution so single quotes inside the f-strings
# survive intact (same trick as gh-pr-wait.sh).
parsed=$(printf '%s' "$metadata" | python3 -c "$(cat <<'PYEOF'
import json, sys
d = json.load(sys.stdin)
nwo = d.get("nameWithOwner") or ""
perm = d.get("viewerPermission") or ""
parent_obj = d.get("parent") or {}
# `parent` on the GraphQL side is { id, name, owner: { login } };
# assemble nameWithOwner ourselves because the field is not
# returned directly.
parent_owner = (parent_obj.get("owner") or {}).get("login") or ""
parent_name = parent_obj.get("name") or ""
parent_nwo = f"{parent_owner}/{parent_name}" if parent_owner and parent_name else ""
print(f"NWO:{nwo}")
print(f"PARENT:{parent_nwo}")
print(f"PERM:{perm}")
PYEOF
)")
nwo=$(printf '%s\n' "$parsed" | sed -n 's/^NWO://p')
parent=$(printf '%s\n' "$parsed" | sed -n 's/^PARENT://p')
permission=$(printf '%s\n' "$parsed" | sed -n 's/^PERM://p')

# --- 5. classify ---

if [[ "$permission" != "WRITE" && "$permission" != "MAINTAIN" && "$permission" != "ADMIN" ]]; then
    if [[ $JSON -eq 1 ]]; then
        python3 -c "
import json, sys
print(json.dumps({
    'type': 'READ_ONLY',
    'origin': sys.argv[1],
    'repo': sys.argv[2],
    'permission': sys.argv[3],
    'protocol': 'local edits only; no commits, no PRs, no issues',
}))
" "$origin" "$nwo" "$permission"
    else
        echo "type:      READ_ONLY"
        echo "origin:    $origin"
        echo "repo:      $nwo"
        echo "permission: ${permission:-NONE}"
        echo ""
        echo "This repo is on GitHub but the authenticated user cannot"
        echo "push to it (typical: cloned someone else's repo to test"
        echo "something quickly). Do not commit, do not open a PR, do"
        echo "not open an issue. Local edits are fine for exploration."
    fi
    exit 20
fi

# Push permission granted: OWNER or FORK depending on whether
# there is an upstream parent.
if [[ -n "$parent" ]]; then
    if [[ $JSON -eq 1 ]]; then
        python3 -c "
import json, sys
print(json.dumps({
    'type': 'FORK',
    'origin': sys.argv[1],
    'repo': sys.argv[2],
    'permission': sys.argv[3],
    'upstream': sys.argv[4],
    'protocol': 'branch + PR + CI + review; wait for upstream approval (no auto-merge)',
}))
" "$origin" "$nwo" "$permission" "$parent"
    else
        echo "type:      FORK"
        echo "origin:    $origin"
        echo "repo:      $nwo"
        echo "upstream:  $parent"
        echo "permission: $permission"
        echo ""
        echo "This is your fork of someone else's project. You can push"
        echo "and open a PR, but the upstream owner has to approve and"
        echo "merge it. Do NOT squash-merge on the agent's authority;"
        echo "stop after the PR is approved (or after Copilot review"
        echo "passes) and hand the merge to the upstream maintainer."
    fi
    exit 10
fi

if [[ $JSON -eq 1 ]]; then
    python3 -c "
import json, sys
print(json.dumps({
    'type': 'OWNER',
    'origin': sys.argv[1],
    'repo': sys.argv[2],
    'permission': sys.argv[3],
    'protocol': 'full PR flow: branch + PR + CI + review + squash-merge',
}))
" "$origin" "$nwo" "$permission"
else
    echo "type:      OWNER"
    echo "origin:    $origin"
    echo "repo:      $nwo"
    echo "permission: $permission"
    echo ""
    echo "You own this repo. Use the full 10-step PR flow:"
    echo "branch (off main) -> commit (GPG-signed) -> push -> issue"
    echo "-> PR (with 'Closes #N') -> wait for CI + Copilot review"
    echo "-> resolve every review thread -> squash-merge -> verify."
fi
exit 0
