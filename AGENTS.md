# Global agent instructions

These instructions are loaded for every project opencode works on.
Project-local `AGENTS.md` files deep-merge on top of this file.


## Server environment

This is the **airvzxf VPS** — a headless Debian server, not a laptop.
The agent must adapt every assumption accordingly.

| Spec | Value |
|---|---|
| Provider | Hetzner Cloud |
| Plan | CCX13 (dedicated vCPU) |
| vCPU | 2 (AMD EPYC-Milan, x86_64) |
| RAM | 8 GB |
| Disk | 80 GB SSD (`/dev/sda1`, currently ~3% used) |
| GPU | **none** — do not propose CUDA, ROCm, or any GPU-bound workflow |
| OS | Debian GNU/Linux 13 (trixie), kernel 6.12.57 |
| Shell | bash 5.x, no GUI, no terminal multiplexer in default sessions |
| Init | systemd (no Docker in default path) |
| Hostname | `ccx13-cloud-dedicated-oregon-hil-01` (Hetzner internal name) |
| Public URLs | `https://agent.rovisoft.net` (via Cloudflare Tunnel + Zero Trust) |
| Users | `devadmin` (uid 1000, sudo NOPASSWD) and `agent` (uid 1001, **no sudo**) |
| Working dir for opencode-web | `/home/agent/projects/` |

