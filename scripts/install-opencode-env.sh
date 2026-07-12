#!/usr/bin/env bash
#
# Bootstrap the per-host credentials that opencode needs to talk
# to a MiniMax Token Plan endpoint. Local to the host running
# this script. Does NOT touch other machines or any remote system.
#
# Background
# ----------
# opencode loads its config from two locations:
#
#   1. ~/.config/opencode/opencode.json  -- provider options
#      (baseURL, npm package), commands, MCP servers, model list.
#      This file is tracked by airvzxf/opencode-user-config.
#
#   2. ~/.local/share/opencode/auth.json -- per-host credentials
#      (one entry per provider). Mode 0600; never committed.
#
# The repo's opencode.json ships WITHOUT apiKey. This script asks
# for the MiniMax Token Plan key once, then writes it to BOTH
# locations so the key is usable from every launch context:
#
#   * ~/.config/opencode/opencode.json  -- the literal apiKey field.
#     This is what opencode-web uses on the SPA. Has to be there for
#     browser-based sessions to work; if you skip this, the SPA hits
#     "Model unavailable" on opencode-web 1.17.18.
#
#   * ~/.local/share/opencode/auth.json -- the canonical credential
#     store. Populated with the same key. opencode providers list
#     shows it; `opencode run` reads it as a fallback.
#
# Why both
# --------
# * The CLI works with EITHER source -- opencode's provider loader
#   reads the literal apiKey field, then falls back to auth.json.
# * The opencode-web SPA in 1.17.18 does NOT pick up auth.json
#   reliably for the SPA model-resolution path -- it only honours
#   the literal apiKey in opencode.json. This is empirically
#   verified; see AGENTS.md "MiniMax auth -- two locations" for
#   the failing-session evidence.
#
# What this does NOT do
# ---------------------
# * Does not touch /etc/opencode-web.env (root-owned) or any
#   systemd drop-in. Those are only relevant if you also need
#   the opencode-web service to authenticate to CF Access on
#   startup; for our deployment CF Access handles it.
# * Does NOT touch ~/.bashrc. The literal key in opencode.json
#   works for both interactive and non-interactive shells.
#
# Usage
# -----
#   install-opencode-env.sh                           # interactive
#   MINIMAX_API_KEY=sk-cp-... install-opencode-env.sh # non-interactive
#
# Idempotent: safe to run multiple times. Skips writes when the
# existing values match.
#
# Exit codes
# ----------
#   0  success
#   1  invalid argument
#   2  prerequisites missing
#   4  user aborted at the prompt
#
# Requirements
# ------------
#   * bash 4+
#   * python3

set -euo pipefail

