#!/usr/bin/env bash
#
# Bootstrap the per-host environment that ~/.config/opencode/
# needs to function on a fresh machine. Local to the host running
# this script (does NOT touch other machines or any remote system).
#
# What this does:
#   1. Writes ~/.config/opencode/.env (mode 0600) with
#      MINIMAX_API_KEY, ANTHROPIC_API_KEY, OPENCODE_EXPERIMENTAL_WORKSPACES,
#      sourcing them from $MINIMAX_API_KEY / $ANTHROPIC_API_KEY in
#      the calling shell. If unset and stdin is a tty, prompts
#      interactively.
#   2. Appends a small block to ~/.bashrc that, in interactive
#      shells, re-exports the same vars from .env so the CLI
#      (opencode run ...) picks them up.
#
# What this does NOT do (handled separately):
#   * The systemd drop-in for opencode-web lives at
#     /etc/systemd/system/opencode-web.service.d/00-env.conf
#     and requires devadmin sudo. See AGENTS.md "opencode-web
#     specifics (airvzxf VPS)" for the canonical install commands.
#     It must be applied once per host that runs opencode-web
#     as a systemd service; the bashrc block in step 2 only
#     covers interactive-shell CLI invocations.
#
# Usage:
#   install-opencode-env.sh                # interactive; prompts for missing keys
#   MINIMAX_API_KEY=sk-cp-... \
#     ANTHROPIC_API_KEY=sk-cp-... \
#     install-opencode-env.sh              # non-interactive
#   install-opencode-env.sh --noninteractive --skip-prompt  # .env untouched if exists
#
# Idempotent: safe to run multiple times. The bashrc block has an
# append-once guard. The .env is rewritten only when --force is
# passed or when the existing file's content differs.
#
# Exit codes:
#   0  success
#   1  invalid argument
#   2  prerequisites missing
#   4  user aborted at the prompt
#
# Requirements:
#   * bash 4+
#   * HOME set

set -euo pipefail

usage() {
    awk 'NR == 1 {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

MINIMAX_API_KEY="${MINIMAX_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
NONINTERACTIVE=0
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --noninteractive) NONINTERACTIVE=1; shift ;;
        --force) FORCE=1; shift ;;
        --) shift; break ;;
        -*) echo "error: unknown flag: $1" >&2; usage 1 ;;
        *) echo "error: unexpected argument: $1" >&2; usage 1 ;;
    esac
done

# --- prerequisites ---

if [[ -z "$HOME" ]]; then
    echo "error: HOME is unset" >&2
    exit 2
fi

CFG_DIR="$HOME/.config/opencode"
ENV_FILE="$CFG_DIR/.env"

# --- prompt for missing keys (if not in env) ---

prompt_for_key() {
    local prompt="$1"
    local value=""
    if [[ -t 0 ]] && [[ $NONINTERACTIVE -eq 0 ]]; then
        read -r -p "$prompt" value
        if [[ -z "$value" ]]; then
            echo "aborted: a non-empty value is required" >&2
            exit 4
        fi
    else
        echo "error: missing required env var and stdin is not a tty" >&2
        exit 1
    fi
    printf '%s' "$value"
}

if [[ -z "$MINIMAX_API_KEY" ]] && [[ -r "$ENV_FILE" ]]; then
    MINIMAX_API_KEY="$(grep -E '^MINIMAX_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
fi
if [[ -z "$MINIMAX_API_KEY" ]]; then
    MINIMAX_API_KEY="$(prompt_for_key 'Enter MINIMAX_API_KEY: ')"
fi

if [[ -z "$ANTHROPIC_API_KEY" ]] && [[ -r "$ENV_FILE" ]]; then
    ANTHROPIC_API_KEY="$(grep -E '^ANTHROPIC_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
fi
# Default ANTHROPIC_API_KEY to MINIMAX_API_KEY — Token Plan keys are
# interchangeable across the two vars on MiniMax.
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    ANTHROPIC_API_KEY="$MINIMAX_API_KEY"
fi

# --- 1. write ~/.config/opencode/.env (mode 0600) ---

NEW_ENV_CONTENT="MINIMAX_API_KEY=$MINIMAX_API_KEY
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
OPENCODE_EXPERIMENTAL_WORKSPACES=1"

NEEDS_WRITE=1
if [[ $FORCE -eq 0 ]] && [[ -r "$ENV_FILE" ]]; then
    EXISTING="$(cat "$ENV_FILE")"
    if [[ "$EXISTING" == "$NEW_ENV_CONTENT" ]]; then
        NEEDS_WRITE=0
    fi
fi

if [[ $NEEDS_WRITE -eq 1 ]]; then
    mkdir -p "$CFG_DIR"
    umask 077
    cat > "$ENV_FILE" <<EOF
# OpenCode MiniMax credentials. mode 0600; never committed.
# opencode 1.17.18's CLI does NOT auto-load this file; the env-template
# form in opencode.json (apiKey: "{env:MINIMAX_API_KEY}") requires
# these vars in the shell environment. See ~/.bashrc (interactive
# shells) and /etc/systemd/system/opencode-web.service.d/00-env.conf
# (the opencode-web service) for the per-invocation loaders.
$NEW_ENV_CONTENT
EOF
    chmod 0600 "$ENV_FILE"
    echo "wrote $ENV_FILE (mode 0600)"
else
    echo "$ENV_FILE already up to date, skipping (pass --force to overwrite)"
fi

# --- 2. append bashrc block (once) ---

BASHRC="${HOME}/.bashrc"
MARKER='OPENCODE USER CONFIG — env loader'

if [[ ! -r "$BASHRC" ]]; then
    echo "info: $BASHRC does not exist yet; skipping bashrc block" >&2
    echo "bootstrap complete: only .env written"
    exit 0
fi

if grep -qF "$MARKER" "$BASHRC"; then
    echo "$BASHRC: env-loader block already present, skipping"
else
    cat >> "$BASHRC" <<EOF

# >>> $MARKER (managed by scripts/install-opencode-env.sh) >>>
# opencode 1.17.18's CLI does not auto-load ~/.config/opencode/.env; the
# env-template form in opencode.json (apiKey: "{env:MINIMAX_API_KEY}")
# requires these vars in the shell environment. This block runs only
# in interactive shells (most .bashrc configs return early on
# non-interactive invocations, which is fine — those use the
# systemd drop-in instead).
_minimax_env="\$HOME/.config/opencode/.env"
if [[ -f "\$_minimax_env" && -r "\$_minimax_env" ]]; then
    eval "\$(
        grep -E '^(MINIMAX_API_KEY|ANTHROPIC_API_KEY|OPENCODE_EXPERIMENTAL_WORKSPACES)=' \
            "\$_minimax_env" 2>/dev/null | \\
        while IFS='=' read -r k v; do
            case "\$k" in
                MINIMAX_API_KEY|ANTHROPIC_API_KEY|OPENCODE_EXPERIMENTAL_WORKSPACES) \\
                    printf 'export %s=%q\\n' "\$k" "\$v" ;;
            esac
        done
    )" 2>/dev/null
fi
unset _minimax_env
# <<< OPENCODE USER CONFIG <<<
EOF
    echo "appended env-loader block to $BASHRC"
fi

echo
echo "Bootstrap complete:"
echo "  - $ENV_FILE (mode 0600)"
echo "  - $BASHRC (env-loader block, interactive shells only)"
echo
echo "For the opencode-web service, install the systemd drop-in:"
echo "  /etc/systemd/system/opencode-web.service.d/00-env.conf"
echo "  (requires devadmin sudo; see AGENTS.md for the canonical commands)"