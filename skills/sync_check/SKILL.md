---
description: Verify that ~/.config/opencode/ is byte-identical to the opencode-user-config repo. Use after editing any tracked config file, before starting a work session on a new machine, and before opening a PR from a non-canonical host. Exits 0 if in sync; prints a per-file diff and exits 1 if any tracked file has drifted.
---

# sync_check

You are checking whether the user's local OpenCode config tree
(`~/.config/opencode/`) is byte-identical to the tracked canonical
copy at the `opencode-user-config` repository.

The repo owns the cross-host subset of the user's OpenCode setup —
the AGENTS.md, the scripts, the skills, and the `opencode.json` /
`MANIFEST` files. Things that are intentionally NOT in the repo
(scripts, backups, drafts, secrets, MoA orchestration artifacts)
are also out of scope for this check.

## When to invoke this skill

The user explicitly asks. Don't run it on every turn. Common cues:

- "Is my config in sync?"
- "Revisa que tus archivos principales están sincronizados o idénticos byte by byte al repositorio."
- "Run check-sync on this machine."
- After editing `~/.config/opencode/AGENTS.md`, any file under
  `~/.config/opencode/scripts/`, or any SKILL.md.
- After `git pull` of the opencode-user-config repo on a new host
  — to verify the deploy landed cleanly.
- Before opening a PR from a non-canonical host, as a sanity
  check that the host has the latest protocol scripts.

## What to do

1. Invoke the helper script:

    ```bash
    ~/.config/opencode/scripts/check-sync.sh
    ```

   If the script can't auto-detect the repo, pass the path
   explicitly or set `OPENCODE_USER_CONFIG` in the shell rc.

2. Read the script's output. The relevant exit codes are:

   - **0 — in sync.** Do nothing else. Just confirm to the user.
   - **1 — drift detected.** Read the per-file `diff -u` blocks
     the script prints. Each drifted file's intent is obvious
     from the filename; do **not** explain drift as a "bug" —
     it might be a deliberate local-only change that has not
     been pushed yet (or vice versa).
   - **2 — prerequisites missing.** Help the user fix the
     prerequisite (the script's stderr is specific).

3. If drift is detected, decide WITH the user how to reconcile.
   This is a workflow decision, not an autonomous fix:

   - If the drift is on the LOCAL side (user edited
     `~/.config/opencode/` without committing), offer to `cp`
     the file into the repo and `git add` + commit + push.
   - If the drift is on the REPO side (new commit on `main`
     that hasn't been deployed to this host), offer to `git
     pull --ff-only` from the repo path, then copy the file
     into place. (`cp` not `ln` — these are independent copies,
     not symlinks, because we never want a host-edit to leak
     through a symlink.)
   - If both differ, present both diffs and ask.

4. **Do not auto-edit config files** to "fix" drift without
   asking. The sync check is informational; the reconcile
   step is the user's call.

## What this skill intentionally does NOT do

- It does not edit any files.
- It does not run `git pull`, `git push`, `git add`, `git
  commit`, `gh pr create`, or anything else side-effectful.
- It does not invoke `gh-pr-wait.sh` or `gh-pr-resolve-thread.sh`.
  Those are part of `github_pr_workflow`, a separate skill.
- It does not check git status of the opencode-user-config
  repo itself (use `git -C $OPENCODE_USER_CONFIG status` for
  that — out of scope here).
- It does not check the in-repo MoA files, because MoA is
  not in the repo. Don't try to "sync" MoA through this
  skill; the user has explicitly excluded MoA.

## Companion files

- `~/.config/opencode/scripts/check-sync.sh` — the helper this
  skill wraps. Bash 4+, no python/gh dependency, exits
  0/1/2.
- `$OPENCODE_USER_CONFIG/MANIFEST` — one tracked-path per
  line. The script reads this; you do not.
