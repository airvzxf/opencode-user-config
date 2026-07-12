#!/usr/bin/env bash
#
# Check that ~/.config/opencode/ is byte-identical to the
# opencode-user-config repo.
#
# The repo's MANIFEST (one tracked-path per line, relative to
# the repo root) is the single source of truth for what counts
# as "tracked config". For each line, we diff
#     <repo>/<line>     against     ~/.config/opencode/<line>
# and report any drift.
#
# Per-host files (.env, opencode.json.local, AGENTS.local.md,
# the opencode.jsonc draft variant) are not in the MANIFEST and
# are never compared. Backup files (*.bak) and the MoA fixture
# (orquestador*, agents/{propuesta-*,evaluador,sintetizador,
# validador,verificador,orquestador}.md, commands/orquestar*)
# are deliberately excluded from the repo and so are also not
# compared.
#
# Usage:
#   check-sync.sh                       # auto-detect repo at <repo-lookup-paths>
#   check-sync.sh /path/to/repo         # explicit repo path
#   check-sync.sh --help
#
# Exit codes:
#   0  All tracked files match ~/.config/opencode/.
#   1  Drift detected (one or more tracked files differ).
#   2  Prerequisites missing or argument error.
#
# Output:
#   When in sync, prints "in sync: N tracked files identical" on stdout.
#   When out of sync, prints one block per drifted file with the
#   `diff -u` output, plus a summary line at the end.
#
# Requirements:
#   * bash 4+ (uses `mapfile`, `printf %q`)
#   * cmp, diff, mktemp, tput (optional for color)
#   * No git/gh/python dependency: pure bash.

set -euo pipefail

usage() {
    awk 'NR == 1 {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

REPO_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --) shift; break ;;
        -*) echo "error: unknown flag: $1" >&2; usage 1 ;;
        *)
            if [[ -z "$REPO_PATH" ]]; then
                REPO_PATH="$1"
            else
                echo "error: unexpected extra argument: $1" >&2; usage 1
            fi
            shift
            ;;
    esac
done

# --- prerequisites ---

for bin in cmp diff mktemp; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "error: required binary not found: $bin" >&2
        exit 2
    fi
done

HOME_CFG="${HOME}/.config/opencode"

if [[ ! -d "$HOME_CFG" ]]; then
    echo "error: $HOME_CFG does not exist; nothing to compare against" >&2
    exit 2
fi

# --- locate the repo ---

# Lookup order:
#   1. $1 if given.
#   2. $OPENCODE_USER_CONFIG environment variable.
#   3. $HOME/projects/opencode-user-config (linux conventional).
#   4. $HOME/Documents/projects/opencode-user-config.
# We resolve to an absolute path and verify MANIFEST is inside.
if [[ -z "$REPO_PATH" ]]; then
    if [[ -n "${OPENCODE_USER_CONFIG:-}" ]]; then
        REPO_PATH="$OPENCODE_USER_CONFIG"
    elif [[ -d "${HOME}/projects/opencode-user-config" ]]; then
        REPO_PATH="${HOME}/projects/opencode-user-config"
    elif [[ -d "${HOME}/Documents/projects/opencode-user-config" ]]; then
        REPO_PATH="${HOME}/Documents/projects/opencode-user-config"
    fi
fi

if [[ -z "$REPO_PATH" ]]; then
    echo "error: could not auto-detect the opencode-user-config repo" >&2
    echo "       pass the path explicitly, e.g.:" >&2
    echo "       check-sync.sh /path/to/opencode-user-config" >&2
    echo "       or set OPENCODE_USER_CONFIG in your shell rc" >&2
    exit 2
fi

REPO_PATH="$(cd "$REPO_PATH" && pwd -P)"

if [[ ! -f "$REPO_PATH/MANIFEST" ]]; then
    echo "error: $REPO_PATH/MANIFEST not found; is that the opencode-user-config repo?" >&2
    exit 2
fi

# --- read the MANIFEST ---

mapfile -t manifest_lines < "$REPO_PATH/MANIFEST"
if [[ ${#manifest_lines[@]} -eq 0 ]]; then
    echo "error: $REPO_PATH/MANIFEST is empty" >&2
    exit 2
fi

# Strip comments and blanks (manifest format: one path per line).
tracked=()
for line in "${manifest_lines[@]}"; do
    case "$line" in
        ""|"#"*) continue ;;
    esac
    tracked+=("$line")
done

if [[ ${#tracked[@]} -eq 0 ]]; then
    echo "error: $REPO_PATH/MANIFEST has no tracked files after stripping comments/blanks" >&2
    exit 2
fi

# --- diff each tracked file ---

drifted=()
ok=0
missing_repo=()
missing_home=()

# ANSI color helpers (silent if no tty).
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ -n "${TERM:-}" ]] && tput colors >/dev/null 2>&1; then
    C_RED=$(tput setaf 1)
    C_GREEN=$(tput setaf 2)
    C_YELLOW=$(tput setaf 3)
    C_BOLD=$(tput bold)
    C_RESET=$(tput sgr0)
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi

for rel in "${tracked[@]}"; do
    repo_file="$REPO_PATH/$rel"
    home_file="$HOME_CFG/$rel"

    if [[ ! -e "$repo_file" ]]; then
        missing_repo+=("$rel")
        continue
    fi
    if [[ ! -e "$home_file" ]]; then
        missing_home+=("$rel")
        continue
    fi

    if cmp -s "$repo_file" "$home_file"; then
        ok=$((ok + 1))
        continue
    fi

    drifted+=("$rel")
    echo "${C_RED}--- DRIFT: $rel ---${C_RESET}"
    diff -u "$repo_file" "$home_file" || true
    echo
done

# --- summary ---

total=${#tracked[@]}
echo "${C_BOLD}=== opencode-user-config sync check ===${C_RESET}"
echo "repo:           $REPO_PATH"
echo "config dir:     $HOME_CFG"
echo "tracked files:  $total"
echo
echo "${C_GREEN}identical:${C_RESET}  $ok"
if [[ ${#missing_repo[@]} -gt 0 ]]; then
    echo "${C_YELLOW}missing in repo:${C_RESET}"
    for r in "${missing_repo[@]}"; do echo "  - $r"; done
fi
if [[ ${#missing_home[@]} -gt 0 ]]; then
    echo "${C_YELLOW}missing in \$HOME/.config/opencode/:${C_RESET}"
    for r in "${missing_home[@]}"; do echo "  - $r"; done
fi

if [[ ${#drifted[@]} -eq 0 && ${#missing_home[@]} -eq 0 && ${#missing_repo[@]} -eq 0 ]]; then
    echo
    echo "${C_GREEN}in sync: $total tracked files identical${C_RESET}"
    exit 0
fi

echo
if [[ ${#drifted[@]} -gt 0 ]]; then
    echo "${C_RED}drifted:${C_RESET}"
    for r in "${drifted[@]}"; do echo "  - $r"; done
fi
echo
echo "${C_RED}drift detected across tracked files${C_RESET}"
echo "       hint: 'cd $REPO_PATH && git pull --ff-only' to refresh the repo,"
echo "             or 'cp \$HOME/.config/opencode/<file> $REPO_PATH/<file> && \\"
echo "                 cd $REPO_PATH && git add <file> && git commit' to push a fix."
exit 1