usage() {
    awk 'NR == 1 {next} /^[^#]/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

MINIMAX_API_KEY="${MINIMAX_API_KEY:-}"
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
OPENCODE_JSON="$CFG_DIR/opencode.json"
STATE_DIR="$HOME/.local/share/opencode"
AUTH_JSON="$STATE_DIR/auth.json"

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

if [[ -z "$MINIMAX_API_KEY" ]] && [[ -r "$AUTH_JSON" ]]; then
    existing="$(python3 -c "
import json, sys
try:
    d = json.load(open('$AUTH_JSON'))
    print(d.get('minimax-coding-plan', {}).get('key', ''))
except Exception:
    pass
")"
    if [[ -n "$existing" ]]; then
        MINIMAX_API_KEY="$existing"
    fi
fi

if [[ -z "$MINIMAX_API_KEY" ]] && [[ -r "$OPENCODE_JSON" ]]; then
    existing="$(python3 -c "
import json
try:
    d = json.load(open('$OPENCODE_JSON'))
    print(d.get('provider', {}).get('minimax-coding-plan', {}).get('options', {}).get('apiKey', ''))
except Exception:
    pass
")"
    if [[ -n "$existing" ]] && [[ "$existing" != "{env:MINIMAX_API_KEY}" ]]; then
        MINIMAX_API_KEY="$existing"
    fi
fi

if [[ -z "$MINIMAX_API_KEY" ]]; then
    MINIMAX_API_KEY="$(prompt_for_key 'Enter MINIMAX_API_KEY (MiniMax Token Plan, sk-cp-...): ')"
fi

echo "key length: ${#MINIMAX_API_KEY}"
if [[ ${#MINIMAX_API_KEY} -lt 50 ]]; then
    echo "warning: that key looks unusually short; double-check before continuing"
fi

# --- 1. write ~/.config/opencode/opencode.json (literal apiKey) ---

mkdir -p "$CFG_DIR"
NEEDS_WRITE=1
if [[ $FORCE -eq 0 ]] && [[ -r "$OPENCODE_JSON" ]]; then
    existing="$(python3 -c "
import json
try:
    d = json.load(open('$OPENCODE_JSON'))
    k = d.get('provider', {}).get('minimax-coding-plan', {}).get('options', {}).get('apiKey', '')
    print(k)
except Exception:
    pass
")"
    if [[ "$existing" == "$MINIMAX_API_KEY" ]]; then
        NEEDS_WRITE=0
    fi
fi

if [[ $NEEDS_WRITE -eq 1 ]]; then
    if [[ ! -r "$OPENCODE_JSON" ]]; then
        echo "warning: $OPENCODE_JSON does not exist; bootstrap from the repo first:"
        echo "         cp /path/to/opencode-user-config/opencode.json $OPENCODE_JSON"
        exit 2
    fi
    python3 - <<PYEOF
import json
p = "$OPENCODE_JSON"
d = json.load(open(p))
prov = d.setdefault("provider", {})
mc = prov.setdefault("minimax-coding-plan", {})
opts = mc.setdefault("options", {})
opts["apiKey"] = "$MINIMAX_API_KEY"
opts.setdefault("baseURL", "https://api.minimax.io/anthropic/v1")
mc.setdefault("npm", "@ai-sdk/anthropic")
mc.setdefault("name", "MiniMax Token Plan")
mc.setdefault("models", {
    "MiniMax-M3": {"name": "MiniMax M3"},
    "MiniMax-M2.7": {"name": "MiniMax M2.7"},
})
d.pop("shell", None)
json.dump(d, open(p, "w"), indent=2)
PYEOF
    echo "wrote $OPENCODE_JSON (literal apiKey)"
else
    echo "$OPENCODE_JSON already has this key, skipping (pass --force to overwrite)"
fi

# --- 2. write ~/.local/share/opencode/auth.json (mode 0600) ---

mkdir -p "$STATE_DIR"
NEEDS_WRITE=1
if [[ $FORCE -eq 0 ]] && [[ -r "$AUTH_JSON" ]]; then
    existing="$(python3 -c "
import json
try:
    d = json.load(open('$AUTH_JSON'))
    print(d.get('minimax-coding-plan', {}).get('key', ''))
except Exception:
    pass
")"
    if [[ "$existing" == "$MINIMAX_API_KEY" ]]; then
        NEEDS_WRITE=0
    fi
fi

if [[ $NEEDS_WRITE -eq 1 ]]; then
    umask 077
    python3 - <<PYEOF
import json, os, stat
p = "$AUTH_JSON"
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: pass
d["minimax-coding-plan"] = {"type": "api", "key": "$MINIMAX_API_KEY"}
json.dump(d, open(p, "w"), indent=2)
os.chmod(p, 0o600)
PYEOF
    chmod 0600 "$AUTH_JSON"
    echo "wrote $AUTH_JSON (mode 0600)"
else
    echo "$AUTH_JSON already has this key, skipping"
fi

echo
echo "Bootstrap complete:"
echo "  - $OPENCODE_JSON (literal apiKey)"
echo "  - $AUTH_JSON (mode 0600, per-host credential store)"
echo
echo "Verify with:"
echo "  /usr/bin/opencode run 'say PONG'"