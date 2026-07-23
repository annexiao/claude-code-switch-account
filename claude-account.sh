#!/usr/bin/env bash
# Switch which Claude account the CLI uses.
#
# WHY. macOS Claude Code keeps credentials in two independent stores: GUI
# sessions use the login Keychain ("Claude Code-credentials"); headless
# processes (SSH / launchd / `claude -p` from cron) use
# ~/.claude/.credentials.json. The two can silently hold different accounts. This script makes the active account an explicit, named,
# verifiable choice. Parked credentials live in ~/.claude/accounts/<name>.json.
#
# COMMANDS
#   save <name>     capture the CURRENT laptop login (Keychain) into the store.
#                   Run once after /login-ing a new account (e.g. josh).
#   use <name>      switch THIS Mac to <name> (writes Keychain + local
#                   .credentials.json if present). New sessions pick it up.
#   usage <name>|all  print 5h/7d pool utilization for stored account(s),
#                   read from the API's own rate-limit headers (costs ~1 haiku
#                   token; on an exhausted account the probe is free).
#
# KNOWN LIMIT: a PARKED credential stops being refreshed and can go stale
# after weeks. Symptom: the switch verification prints a 401 warning, or
# claude asks you to log in. Fix: /login that account once, then `save` it.
set -uo pipefail

STORE="$HOME/.claude/accounts"
SERVICE="Claude Code-credentials"
PROFILE_URL="https://api.anthropic.com/api/oauth/profile"
mkdir -p "$STORE" && chmod 700 "$STORE"

die() { echo "FAIL: $*" >&2; exit 1; }

_keychain_read() { security find-generic-password -s "$SERVICE" -a "$USER" -w; }

_valid() {  # is $1 a claude credential blob?
    python3 -c "import json,sys; json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken']" "$1" >/dev/null 2>&1
}

_token_of() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['claudeAiOauth']['accessToken'])" "$1"; }

_whoami() {  # $1 = token -> email, or "" on failure
    curl -s -m 15 "$PROFILE_URL" -H "Authorization: Bearer $1" \
         -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null \
      | python3 -c "import json,sys
try: print(json.load(sys.stdin)['account']['email'])
except Exception: pass"
}

_sync_back_local() {  # keep the parked copy of the outgoing account fresh
    local active_file="$STORE/.local-active"
    [[ -f "$active_file" ]] || return 0
    local name; name="$(cat "$active_file")"
    local cur; cur="$(_keychain_read 2>/dev/null)" || return 0
    [[ -n "$cur" ]] && ( umask 077; echo "$cur" > "$STORE/$name.json" )
}

_verify() {  # $1 = token, $2 = surface label
    local email; email="$(_whoami "$1")"
    if [[ -n "$email" ]]; then
        echo "$2 now runs as: $email"
    else
        echo "WARNING: could not verify identity (token may need claude's auto-refresh," >&2
        echo "or this parked credential has gone stale — /login + save it again if claude asks)." >&2
    fi
}

cmd="${1:-}"; name="${2:-}"

case "$cmd" in
save)
    [[ -n "$name" ]] || die "usage: claude-account save <name>"
    cred="$(_keychain_read)" || die "could not read the Keychain (GUI terminal only)"
    ( umask 077; echo "$cred" > "$STORE/$name.json" )
    _valid "$STORE/$name.json" || { rm -f "$STORE/$name.json"; die "Keychain blob is not a claude credential"; }
    echo "$name" > "$STORE/.local-active"
    _verify "$(_token_of "$STORE/$name.json")" "saved '$name';"
    ;;
use)
    [[ -f "$STORE/$name.json" ]] || die "no stored credential '$name' — /login that account in GUI Claude Code, then: claude-account save $name"
    _valid "$STORE/$name.json" || die "$STORE/$name.json is corrupt"
    _sync_back_local
    security add-generic-password -U -s "$SERVICE" -a "$USER" -w "$(cat "$STORE/$name.json")" \
        || die "could not write the Keychain"
    # Headless fallback file on this Mac, if one exists, must agree with the GUI.
    if [[ -f "$HOME/.claude/.credentials.json" ]]; then
        ( umask 077; cat "$STORE/$name.json" > "$HOME/.claude/.credentials.json" )
    fi
    echo "$name" > "$STORE/.local-active"
    echo "(already-running claude sessions keep their old login; new ones use this)"
    _verify "$(_token_of "$STORE/$name.json")" "this Mac"
    ;;
usage)
    [[ -n "$name" ]] || die "usage: claude-account usage <name>|all"
    if [[ "$name" == "all" ]]; then files=("$STORE"/*.json); else files=("$STORE/$name.json"); fi
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || die "no stored credential: $f"
        n="$(basename "$f" .json)"; tok="$(_token_of "$f")"
        curl -s -m 20 -D - -o /dev/null https://api.anthropic.com/v1/messages \
            -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
            -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
            -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        | python3 -c '
import sys, time
name = sys.argv[1]
vals = {}
for line in sys.stdin:
    k, _, v = line.strip().partition(": ")
    vals[k.lower()] = v
def fmt(bucket):
    u = vals.get(f"anthropic-ratelimit-unified-{bucket}-utilization")
    r = vals.get(f"anthropic-ratelimit-unified-{bucket}-reset")
    if u is None:
        return "?"
    when = time.strftime("%m-%d %H:%M", time.localtime(int(r))) if r else "?"
    return f"{float(u)*100:.0f}% (resets {when})"
if not vals.get("anthropic-ratelimit-unified-7d-utilization"):
    print(f"{name:>6}:  could not read usage (token stale? switch to it once so claude refreshes it)")
else:
    print(f"{name:>6}:  5h " + fmt("5h") + "   7d " + fmt("7d"))
' "$n"
    done
    ;;
*)
    die "usage: claude-account <save|use|usage> <name>"
    ;;
esac
