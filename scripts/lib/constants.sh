#!/usr/bin/env bash
# =============================================================================
# scripts/lib/constants.sh — shared constants for the skill scripts (bash twin)
#
# Single source of truth for the bash side. The PowerShell twin is
# scripts/lib/constants.ps1; shared/parity-check.sh asserts the two agree on
# markers and sources.
#
# Deliberately independent of lib/00-constants.sh: that module belongs to the
# pull-based CLI implementation. Keeping the skill's contract separate means a
# CLI change cannot silently alter what the skill writes.
# =============================================================================
# shellcheck shell=bash
# SC2034 disable: every constant here is consumed by the scripts that source
# this file; shellcheck analyses this file standalone and cannot see that use.
# shellcheck disable=SC2034

if [ -n "${GOTO_GITHUB_SKILL_CONSTANTS_LOADED:-}" ]; then
    return 0
fi
GOTO_GITHUB_SKILL_CONSTANTS_LOADED=1

# ── Hosts file and marker block ──────────────────────────────────────────────
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
MARKER_START="# >>> goto-github >>>"
MARKER_END="# <<< goto-github <<<"

# ── Community hosts sources (tried in order) ─────────────────────────────────
# Mirrors scripts/lib/constants.ps1 SOURCES.
SOURCES="https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts
https://raw.hellogithub.com/hosts
https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts"

# ── Core domains written into the marker block ───────────────────────────────
# Deliberately shorter than the CLI's CORE_DOMAINS: the skill writes only the
# domains that carry git/API/download traffic.
CORE_DOMAINS="github.com api.github.com gist.github.com codeload.github.com"

# ── Known-good priority IPs (fast path) ──────────────────────────────────────
PRIORITY_IPS=(
    140.82.112.3
    140.82.113.3
    140.82.114.3
    140.82.113.4
    140.82.114.4
    140.82.113.20
    140.82.114.20
    140.82.112.20
)

# ── CIDR ranges (last-resort scan) ───────────────────────────────────────────
CIDR_RANGES=(
    140.82.112.0/20
    185.199.108.0/22
    192.30.252.0/22
    143.55.64.0/20
)

# ── Probe tuning ─────────────────────────────────────────────────────────────
CONNECT_TIMEOUT=3
MAX_TIME=6
CONCURRENT_BATCH=100
PROBE_TEST_CAP=50

# ── Backup rotation ──────────────────────────────────────────────────────────
KEEP_BACKUPS=5

# ── Default repo used by the git/download probe endpoints ────────────────────
PROBE_REPO="${PROBE_REPO:-cgartlab/goto-github}"
