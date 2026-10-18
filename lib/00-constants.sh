#!/usr/bin/env bash
# =============================================================================
# lib/00-constants.sh — data constants for goto-github (bash)
# Sourced by fetch.sh and by the test suite. Do not execute directly.
# =============================================================================
# shellcheck shell=bash
# SC2034: these constants are consumed by the other sourced lib modules and by
# fetch.sh; shellcheck analyses this file standalone and cannot see that use.
# shellcheck disable=SC2034

# Guard against double-sourcing
if [ -n "${GOTO_GITHUB_00_CONSTANTS_LOADED:-}" ]; then
    return 0
fi
GOTO_GITHUB_00_CONSTANTS_LOADED=1

# ── Hosts file and marker block ──────────────────────────────────────────────
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
MARKER_START="# >>> goto-github >>>"
MARKER_END="# <<< goto-github <<<"

# curl retry policy shared by every download
CURL_RETRY_OPTS=(--retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 60)

# Community-maintained hosts sources, tried in order (mirror list)
SOURCES="https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts
https://raw.hellogithub.com/hosts
https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts"

# ANSI colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Core domains whose source IPs are liveness-checked before applying.
# CDN domains (avatars, raw, objects) are deliberately not checked.
CORE_DOMAINS="github.com api.github.com gist.github.com codeload.github.com"

# ── Last-resort IP probe tuning ──────────────────────────────────────────────
# GitHub rotates edge IPs and blocking is per-IP, so a source can list an
# unreachable github.com while a neighbour in the same /24 still answers.
PROBE_RADIUS=7
PROBE_POOL_CAP=300
PROBE_TEST_CAP=50
PROBE_TIMEOUT=8
# Probe target is a real git smart-http endpoint, NOT the github.com front
# page: some edge IPs serve the front page but time out on git traffic.
PROBE_TARGET="https://github.com/github/gitignore.git/info/refs?service=git-upload-pack"

# ── Backup rotation ──────────────────────────────────────────────────────────
# Keep at most KEEP_BACKUPS recent hosts backups to avoid clutter.
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
