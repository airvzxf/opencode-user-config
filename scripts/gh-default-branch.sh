#!/usr/bin/env bash
#
# Print the default branch of the current GitHub repo (e.g. `main`
# or `master`). Use this instead of hard-coding `main` in the
# PR workflow, because many repos that predate GitHub's 2020
# default-branch change (or repos whose owner explicitly chose
# `master`) will silently fail `gh pr create --base main` and
# `git fetch origin main` otherwise.
#
# Usage:
#   gh-default-branch.sh            # prints the branch name
#   BASE=$(gh-default-branch.sh)    # capture for use in scripts
#   gh-default-branch.sh --help
#
# Strategy (in order):
#   1. `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`
#      — works on any repo `gh` can see (public, private, own,
#      collaborator). Requires `gh` to be authenticated.
#   2. `git symbolic-ref refs/remotes/origin/HEAD` — works for
#      local clones where the remote's HEAD has been resolved
#      (the case after `git clone` or `git remote set-head`).
#   3. Print an error to stderr and exit non-zero. The PR
#      workflow must not silently fall back to `main` because
#      that is exactly the failure mode this script exists to
#      prevent.
#
# Exit codes:
#   0  Branch name printed on stdout.
#   1  Invalid arguments.
#   2  Could not determine the default branch (neither `gh` nor
#      `git symbolic-ref` returned a value).

set -euo pipefail

usage() {
    awk 'NR == 1 {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --) shift; break ;;
        -*) echo "error: unknown flag: $1" >&2; usage 1 ;;
        *) echo "error: unexpected extra argument: $1" >&2; usage 1 ;;
    esac
done

# --- 1. try `gh repo view` ---

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if branch=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null) && [[ -n "$branch" ]]; then
        printf '%s\n' "$branch"
        exit 0
    fi
    # Fall through to the symbolic-ref fallback. Do not exit
    # yet — `gh` may have succeeded at auth but failed on a
    # particular repo (e.g. unauthenticated org), and we want
    # to give the local-only path a chance.
fi

# --- 2. fall back to `git symbolic-ref` ---

if branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
    branch=${branch#refs/remotes/origin/}
    if [[ -n "$branch" ]]; then
        printf '%s\n' "$branch"
        exit 0
    fi
fi

# --- 3. could not determine ---

echo "error: could not determine the default branch" >&2
echo "       tried 'gh repo view --json defaultBranchRef' and" >&2
echo "       'git symbolic-ref refs/remotes/origin/HEAD'" >&2
echo "       fix: run 'git remote set-head origin --auto' once" >&2
echo "       on the local clone so symbolic-ref resolves" >&2
exit 2
