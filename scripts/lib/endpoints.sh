#!/usr/bin/env bash
# =============================================================================
# scripts/lib/endpoints.sh — the full GitHub service surface, in one place
#
# Sourced by connectivity_probe.sh, hosts_status.sh and cli_surface.sh.
# The bash twin of this list is scripts/lib/endpoints.ps1; they must stay in
# sync (shared/parity-check.sh checks the key set).
#
# Why this list and not "the 5 endpoints": a developer reaches GitHub through
# many paths, and they fail independently. A 5-endpoint probe reports "GitHub is
# fine" while `docker pull ghcr.io/...` or `ssh -T git@github.com` is dead.
# See references/judgment-criteria.md.
# =============================================================================
# shellcheck shell=bash

if [ -n "${GOTO_GITHUB_ENDPOINTS_LOADED:-}" ]; then
    return 0
fi
GOTO_GITHUB_ENDPOINTS_LOADED=1

# Prints "key<TAB>url<TAB>group<TAB>kind" for every endpoint this platform can
# exercise. $1 selects a subset: "fast" (default) or "all".
#
#   group: web | api | git | raw | download | registry | ssh | assets
#   kind:  http | tcp | git-smart
#
# TCP-only endpoints (ssh) cannot be probed with an HTTP status code; they are
# measured by connect success instead.
list_endpoints() {
    local scope="${1:-fast}"
    local repo="${PROBE_REPO:-cgartlab/goto-github}"

    # ── Core HTTP surface (always) ───────────────────────────────────────────
    printf 'web\thttps://github.com/\tweb\thttp\n'
    printf 'api\thttps://api.github.com/\tapi\thttp\n'
    printf 'git_read\thttps://github.com/%s/info/refs?service=git-upload-pack\tgit\tgit-smart\n' "$repo"
    printf 'git_write\thttps://github.com/%s/info/refs?service=git-receive-pack\tgit\tgit-smart\n' "$repo"
    printf 'raw\thttps://raw.githubusercontent.com/%s/main/README.md\traw\thttp\n' "$repo"
    printf 'gist\thttps://gist.githubusercontent.com/\traw\thttp\n'
    printf 'download\thttps://codeload.github.com/%s/tar.gz/refs/heads/main\tdownload\thttp\n' "$repo"
    printf 'assets\thttps://github.githubassets.com/\tassets\thttp\n'

    # ── SSH transport (TCP only; auth is a separate dimension) ───────────────
    # github.com:22 is the default. ssh.github.com:443 is the fallback that
    # works where port 22 is blocked. Both are probed because a user may have
    # either configured.
    printf 'ssh22\ttcp://github.com:22\tssh\ttcp\n'
    printf 'ssh443\ttcp://ssh.github.com:443\tssh\ttcp\n'

    # ── Package registries (slow; only in "all") ─────────────────────────────
    if [ "$scope" = "all" ]; then
        printf 'ghcr\thttps://ghcr.io/v2/\tregistry\thttp\n'
        printf 'npmpkg\thttps://npm.pkg.github.com/\tregistry\thttp\n'
        printf 'mavenpkg\thttps://maven.pkg.github.com/\tregistry\thttp\n'
        printf 'avatars\thttps://avatars.githubusercontent.com/\tassets\thttp\n'
        printf 'objects\thttps://objects.githubusercontent.com/\tassets\thttp\n'
        # Derive the Pages host from PROBE_REPO's owner instead of hard-coding one
    # account: a fork or another user's install must probe their own Pages
    # site, not a stranger's.
    local owner="${repo%%/*}"
    printf 'pages\thttps://%s.github.io/\tweb\thttp\n' "$owner"
    fi
}

# The endpoint keys that participate in the verdict. Everything else is
# reported but does not move the grade — a registry being slow should not
# downgrade "can I clone and push". See references/judgment-criteria.md.
verdict_keys() {
    printf 'git_read\napi\nweb\n'
}
