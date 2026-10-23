#!/usr/bin/env bash
# =============================================================================
# scripts/auth_probe.sh — credential state per transport (read-only)
# Outputs single-line JSON to stdout; progress goes to stderr.
# =============================================================================
# Why this exists: a failing `git push` has at least four distinct causes —
# no SSH key, key not authorized, no HTTPS credential, or no write permission.
# A pure connectivity probe reports all of them as "FAIL" and sends the user to
# fix the network, which is the wrong thing. This script separates them.
#
# Nothing here is a network test. Reachability lives in connectivity_probe;
# this answers "do I have the credentials this path needs".
#
# bash 3.2 compatible (macOS default).
# =============================================================================
# Usage:
#   ./scripts/auth_probe.sh [--repo owner/repo] [--help]
#
# Output fields:
#   ssh.state     transport-ok | auth-fail | blocked | no-key | unknown
#   https.state   ok | no-credentials | permission-denied | unknown
#   gh.state      keyring_ok | env_var_shadowed | none | error
# =============================================================================

set -uo pipefail

# No library is sourced, so no script-directory resolution is needed.

REPO="cgartlab/goto-github"

show_help() {
    cat <<'EOF'
Usage: auth_probe.sh [--repo owner/repo] [--help]

Credential state probe for the goto-github skill. Read-only, no network.

Separates authentication failures from network failures, which a connectivity
probe cannot do:
  ssh.state     transport-ok | auth-fail | blocked | no-key | unknown
  https.state   ok | no-credentials | permission-denied | unknown
  gh.state      keyring_ok | env_var_shadowed | none | error

Options:
  --repo owner/repo  repository used for the permission check
                     (default cgartlab/goto-github)

Output: single-line JSON on stdout.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:-cgartlab/goto-github}"; shift 2 ;;
        --help|-h) show_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; show_help >&2; exit 1 ;;
    esac
done

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

warnings=()
add_warning() { warnings+=("$1"); }

# ── SSH ──────────────────────────────────────────────────────────────────────
# Order matters: a missing key produces the same "Permission denied (publickey)"
# as an unauthorized one, so check for the key file first.
ssh_state="unknown"
ssh_detail="null"

ssh_dir="${HOME}/.ssh"
has_key="false"
for k in id_rsa id_ed25519 id_ecdsa id_dsa; do
    if [ -f "${ssh_dir}/${k}" ]; then has_key="true"; break; fi
done
# ssh-agent may hold keys even with no key file on disk
if command -v ssh-add >/dev/null 2>&1; then
    if ssh-add -l 2>/dev/null | grep -q 'SHA256\|ssh-'; then has_key="true"; fi
fi

if [ "$has_key" = "false" ]; then
    ssh_state="no-key"
    ssh_detail="\"no private key in ${ssh_dir} and none loaded in ssh-agent\""
else
    # One TCP check first: distinguishes "port closed" from "key rejected".
    # BatchMode prevents an interactive prompt from hanging the probe.
    out=$(GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8' \
        ssh -T git@github.com 2>&1 || true)

    case "$out" in
        *"successfully authenticated"*)
            ssh_state="transport-ok"
            ssh_detail="\"key is authorized on GitHub\""
            ;;
        *"Permission denied (publickey)"*)
            # Reached the auth phase, so transport is fine; the key is not
            # registered on the account matching this machine.
            ssh_state="auth-fail"
            ssh_detail="\"transport OK but the key is not authorized on any GitHub account\""
            add_warning "SSH reaches GitHub but the key is not registered; use HTTPS (your git already does) or add the key to GitHub"
            ;;
        *"Connection refused"*|*"Connection timed out"*|*"Network is unreachable"*)
            ssh_state="blocked"
            ssh_detail="\"$(json_escape "$out" | head -1)\""
            add_warning "SSH transport is blocked (port 22/443); use HTTPS or ssh.github.com:443"
            ;;
        "")
            ssh_detail="null"
            ;;
        *)
            ssh_state="unknown"
            ssh_detail="\"$(json_escape "$(printf '%s' "$out" | head -1)")\""
            ;;
    esac
fi

# ── HTTPS / git credential ───────────────────────────────────────────────────
# What matters is whether a credential helper is configured and whether gh (if
# that is the helper) has a usable token.
https_state="unknown"
https_detail="null"

helper=$(git config --get "credential.https://github.com.helper" 2>/dev/null || true)
if [ -z "$helper" ]; then
    helper=$(git config --get credential.helper 2>/dev/null || true)
fi

if [ -z "$helper" ]; then
    https_state="no-credentials"
    https_detail="\"no credential helper configured; git push over HTTPS will prompt or fail\""
    add_warning "no git credential helper configured for github.com"
else
    # `!gh auth git-credential` means gh supplies the token.
    case "$helper" in
        *"gh auth git-credential"*|*gh*)
            if command -v gh >/dev/null 2>&1; then
                perm=$(gh api "repos/${REPO}" --jq '.permissions.push' 2>/dev/null || true)
                case "$perm" in
                    true)
                        https_state="ok"
                        https_detail="\"gh token has push permission on ${REPO}\""
                        ;;
                    false)
                        https_state="permission-denied"
                        https_detail="\"gh token is valid but lacks push permission on ${REPO}\""
                        add_warning "the GitHub token has no write permission on ${REPO}"
                        ;;
                    *)
                        https_state="no-credentials"
                        https_detail="\"gh is present but has no usable token\""
                        ;;
                esac
            else
                https_state="unknown"
                https_detail="\"credential helper references gh, which is not installed\""
            fi
            ;;
        *)
            https_state="ok"
            https_detail="\"credential helper: $(json_escape "$helper")\""
            ;;
    esac
fi

# ── gh auth state ────────────────────────────────────────────────────────────
# env_var_shadowed is the subtle one: an invalid GITHUB_TOKEN shadows a valid
# keyring token, so every gh call returns 401 while git keeps working.
gh_state="error"
gh_warning="null"
if command -v gh >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        if gh api user --jq .login >/dev/null 2>&1; then
            gh_state="keyring_ok"
        else
            gh_state="env_var_shadowed"
            gh_warning="\"GITHUB_TOKEN is set but invalid; it shadows a valid keyring token and breaks all gh commands (git operations are unaffected)\""
            add_warning "GITHUB_TOKEN is invalid and shadows the keyring token"
        fi
    else
        if gh api user --jq .login >/dev/null 2>&1; then
            gh_state="keyring_ok"
        else
            gh_state="none"
        fi
    fi
else
    gh_state="none"
fi

warn_json="[]"
if [ ${#warnings[@]} -gt 0 ]; then
    warn_json="["
    first=1
    for w in "${warnings[@]}"; do
        [ $first -eq 0 ] && warn_json+=","
        warn_json+="\"$(json_escape "$w")\""
        first=0
    done
    warn_json+="]"
fi

cat <<EOF
{"ssh":{"state":"$ssh_state","detail":$ssh_detail},"https":{"state":"$https_state","detail":$https_detail},"gh":{"state":"$gh_state","warning":$gh_warning},"warnings":$warn_json}
EOF
