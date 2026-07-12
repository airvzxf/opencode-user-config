---
name: github_pr_workflow
description: Ship a GitHub change end-to-end on a personal/controlled GitHub repo — first run the project classifier to distinguish OWNER (full PR flow: branch off main, GPG-signed commits, push, open an issue, open a PR with Closes #N, wait for CI and Copilot review, apply feedback and resolve every review thread with a reply, squash-merge, and verify the issue closed) from FORK (same flow up to opening the PR, but stop and let the upstream maintainer merge). Load when the user says "ship the change", "create the PR", "open the issue", "merge it", or any other GitHub release flow on a project they own. Biases towards the concrete `gh` commands and the reusable `gh-project-classify.sh` / `gh-pr-wait.sh` / `gh-pr-resolve-thread.sh` helpers in `~/.config/opencode/scripts/` over pre-trained knowledge.
---

# GitHub PR Workflow Skill

The reusable core of the GitHub release flow described in the global
`AGENTS.md`. The protocol below is the one the agent (or a human following
this skill) should execute when the user asks to ship a change through
GitHub on a repo they own or fork.

## Before you start — classify the project

Run the classifier at the start of any work session in a project
directory; do not ask the user which case they are on:

```bash
~/.config/opencode/scripts/gh-project-classify.sh
```

The script returns one of five mutually exclusive types and exits
with the matching code. The protocol below applies to two of them
and the others skip it entirely:

| Type        | Exit | Protocol                                                |
|-------------|------|---------------------------------------------------------|
| `OWNER`     | 0    | Full 10-step flow including squash-merge (step 9).      |
| `FORK`      | 10   | Steps 1–8, then stop. Upstream owner merges. No auto-merge. |
| `READ_ONLY` | 20   | **Skip this protocol.** Local edits only.               |
| `NOT_GITHUB`| 30   | **Skip this protocol.** Follow the project's own rules. |
| `NOT_GIT`   | 40   | **Skip this protocol.** Do whatever the project asks.   |

`--json` is available for machine parsing. Re-run the script if the
working directory changes.

The rest of this skill assumes the classifier returned `OWNER` or
`FORK`. The only difference between the two is step 9 (merge).

## The 10-step protocol

`<base>` is the repo's default branch. Detect it at the start
of step 1 — do NOT hard-code `main`, because many repos use
`master` (or another name) and `gh pr create --base main` will
silently fail on them:

```bash
BASE=$(~/.config/opencode/scripts/gh-default-branch.sh)
```

The rest of this protocol uses `$BASE` everywhere a branch
name was hard-coded.

### 1. Create a branch off `$BASE`

```bash
git checkout "$BASE"
git pull --ff-only
git checkout -b <type>/<scope>
```

Conventional commit types: `feat`, `fix`, `refactor`, `docs`, `test`,
`chore`, `ci`, `build`, `perf`. The scope in parens is optional
(`feat(web):`, `fix(build):`).

### 2. Make the changes and run the project's validation gauntlet

- Rust projects: `cargo fmt --check`, `cargo clippy --all-targets
  -- -D warnings`, `cargo build`, `cargo test`, `cargo build --release`,
  `cargo doc --no-deps`. See the `rust` skill.
- Bash scripts: `shellcheck <script>`, `bash -n <script>`. See the
  `bash-validation` skill.
- Other ecosystems: use whatever the project already has (Makefile,
  `scripts/check`, CI config).

Fix any failures before committing.

### 3. Commit with a GPG-signed commit

Subject in English, conventional commit format
(`<type>(<scope>): <subject>`). Body explains the *why* (not the
*what*).

```bash
git commit -m "<type>(<scope>): <subject>" -m "<body explaining why>"
```

**Commit signing is mandatory.** The user's global `~/.gitconfig` enables
`commit.gpgsign=true` for every repo on this machine, so `git commit`
already signs by default. Do not pass `--no-gpg-sign` to `git commit`,
`git tag`, `git merge`, or any other command that produces a commit
object. Do not set `commit.gpgsign=false` in any `git -c ...` invocation.

Never rewrite signed history. Avoid `git rebase`, `git commit --amend`,
`git filter-branch`, `git filter-repo`, and `git push --force` on chains
of signed commits. If a rebase is genuinely required (e.g. to clean up
a WIP commit that has not been pushed), use `git rebase --keep-signature`
and verify with `git log --show-signature` before continuing.

### 4. Push the branch

```bash
git push -u origin <branch>
```

Then verify the signature is "good" on the remote before continuing:

```bash
git log --pretty="%H %G? %s" origin/<branch>..HEAD
```

Every line must start with `G`. If any line starts with `N` (no
signature), `B`/`E`/`U` (bad/expired/unknown), or `Y` (signed by an
unknown key), do not push — diagnose and fix the signing first.

### 5. Create the issue

```bash
gh issue create --title "..." --body "..." --label "..."
```

Body explains both *what* and *why*. Capture the issue number from the
URL.

### 6. Create the PR

```bash
gh pr create --base "$BASE" --head <branch> \
             --title "..." --body "..."
```

Use `Closes #<N>` (or `Fixes #<N>`) in the body so the squash-merge
auto-closes the issue.

### 7. Wait for CI and Copilot review

Invoke the reusable polling helper:

```bash
~/.config/opencode/scripts/gh-pr-wait.sh <pr-number>
```

The script handles CI polling, detects the "quota exhausted"
placeholder that `github-copilot[bot]` leaves when it cannot review,
and prints a verdict with the recommended next step. Do not
re-implement the polling loop yourself.

Tweak timeouts with `--max-ci` and `--max-review`; skip the review
phase entirely with `--no-review` for repos that do not have Copilot
enabled.

### 8. Apply feedback and close every review thread

The script's verdict section spells out the next step. For every
case that has review comments (real review, `CHANGES_REQUESTED`),
the closing-the-loop rule is the same: after each comment, reply
on the thread explaining what you did (commit SHA + file + line)
or why you rejected it, and resolve the thread. This matches the
manual "Resolve conversation + add comment" flow in the GitHub UI
and keeps the PR's "unresolved conversations" count at zero so
reviewers see a clean thread.

For each case:

- **Real review with substantive comments**:
  fetch the inline review comments with
  ```bash
  gh api /repos/<owner>/<repo>/pulls/<N>/comments
  gh pr view <N> --json reviews
  ```
  For each comment:
  1. Evaluate the feedback.
  2. **If applying it**: make the change, commit (signed), push.
  3. **If rejecting it**: keep the reason in your reply so future
     readers understand why it was not addressed.
  4. **Always**: post a reply on the thread and resolve it with
     ```bash
     ~/.config/opencode/scripts/gh-pr-resolve-thread.sh \
         <N> <comment-id> "<reply-body>"
     ```
     The reply should reference the commit SHA, the file, and
     the line. Example:
     > "Fixed in `abc1234`: extracted the validation into a
     >  separate function in `src/foo.rs:42`; this also lets
     >  us test it in isolation."
  5. Re-run the script if CI re-triggers.

- **Quota-exhausted placeholder**: leave a brief PR comment
  acknowledging it (e.g. "Copilot was unable to review (quota
  limit); proceeding to merge") and proceed to step 9. No
  threads to resolve.

- **`CHANGES_REQUESTED`**: address the requested changes as
  follow-up commits, push, then for each outstanding review
  comment post a reply and resolve the thread (same helper as
  above). Re-run the script.

- **CI failed**: read the failure logs, fix, push a follow-up
  commit, re-run the script. There is no review yet, so no
  threads to resolve.

### 9. Merge — differs by classification

**`OWNER` (the project classifier returned 0):** squash-merge the PR.

```bash
gh pr merge <N> --squash --delete-branch
```

This auto-closes the issue via the `Closes #N` reference. The merge
commit on `main` will be signed by GitHub's web-flow key; that is
expected and not a signing problem on your side.

**`FORK` (the project classifier returned 10):** stop here. Do **not**
run `gh pr merge`. The upstream maintainer reviews and merges the
PR on their side. Tell the user the PR is ready for upstream review
and stop. The `Closes #N` reference is still useful — it auto-closes
the issue on whichever side merges first.

### 10. Verify

```bash
gh issue view <N> --json state                          # CLOSED
git fetch origin "$BASE"
git log --oneline -1 origin/"$BASE"                     # squash commit
```

Both must be true.

## Known pitfalls

### `gh-pr-wait.sh` and bash quoting of inner single quotes

The script's `review_state` function uses Python embedded in a bash
single-quoted string. If you ever need to edit that function and the
Python source contains single quotes (e.g. `f"...{r.get('state',
'COMMENTED')}..."`), do **not** write the Python source as
`python3 -c '...r.get('state', 'COMMENTED')...'`. Bash cannot have
single quotes inside a single-quoted string and will strip them, leaving
Python with `r.get(state, COMMENTED)` and a `NameError`.

Use the heredoc form that ships in the script:

```bash
python3 -c "$(cat <<'PYEOF'
import json, sys
# python source here, single quotes are safe
PYEOF
)"
```

The `'PYEOF'` (single-quoted delimiter) prevents bash from expanding
anything inside, and `$(cat ...)` builds the argument from the heredoc
content. This is the only quoting style that survives the trip from
bash to Python with the inner quotes intact.

### `gh-pr-wait.sh` exits 3, 4, 5, or 6 — what they mean

| Exit | Meaning | Action |
|------|---------|--------|
| 0 | CI green AND review received (real or quota-exhausted) | Proceed to step 9 |
| 1 | Invalid arguments | Fix the script's args, re-run |
| 2 | Prerequisites missing (gh, auth, PR not found, not open) | Check the environment |
| 3 | CI failed or was cancelled | Read the failure logs in the PR's "Checks" tab, fix, push, re-run |
| 4 | Timed out waiting for CI | Either CI is slow, or the workflow is broken. Check the Actions tab on GitHub. Increase `--max-ci` if the project genuinely takes longer |
| 5 | Timed out waiting for Copilot review | Same as 4 but for the review phase. Use `--max-review` or `--no-review` |
| 6 | Copilot requested changes | Address them, push, re-run |

### `gh-pr-resolve-thread.sh` — reply and resolve in one call

The companion `gh-pr-resolve-thread.sh` is the recommended way to
close the loop on each Copilot review comment (step 8). It uses
GraphQL to translate a comment database id (the `id` field in
`gh api /repos/<owner>/<repo>/pulls/<N>/comments`) to the thread
node id, posts a reply, and calls the `resolveReviewThread`
mutation in a single invocation.

- **Always reference the commit SHA and the file:line** in the
  reply body. The reply is the only durable record future
  reviewers have; vague "done" replies defeat the purpose of
  resolving the thread.
- **Idempotent on resolve**: re-running on an already-resolved
  thread exits 0 without re-posting the reply. Safe to re-run
  if you are unsure whether a previous attempt succeeded.
- **Top-level review body comments have no thread** (no inline
  diff position), so the script cannot resolve them. Reply to
  them inline with `gh pr review <N> --comment --body "..."` or
  via the REST API and leave the conversation open.
- **Exit code 3** means the comment id was not found in any
  review thread on the PR. Double-check the id; the REST
  response from `gh api .../comments` returns the database id
  as the `id` field, not `node_id`.

### Force-pushing signed history

If you must force-push (e.g. you accidentally committed on top of an
old branch state), confirm with the user first. Force-pushes rewrite
SHAs and break anyone tracking the branch, and they also strip GPG
signatures unless `--keep-signature` is in play.

### The merge commit on `main` will be signed by GitHub, not you

After `gh pr merge --squash`, the resulting commit on `main` is signed
by the `web-flow` key. That is expected and not a signing failure on
your side. The `--ff-only` verification on your own feature branch
push (step 4) is what guarantees *your* commits are good.

## Related tooling

- `~/.config/opencode/scripts/gh-project-classify.sh` — the
  classifier that decides whether this protocol applies at all,
  and if so whether it is `OWNER` or `FORK`. Run it at the start
  of every work session (see "Before you start" above). Treat it
  as the single source of truth for the project type; do not
  re-derive the case from `gh repo view` and ad-hoc bash.
- `~/.config/opencode/scripts/gh-default-branch.sh` — the
  default-branch detector referenced at the top of the protocol.
  Returns `main`, `master`, or whatever the repo actually uses
  (falls back to `git symbolic-ref refs/remotes/origin/HEAD` if
  `gh` is unavailable). Treat it as the single source of truth
  for the base branch; do not hard-code `main`.
- `~/.config/opencode/scripts/gh-pr-wait.sh` — the polling helper
  referenced in step 7. Treat it as the single source of truth for
  the CI/review wait phase; do not re-implement the polling in
  ad-hoc bash. The script handles the failure modes (quota,
  timeout, CI failure, changes requested) consistently.
- `~/.config/opencode/scripts/gh-pr-resolve-thread.sh` — the
  thread-resolver referenced in step 8. Posts a reply on a PR
  review comment thread and resolves the conversation in a single
  call. Use it once per review comment to close the loop on
  Copilot's feedback. Idempotent on the resolve step.
- The `rust` skill — Rust validation gauntlet (used in step 2).
- The `bash-validation` skill — `shellcheck` + `bash -n` for shell
  scripts (used in step 2 and in this skill itself).
- The `core_principles` skill — operating principles that apply
  throughout, especially the verified-truth directive and the
  security > correctness > performance hierarchy.