For tasks that need root (apt install, systemd unit edits, etc.),
use the `agent → devadmin → sudo` path documented in
[Installing system packages (agent → devadmin → sudo)](#installing-system-packages-agent--devadmin--sudo)
below.

### What this changes vs. a laptop

- **No pinentry GUI** — use `pinentry-tty` or `pinentry-loopback`,
  never `pinentry-gtk` or `pinentry-qt`. The agent has no display.
- **No browser** — `xdg-open`, `xdg-mime`, etc. fail. Do not assume
  any GUI tool exists; check with `command -v` first.
- **TTY-less systemd services** — `opencode-web.service`,
  `agent-watcher.service`, `cloudflared-agent.service`,
  `opencode-upgrade.timer` all run without a controlling terminal.
  The gpg-agent must be reachable **and** `GPG_TTY` does not need
  to be set (there is no TTY), but `SSH_AUTH_SOCK` must survive.
- **No `sudo` for the `agent` user** — anything that needs root must
  go through `devadmin` (ssh + sudo) or `agent-watcher`/`opencode-web`
  systemd units that were started as root.
- **Restricted filesystem** — `agent`'s home is `0750`, so other
  users on the box cannot read it. Fine for solo use, awkward for
  sharing. Don't `chmod 777` anything to "fix" a permission error.
- **Long-running daemons** — services are expected to run for weeks
  without restart. Anything that needs to survive a reboot must be
  a systemd unit, not a `nohup` or a tmux session.

## Project classification (run at the start of any work session)

Before doing anything else in a project directory, run

```bash
~/.config/opencode/scripts/gh-project-classify.sh
```

and show the user the result. The script classifies the project
into one of four mutually exclusive cases and exits with a code
that the agent can branch on:

| Exit | Type        | Meaning                                                    | What to do                                       |
|------|-------------|------------------------------------------------------------|--------------------------------------------------|
| 0    | `OWNER`     | Repo under the user's account, not a fork.                 | Full 10-step PR flow (branch → issue → PR → CI → review → merge). |
| 10   | `FORK`      | Repo under the user's account, forked from someone else's project. | Branch + PR + CI + review; **stop and let the upstream maintainer merge**. Do not auto-merge. |
| 20   | `READ_ONLY` | Repo on GitHub that the user cannot push to.               | Local edits only. No commits, no branches, no PRs, no issues. |
| 30   | `NOT_GITHUB`| Not on github.com (or `gh` cannot see the repo).           | Out of scope for the GitHub protocol; follow the project's own rules (e.g. `AGENTS.md`, Makefile, CI config). |
| 40   | `NOT_GIT`   | Not inside a Git working tree.                             | Out of scope; do whatever the project asks.      |

The point of this step is to **stop the user from having to
spell out which kind of project they are on every session**.
Re-run the script if the working directory changes.

`--json` is available for machine parsing:

```bash
~/.config/opencode/scripts/gh-project-classify.sh --json
# {"type": "OWNER", "origin": "...", "repo": "user/repo", "permission": "ADMIN", "protocol": "..."}
```

## Git remote URLs (prefer SSH over HTTPS)

The agent must use SSH URLs for `git clone` and remote
configuration on GitHub. HTTPS is a fallback, not the
default. This applies to both the raw `git` CLI and any
`gh` command that triggers a clone or push under the hood
(`gh repo clone`, `gh repo fork`, etc.).

### Canonical SSH form

```bash
git clone git@github.com:<owner>/<repo>.git
```

This VPS already has `git_airvzxf_ed25519` loaded into
`ssh-agent` and registered on GitHub, so SSH clones reuse
that key for read and write without extra setup.

**Do NOT** use the HTTPS form as the default:

```bash
git clone https://github.com/<owner>/<repo>.git   # wrong default
```

### Making `gh` use SSH

`gh` reads its preferred protocol from the `git_protocol`
config key (default `https`). Set it once to make every
`gh` clone use SSH:

```bash
gh config set git_protocol ssh
```

The per-user git-level rewrite also works (rewrites HTTPS
URLs before git sees them):

```bash
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

### Converting an existing HTTPS remote to SSH

If a repo was already cloned with HTTPS (the project
classifier will report `origin: https://github.com/...`),
switch it in place without re-cloning:

```bash
git remote set-url origin git@github.com:<owner>/<repo>.git
```

Verify with `git remote -v` — both fetch and push URLs should
start with `git@github.com:`.

### Don't clone unless asked

The agent does not run `git clone` on its own initiative.
Cloning is destructive of any local working state and the
user may have uncommitted local changes. Wait for the user
to clone (or to explicitly ask the agent to do so).

## GitHub pull request workflow

Once a project is classified as `OWNER` or `FORK`, the 10-step
PR flow below applies. The two cases differ only in step 9
(merge): `OWNER` squash-merges, `FORK` stops there and hands
the merge to the upstream maintainer. Everything else is the
same.

### The 10-step protocol

`<base>` is the repo's default branch. Detect it at the start
of step 1 — do NOT hard-code `main`, because many repos use
`master` (or another name) and `gh pr create --base main` will
silently fail on them:

```bash
BASE=$(~/.config/opencode/scripts/gh-default-branch.sh)
```

The rest of this protocol uses `$BASE` everywhere a branch
name was hard-coded.

1. **Create a branch off `$BASE`**.
   `git checkout "$BASE" && git pull --ff-only
    && git checkout -b <type>/<scope>`. Use conventional
   commit types: `feat`, `fix`, `refactor`, `docs`, `test`,
   `chore`, `ci`, `build`, `perf`. Scope in parens is
   optional (`feat(web):`, `fix(build):`).

2. **Make the changes** and run the project's local
   validation gauntlet (typically `fmt`, `clippy`, `test`,
   `build`, `doc`, `audit`, etc., as described in the
   project's own `AGENTS.md`). Fix any failures before
   committing.

3. **Commit** with a GPG-signed commit. Subject in English,
   conventional commit format. Body explains the *why* (not
   the *what*). The commit-signing rules below are
   mandatory; do not skip them.

4. **Push** the branch:
   `git push -u origin <branch>`.
   Then verify the signature is "good" on the remote before
   continuing:
   `git log --pretty="%H %G? %s" origin/<branch>..HEAD`
   — every line must start with `G`.

5. **Create the issue** describing the change:
   `gh issue create --title ... --body ... --label ...`.
   Body explains both *what* and *why*. Capture the issue
   number from the URL.

6. **Create the PR** referencing the issue:
   `gh pr create --base "$BASE" --head <branch>
              --title ... --body ...`.
   Use `Closes #<N>` (or `Fixes #<N>`) in the body so the
   squash-merge auto-closes the issue.

7. **Wait for CI and Copilot review** by invoking
   `~/.config/opencode/scripts/gh-pr-wait.sh <pr-number>`.
   The script handles CI polling, detects the "quota
   exhausted" placeholder vs a real review, and prints a
   verdict with the recommended next step. Do not
   re-implement the polling loop yourself.

8. **Apply feedback and close every review thread**
   based on the script's verdict. For every case that
   has review comments (real review, `CHANGES_REQUESTED`),
   the closing-the-loop rule is the same: after each
   comment, reply on the thread explaining what you did
   (commit SHA + file + line) or why you rejected it, and
   resolve the thread. Use the helper
   `~/.config/opencode/scripts/gh-pr-resolve-thread.sh
    <N> <comment-id> "<reply-body>"` for that — it posts
   the reply and resolves the conversation in one call,
   matching the manual "Resolve + add comment" flow in the
   GitHub UI. This keeps the PR's "unresolved
   conversations" count at zero so reviewers see a clean
   thread.

   - **Real review with substantive comments**:
     fetch the inline review comments with
     `gh api /repos/<owner>/<repo>/pulls/<N>/comments`
     and the review bodies via
     `gh pr view <N> --json reviews`. For each
     comment:
     1. Evaluate the feedback.
     2. **If applying it**: make the change, commit
        (signed), push.
     3. **If rejecting it**: keep the reason in your
        reply so future readers understand.
     4. **Always**: post a reply on the thread and
        resolve it with
        `gh-pr-resolve-thread.sh <N> <comment-id> "<reply-body>"`.
     5. Re-run the script if CI re-triggers.
   - **Quota-exhausted placeholder**: leave a brief PR
     comment acknowledging it (e.g. "Copilot was unable
     to review (quota limit); proceeding to merge") and
     proceed to step 9 (`OWNER`) or stop and hand off
     (`FORK`). No threads to resolve.
   - **`CHANGES_REQUESTED`**: address the requested
     changes as follow-up commits, push, then for each
     outstanding review comment post a reply and resolve
     the thread (same helper as above). Re-run the
     script.
   - **CI failed**: read the failure logs, fix, push a
     follow-up commit, re-run the script. There is no
     review yet, so no threads to resolve.

9. **OWNER: Squash-merge**:
   `gh pr merge <N> --squash --delete-branch`.
   This auto-closes the issue via the `Closes #N`
   reference. The merge commit on `main` will be signed by
   GitHub's web-flow key; that is expected and not a
   signing problem on your side.

   **FORK: stop here.** Do not run `gh pr merge`. The
   upstream maintainer reviews and merges. Tell the user
   the PR is ready for upstream review, and stop. The
   `Closes #N` reference is still useful (it auto-closes
   the issue on whatever side merges first).

10. **Verify** the issue is closed and the merge is on
    `$BASE`:
    `gh issue view <N> --json state` returns `CLOSED`,
    `git fetch origin "$BASE" && git log --oneline -1
     origin/"$BASE"` shows the squash commit. Skip for
    `FORK`; the merge happens upstream.

### When to skip the protocol

- The user explicitly says "skip the protocol", "just
  commit", "directly to the default branch", or similar.
- The change is a typo, a comment fix, or any change the
  user has flagged as trivial.
- The classification came back as `READ_ONLY` (cloned for
  testing — no commits, no PR).
- The classification came back as `NOT_GITHUB` or
  `NOT_GIT` (out of scope; follow the project's own
  rules).
- The repo is AUR, local-only Git, or any non-GitHub
  hosting the user happens to be on.

### Companion scripts

Three reusable scripts back this protocol. Treat them as
the single sources of truth for their respective phases;
do not re-implement any of them in ad-hoc bash.

- `~/.config/opencode/scripts/gh-project-classify.sh` —
  run at the start of any work session. Classifies the
  project as `OWNER` / `FORK` / `READ_ONLY` / `NOT_GITHUB`
  / `NOT_GIT` so the agent can pick the right protocol
  without re-asking. `--json` for machine parsing.
- `~/.config/opencode/scripts/gh-default-branch.sh` —
  invoked at the start of step 1 to detect the repo's
  default branch (`main`, `master`, or whatever). Falls
  back to `git symbolic-ref refs/remotes/origin/HEAD` if
  `gh` is unavailable. Use this instead of hard-coding
  `main`; many repos that predate GitHub's 2020 default
  branch change will silently fail otherwise.
- `~/.config/opencode/scripts/gh-pr-wait.sh` — invoked
  after step 6 with the PR number. Polls CI and the
  Copilot review, distinguishes a real review from the
  "quota exhausted" placeholder, and prints a verdict
  with the recommended next step. Handles the failure
  modes (quota, timeout, CI failure, changes requested)
  consistently. Tweak timeouts with `--max-ci` and
  `--max-review`; skip the review phase entirely with
  `--no-review` for repos that do not have Copilot
  enabled.
- `~/.config/opencode/scripts/gh-pr-resolve-thread.sh` —
  invoked per review comment from step 8. Posts a
  reply on the comment thread explaining the resolution
  and marks the conversation as resolved in a single
  call. Idempotent on the resolve step (safe to
  re-run). Pass the PR number, the review comment
  database id, and the reply body.

## Commit signing (mandatory, applies to every repo)

The global `~/.gitconfig` enables
`commit.gpgsign`, `tag.gpgsign`, and `rebase.preserveSignatures`
for every repository on this machine. Treat the resulting signed
history as a hard contract.

### Rules

- **Every commit and tag you create must be GPG-signed and show as
  "Verified" on the remote.** Do not pass `--no-gpg-sign` to
  `git commit`, `git tag`, `git merge`, or any other command that
  can produce a commit object. Do not set `commit.gpgsign=false`
  in any `git -c ...` invocation.
- **Never rewrite signed history in a way that drops signatures.**
  Avoid `git rebase` (including `git rebase -i`),
  `git commit --amend`, `git filter-branch`, `git filter-repo`,
  and `git push --force` on chains of signed commits. Each one
  recreates commit objects, and the recreation is unsigned unless
  the gpg-agent is reachable *and* `commit.gpgsign=true` is in
  effect — both of which can fail silently.
- **If a rebase or amend is genuinely required** (e.g. to clean
  up a WIP commit that has not been pushed), use
  `git rebase --keep-signature` (or rely on
  `rebase.preserveSignatures = true` from the global config) and
  verify with `git log --show-signature` before continuing. If the
  rebase cannot preserve a signature, stop and ask the user before
  force-pushing.
- **Before any force-push** (including `--force-with-lease`),
  confirm with the user. Force-pushes rewrite SHAs and break
  anyone tracking the branch.
- **Tags must be signed** (`tag.gpgsign = true` is set globally).
  Annotated tags created without `-s`/`--sign` will be rejected
  by the user's release workflow. Verify with
  `git verify-tag <tag>` before publishing.
- **Before pushing**, run
  `git log --pretty="%H %G? %s" origin/<branch>..HEAD` and check
  that every line starts with `G` (good signature). If any line
  starts with `N` (no signature), `B`/`E`/`U` (bad/expired/unknown),
  or `Y` (signed by an unknown key), do not push — diagnose and
  fix the signing first.

### Quick troubleshooting

The troubleshooting recipes below look up the current signing
key from `git config user.signingkey` (or, per-repo, from the
local repo's `git config --get user.signingkey`). If you have
overridden the signing key in a particular repo, substitute
that value.

- "gpg: signing failed: No secret key" → the gpg-agent lost the
  signing key. Re-unlock with
  `gpg --list-secret-keys "$(git config user.signingkey)"`
  and, if missing, restart the agent with
  `gpgconf --kill gpg-agent && gpg --list-secret-keys`.
- "gpg: signing failed: Inappropriate ioctl for device" → the
  agent has no usable pinentry in the current environment. Set
  `GPG_TTY=$(tty)` if a TTY exists, and ensure
  `~/.gnupg/gpg-agent.conf` has
  `allow-loopback-pinentry` and `pinentry-program /usr/bin/pinentry-tty`
  (this VPS uses `pinentry-tty`, not `pinentry-gtk`, because
  there is no display). The `default-cache-ttl 31536000` (1 year)
  lets the agent survive reboots without re-prompting.
- Commit succeeded but is unsigned → `commit.gpgsign` was
  overridden somewhere (e.g. `GIT_COMMITTER_SIGN=no` env var, or
  `git -c commit.gpgsign=false ...`). Check with
  `git config --show-origin --get commit.gpgsign`.

### Detached worktrees and non-interactive shells

The agent on this VPS runs most of its commands inside systemd
services (`opencode-web.service`, `agent-watcher.service`,
`opencode-upgrade.service`) which have no controlling TTY and no
interactive pinentry. In that case:

- The gpg-agent must already have the signing key cached
  (1-year TTL is configured, so as long as the agent has been
  unlocked once in this session it will keep working).
- `allow-loopback-pinentry` is mandatory: the agent has no
  keyboard to type a passphrase, and the key has no passphrase
  anyway, but loopback mode still needs to be enabled so that
  non-interactive sign requests don't hang.
- Do not unset `SSH_AUTH_SOCK`. The VPS's dedicated GitHub SSH
  key (`git_airvzxf_ed25519`) is held by `ssh-agent` and used by
  `git push`; dropping `SSH_AUTH_SOCK` would force a re-add on
  every commit.
- If a commit comes out unsigned despite the global config,
  report it to the user and fix the environment before pushing.
  Common cause on this VPS: running `sudo -u agent -H bash -c ...`
  without `-E` strips `GPG_AGENT_INFO` and the agent process loses
  the socket path.

## Available skills

The `~/.config/opencode/skills/` directory carries the same
skills as the laptop. Load them when the task matches:

| Skill | Use when |
|---|---|
| `github_pr_workflow` | Shipping a GitHub change end-to-end (the protocol above, in skill form). |
| `bash_validation` | Writing or fixing Bash scripts; uses `shellcheck` (installed). |
| `core_principles` | Working on any task — defines the philosophy (UX-first, security > everything, no hallucinations). |
| `arch_linux` | Packaging or system integration work; the agent must respect FHS, prefer system packages, and use systemd units. |
| `rust` | Rust code; defines `cargo fmt` / `clippy -D warnings` / `cargo test` gauntlet. |

Note: the laptop runs Arch, this VPS runs Debian. The
`arch_linux` skill is still useful for its packaging and
systemd-unit patterns (Debian uses the same systemd layout);
just substitute `apt` for `pacman`/`yay` in any examples.

## Onboarding a new host (Ubuntu laptop, fresh VPS, etc.)

Two things must be in place on each host for the cross-host
sync to actually work end-to-end:

1. **Tracked files from this repo**, copied verbatim into
   `~/.config/opencode/`:
   - `AGENTS.md`, `MANIFEST`, `opencode.json`, `scripts/*`,
     `skills/*`.
   - The repo's `opencode.json` has the provider block but **no
     `apiKey` field** -- it's a sanitized template. Each host
     installs its own literal key there.

2. **Per-host credentials**, populated by
   `scripts/install-opencode-env.sh`:
   - A literal `provider.minimax-coding-plan.options.apiKey`
     inserted into `opencode.json` (so the opencode-web SPA path
     can resolve the model and the CLI can authenticate).
   - A mirror of the same key in
     `~/.local/share/opencode/auth.json` (mode 0600), the
     canonical opencode credential store; `opencode providers
     list` shows it; the CLI falls back to it.

See "MiniMax auth -- two locations, both required" below for the
why-both explanation.

### `scripts/install-opencode-env.sh` cheat sheet

```bash
# Local install (interactive; prompts for missing keys):
~/.config/opencode/scripts/install-opencode-env.sh

# Non-interactive (CI, scripted onboarding):
MINIMAX_API_KEY=sk-cp-... \
ANTHROPIC_API_KEY=sk-cp-... \
  ~/.config/opencode/scripts/install-opencode-env.sh

# Idempotent re-run (safe — only rewrites .env when contents differ):
~/.config/opencode/scripts/install-opencode-env.sh

# Force a clean .env overwrite (e.g., after a key rotation):
~/.config/opencode/scripts/install-opencode-env.sh --force
```

The script writes `~/.config/opencode/.env` (mode 0600) and
appends the bashrc block. It does NOT touch the systemd drop-in
(the drop-in requires devadmin sudo; do it once per host as
documented in the opencode-web section).

## MiniMax auth -- two locations, both required

The MiniMax Token Plan key (`sk-cp-...`) lives in TWO
per-host locations after `scripts/install-opencode-env.sh` runs:

1. **`~/.config/opencode/opencode.json`** under
   `provider.minimax-coding-plan.options.apiKey` -- the **literal**
   key. This file is tracked by this repo with the `apiKey` field
   removed (sanitized template); each host inserts the literal
   value via `install-opencode-env.sh`.
   - The CLI (`opencode run ...`) reads this directly.
   - **The opencode-web SPA on 1.17.18 also reads this.** The SPA
     path does NOT pick up the key from `auth.json`; without a
     literal `apiKey` in `opencode.json`, the SPA path emits
     `SessionRunnerModel.ModelUnavailableError: Model unavailable:
     minimax-coding-plan/MiniMax-M3` and returns 0 tokens. So
     `opencode.json`'s apiKey is what the browser session depends
     on.

2. **`~/.local/share/opencode/auth.json`** under
   `minimax-coding-plan.key` -- canonical opencode credential
   store, mode 0600, never committed. Populated by
   `install-opencode-env.sh` with the same key.
   - `opencode providers list` shows it.
   - Acts as a CLI fallback if you remove the literal `apiKey`
     from `opencode.json` (CLI works; SPA breaks -- see above).

Why two locations. In opencode 1.17.18 the SPA's model-resolution
path reads only `opencode.json`'s `provider.X.options.apiKey`; the
CLI's provider loader reads both. Keeping both in sync is the
safest ground.

## opencode-web specifics (VPS airvzxf)

Authoritative notes for operating the `opencode-web` service
exposed at `https://agent.rovisoft.net/`. Updated 2026-07-08
after an extended debugging session. Anything here supersedes
older guesses in this file or in third-party writeups.

### Topology and auth layers

- **Process**: `opencode web --port 4096 --hostname 127.0.0.1`,
  PID managed by `systemd` (`opencode-web.service`,
  `User=agent`, `WorkingDirectory=/home/agent/projects`).
  `Restart=always` is set, so a `kill -TERM $PID` from the
  `agent` user is safe — systemd brings it back in ~5s.
- **Bind**: only `127.0.0.1:4096` is open. The service is NOT
  reachable from the LAN; the only public ingress is
  `cloudflared-agent.service` → Cloudflare Tunnel →
  `airvzxf.cloudflareaccess.com` (Cloudflare Access / Zero
  Trust SSO) → tunnel → `127.0.0.1:4096`.
- **Auth layers** (in order):
  1. **Cloudflare Access** (SSO via CF Zero Trust) — the
     only real auth wall. Without a valid CF Access JWT the
     request never reaches the opencode process.
  2. **opencode-web server** — currently **unsecured**
     (`OPENCODE_SERVER_PASSWORD` is empty in the unit since
     2026-07-08, see `/etc/systemd/system/opencode-web.service.bak.20260708`
     for the old password). CF Access + bind-to-loopback is
     treated as sufficient. Do NOT add `OPENCODE_SERVER_PASSWORD`
     back without first re-reading this section — when set, the
     SPA's SDK fetch does not send the header and every model
     call silently 401s.
  3. **Provider API keys** — MiniMax (and any other LLM
     provider) auth happens in the model SDK call. See below.

### Where the API keys live (post-bootstrap)

The canonical install lays down three sources for the API keys,
all kept in sync via `scripts/install-opencode-env.sh`:

- **`~/.config/opencode/.env` (mode 0600)** — primary store.
  Read by the bashrc block and the systemd drop-in.
- **`/etc/systemd/system/opencode-web.service.d/00-env.conf`** —
  systemd drop-in that exports the keys into the
  `opencode-web.service` process. Install once per host via:

  ```
  ssh devadmin sudo -n mkdir -p /etc/systemd/system/opencode-web.service.d
  printf '[Service]\nEnvironment="MINIMAX_API_KEY=<key>"\nEnvironment="ANTHROPIC_API_KEY=<key>"\n' \
    | ssh devadmin "sudo -n tee /etc/systemd/system/opencode-web.service.d/00-env.conf >/dev/null"
  ssh devadmin sudo -n systemctl daemon-reload
  ssh devadmin sudo -n systemctl restart opencode-web.service
  ```

  (`install-opencode-env.sh` writes `.env` and the bashrc block
  but does **not** touch the drop-in; the drop-in requires
  devadmin sudo and is a per-host one-time install.)
- **`~/.bashrc`** — appended env-loader block; re-exports the
  three vars in interactive shells so `opencode run ...` works.

### URL pattern

- The SPA constructs session URLs as
  `/server/<base64(defaultServer)>/session/<id>`.
  For this single-server setup, `defaultServer` is `"/"`,
  so URLs read as **`/Lw/session/<id>`** (`Lw` is
  base64 of `/`). The `/Lw/...` prefix is **normal**, not
  a bug.
- Sessions created in the web UI start with
  `providerID: "minimax"`. The CLI creates sessions with
  `providerID: "minimax-coding-plan"` (auto-injected from
  models.dev / the runtime). See "Provider pitfall" below.

### Provider pitfall — MiniMax (the bug that started this)

**Symptom**: prompt submitted in the web UI returns the
literal string `404 page not found` (18 bytes, lowercase)
in the assistant bubble instead of a real response. Looks
like an HTTP 404 from opencode, but is actually the upstream
LLM provider's body, piped through.

**Root cause** (in order of likelihood):

1. **Wrong `baseURL`** in `~/.config/opencode/opencode.json`.
   The `minimax` provider must point at the full Anthropic
   endpoint, including `/anthropic` and `/v1`. Required:
   `https://api.minimax.io/anthropic/v1`. Anything shorter
   (`.../v1`, `.../anthropic`, `.../`) returns either 404 or
   401 from the MiniMax gateway, with a body of literally
   `404 page not found` (or the JSON
   `authentication_error` asking for `X-Api-Key`).
   Verified with raw `curl`:
   - `https://api.minimax.io/v1/messages` → **HTTP 404**,
     body `404 page not found`
   - `https://api.minimax.io/anthropic/messages` → **HTTP 404**,
     body `404 page not found`
   - `https://api.minimax.io/anthropic/v1/messages` → **HTTP 200**
2. **Missing API key** in the opencode-web process
   environment. The systemd unit does NOT carry
   `MINIMAX_API_KEY`; without it, opencode's provider loader
   (`packages/opencode/src/provider/provider.ts`) finds no
   `provider.key` and falls through to a 401. The CLI inherits
   the env from the shell, which is why the CLI sessions
   (`minimax-coding-plan/MiniMax-M3`) work but the web
   sessions (`minimax/MiniMax-M3`) don't. Workaround in place:
   `~/.config/opencode/.env` exports `MINIMAX_API_KEY` and
   `ANTHROPIC_API_KEY`. opencode reads this file at startup
   on this server. **Long-term fix**: a systemd drop-in at
   `/etc/systemd/system/opencode-web.service.d/00-env.conf`
   that adds
   `Environment="MINIMAX_API_KEY=..."` to the unit, plus
   `sudo systemctl daemon-reload && sudo systemctl restart
   opencode-web`. That requires `devadmin` (agent has no
   sudo on this box).
3. **`{env:...}` resolution** — the docs say
   `"apiKey": "{env:MINIMAX_API_KEY}"` works. In practice,
   on opencode 1.17.15 the web service sometimes loads the
   literal string `{env:MINIMAX_API_KEY}` instead of the
   resolved value (empirically: a fresh restart after
   touching the config occasionally lands without the env
   resolved; the next restart usually fixes it). Hardcoding
   the key in `opencode.json` is the only 100% reliable
   workaround, but it puts the secret on disk. Acceptable
   here because the file is `0640` agent:agent on a single
   tenant VPS; not acceptable on a multi-tenant box.

**Symptom decoder for the user**:
- "404 page not found" in the chat bubble → provider
  baseURL is missing `/anthropic/v1` OR the env var is
  not resolved. Run `curl -sS https://api.minimax.io/anthropic/v1/messages
  -H "x-api-key: $MINIMAX_API_KEY" -H "anthropic-version:
  2023-06-01" -d '{"model":"MiniMax-M3","max_tokens":5,"messages":[{"role":"user","content":"x"}]}'`.
  If that returns 200 from your shell but the SPA 404s,
  the web process does not have the env. Restart opencode-web.
- "401 authentication_error: ... X-Api-Key field ..." in
  the assistant bubble → SDK called the endpoint but with
  empty auth. The `provider.key` resolution path failed.
  Check `~/.config/opencode/.env` exists and the web PID's
  `/proc/$PID/environ` contains `MINIMAX_API_KEY=...`.
- "Model unavailable: minimax/MiniMax-M3" → opencode could
  not resolve the provider/model pair at all. The custom
  `provider.minimax-coding-plan` (or `provider.minimax`)
  block in `opencode.json` is missing or invalid. See below.

### What lives where

| File | Owner | Purpose |
|---|---|---|
| `/etc/systemd/system/opencode-web.service` | root | systemd unit. `OPENCODE_SERVER_PASSWORD` empty since 2026-07-08. Do NOT touch without reading the section above. |
| `/etc/systemd/system/opencode-web.service.bak.20260708` | root | Backup of the unit before the password was removed. Contains the original password. |
| `~/.config/opencode/opencode.json` | agent | Custom provider config. Current state has a `minimax-coding-plan` provider pointing at `https://api.minimax.io/anthropic/v1`. Backup at `~/.config/opencode/opencode.json.bak.20260708-185422`. |
| `~/.config/opencode/.env` | agent (0600) | `MINIMAX_API_KEY` + `ANTHROPIC_API_KEY`. Read by opencode at startup; equivalent to injecting these into the systemd unit. |
| `~/.local/share/opencode/log/opencode.log` | agent | opencode's structured log. Tail with `tail -200 ~/.local/share/opencode/log/opencode.log | grep -E '<session-id>'` to follow a session. **This is the first place to look when diagnosing a chat failure.** The web service journal (`journalctl -u opencode-web`) is empty because `agent` is not in `adm`/`systemd-journal`. |
| `~/.local/share/opencode/opencode.db*` | agent | SQLite — sessions, messages, permissions. Useful for forensics. |
| `~/.cache/opencode/models.json` | agent | models.dev cache. Defines `minimax`, `minimax-coding-plan`, `minimax-cn`, `minimax-cn-coding-plan` with `api: https://api.minimax.io/anthropic/v1` (and `api.minimaxi.com` for the `.cn` variants). Refreshed on opencode upgrade. |

### Diagnosing real 404s vs the SPA-rendered "404 page not found"

The SPA serves `index.html` (HTTP 200) for **every** unknown
path — client-side routing fallback. So a real server 404
will show up as a 200 with the SPA HTML. Don't trust the
status code from `curl http://127.0.0.1:4096/some/random/path`;
check whether the body is the SPA HTML (look for
`/assets/index-` in the response).

To check whether a real LLM call is happening, hit the API
endpoints directly:
```bash
curl -sS http://127.0.0.1:4096/api/session | python3 -m json.tool
curl -sS http://127.0.0.1:4096/api/session/<sid>/message | python3 -m json.tool
```
The `assistant` message `info.error` field is the upstream
error verbatim — that's where the "X-Api-Key" string comes
from in the current bug.

### Restarting opencode-web safely (no sudo required)

`agent` owns the opencode-web process (same UID), so you can
restart it without sudo by signaling the process. systemd
will respawn it:

```bash
PID=$(pgrep -f 'opencode web --port 4096' | head -1)
kill -TERM "$PID"
sleep 6
pgrep -f 'opencode web --port 4096' | head -1   # new PID
```

This is a ~5s blip on the SPA; no auth loss (CF Access keeps
the session, the SPA holds the JWT).

If you change the systemd unit (e.g. to add
`MINIMAX_API_KEY` to `Environment=` directly), you must
`sudo systemctl daemon-reload && sudo systemctl restart
opencode-web`. The `agent` user has no sudo; either go
through `devadmin` over SSH or run the commands from a
session that has sudo.

### Inspecting / clearing browser state

The SPA stores `opencode-theme-id`, `opencode-color-scheme`,
and per-tab state in `localStorage`. Hard refresh
(Ctrl-Shift-R / Cmd-Shift-R) clears it. To wipe completely,
DevTools → Application → Storage → Clear site data for
`https://agent.rovisoft.net`. The `opencode.db` on the
server side is per-session-id; old sessions can be left
hanging in `/api/session` listings without affecting new
sessions.

### Resolution (as of 2026-07-08)

The combination that makes the web service work for real
model calls:

1. **`baseURL` ends in `/anthropic/v1`** in
   `~/.config/opencode/opencode.json` (not `/anthropic`,
   not `/v1`). Required.
2. **Literal `apiKey`** in the provider `options` block
   (no `{env:...}` substitution). `{env:...}` works for the
   CLI but the web service occasionally drops the resolution
   on restart; the literal value is the only 100% reliable
   path for the web.
3. **Optional**: `~/.config/opencode/.env` carries
   `MINIMAX_API_KEY` + `ANTHROPIC_API_KEY`. opencode reads
   this at startup (Bun native). The env is what the SDK
   would fall back to if `options.apiKey` ever became empty.

The earlier 401s ("Please carry the API secret key in the
'X-Api-Key' field") during the debugging session were caused
by a half-loaded config after rapid restarts — opencode 1.17.15
needs a clean stop (`kill -TERM`) and a 5–10s wait before the
next start, otherwise the env is not yet picked up and the
SDK hits MiniMax with an empty `x-api-key`. The service is
stable now (uptime ~1h, multi-turn sessions with hundreds of
thousands of input tokens confirmed working).

**Security note**: the literal `apiKey` in `opencode.json`
puts the secret on disk. The file is owned `agent:agent`
mode `0664` (rw-rw-r--) on this single-tenant VPS; not safe
on a multi-tenant box. The clean long-term fix is a systemd
drop-in at `/etc/systemd/system/opencode-web.service.d/00-env.conf`
with `Environment="MINIMAX_API_KEY=..."` and reverting
`apiKey` to `"{env:MINIMAX_API_KEY}"`. That requires `devadmin`
to sudo-apply.

## Installing system packages (agent → devadmin → sudo)

`agent` runs without sudo and is intended to stay that way
(filesystem permissions, no secrets on disk, no accidental global
mutations). For anything that requires root — `apt install`,
`systemctl edit`, kernel knobs, raw socket opens — the canonical
escape hatch is:

```
ssh devadmin sudo -n <command>
```

`sshd` listens on `127.0.0.1:22` and `devadmin`'s sudoers is
configured NOPASSWD for the relevant commands (apt, systemctl, …).
No password prompt, no interactive pinentry, safe to call from a
non-interactive shell (systemd units without a controlling TTY
included).

### One-time wiring (already in place on this VPS as of 2026-07-09)

1. **`agent` generates a dedicated SSH key** for the devadmin hop
   (do NOT reuse `git_airvzxf_ed25519`; that's for GitHub):
   ```
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_devadmin \
     -N "" -C "agent@airvzxf"
   ```
   `/home/devadmin` is `0750 devadmin:devadmin`, so `agent`
   cannot read its `authorized_keys` — pasting the public key
   is a manual step from a `devadmin` session.
2. **`~/.ssh/config`** carries a `devadmin` block that pins the
   private key with `IdentitiesOnly yes`, so no other key leaks
   into the auth attempt:
   ```
   Host devadmin
       HostName localhost
       User devadmin
       IdentityFile ~/.ssh/id_ed25519_devadmin
       IdentitiesOnly yes
   ```
3. **`devadmin`'s `~/.ssh/authorized_keys`** contains the
   matching `ssh-ed25519 AAAA… agent@airvzxf` line. Pasted once
   by the human; never by the agent.

### Sanity check before relying on it

The first thing to run when diagnosing "can agent do X with root?"
is this single-liner:

```
ssh devadmin sudo -n apt --version
```

If it prints `apt X.Y.Z (amd64)`, the channel is open and any
succeeding `ssh devadmin sudo -n <cmd>` should also work. If it
hangs, prints `permission denied`, or asks for a password, the
wiring above is broken — fix it before doing anything else.

### Common pitfalls

- **Reusing a key that belongs to another user.** A keyfile
  copied onto the VPS but still owned by `devadmin:users` and
  mode `0600` is unreadable by `agent`. Drop the cross-user key,
  generate fresh on `agent`.
- **Wrong `IdentityFile` in `~/.ssh/config`.** SSH quietly
  refuses keys whose path doesn't exist; the connection then
  attempts every other key in the agent and fails. Always
  `ssh -v devadmin true` once after editing.
- **`apt-get download` works without sudo and is a useful
  fallback** — download the `.deb`, `dpkg-deb -x` into
  `~/.local/stage/`, symlink into `~/.local/bin/`. Fully
  portable, no system state. Reserve for cases where the
  devadmin hop is unavailable (e.g. you're not sure sshd is up).

### Examples

```
ssh devadmin sudo -n apt install -y bats
ssh devadmin sudo -n systemctl restart opencode-web
ssh devadmin sudo -n journalctl -u opencode-web -n 50 --no-pager
```

Prefer `sudo -n` (non-interactive) for every invocation. If a
command needs a TTY, that's a sign it should be a `devadmin`
shell session, not an agent call.
