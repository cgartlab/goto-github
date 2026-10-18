#!/usr/bin/env bash
# =============================================================================
# shared/parity-check.sh — assert the Bash and PowerShell implementations agree
# on the data constants they must share (markers + mirror source list).
# Run in CI / locally on PRs that touch either implementation.
# Exit 0 = in sync, 1 = drift detected.
# =============================================================================
# The two implementations are independent (bash fetches via lib/*.sh; PowerShell
# is a single self-contained script), but they MUST write the same marker block
# and fetch from the same sources, or a hosts file written by one is invisible
# to the other. This script guards exactly that contract.
#
# Requires: bash, grep, sed (no pwsh needed — it parses the PS source as text).
# =============================================================================

set -o nounset -o pipefail -o errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_CONST="$REPO_ROOT/lib/00-constants.sh"
PS1_ENTRY="$REPO_ROOT/goto-github.ps1"

die() { echo "PARITY FAIL: $*" >&2; exit 1; }

[ -f "$BASH_CONST" ] || die "missing $BASH_CONST"
[ -f "$PS1_ENTRY" ]  || die "missing $PS1_ENTRY"

# ── 1. Marker lines ──────────────────────────────────────────────────────────
bash_marker_start=$(grep -E '^MARKER_START=' "$BASH_CONST" | head -1 | cut -d= -f2- | tr -d '"')
bash_marker_end=$(grep -E '^MARKER_END='   "$BASH_CONST" | head -1 | cut -d= -f2- | tr -d '"')
ps_marker_start=$(grep -E "^\s*\\\$script:MARKER_START\s*=" "$PS1_ENTRY" | head -1 | sed "s/^[^=]*=[[:space:]]*//; s/^'//; s/'[[:space:]]*$//")
ps_marker_end=$(grep -E "^\s*\\\$script:MARKER_END\s*="   "$PS1_ENTRY" | head -1 | sed "s/^[^=]*=[[:space:]]*//; s/^'//; s/'[[:space:]]*$//")

[ "$bash_marker_start" = "$ps_marker_start" ] || die "MARKER_START differs: bash='$bash_marker_start' ps='$ps_marker_start'"
[ "$bash_marker_end"   = "$ps_marker_end"   ] || die "MARKER_END differs: bash='$bash_marker_end' ps='$ps_marker_end'"
echo "OK: marker lines match ('$bash_marker_start' / '$bash_marker_end')"

# ── 2. Mirror source list ────────────────────────────────────────────────────
# Extract every https URL from each implementation's SOURCES block.
bash_sources=$(sed -n '/^SOURCES=/,/^[A-Za-z_]*=/p' "$BASH_CONST" \
    | grep -oE 'https://[^ "'"'"']+' | sort -u)
ps_sources=$(sed -n '/\$script:SOURCES = @(/,/^)/p' "$PS1_ENTRY" \
    | grep -oE 'https://[^ "'"'"']+' | sort -u)

if [ -z "$bash_sources" ]; then die "no sources found in $BASH_CONST"; fi
if [ -z "$ps_sources" ];   then die "no sources found in $PS1_ENTRY"; fi

if ! diff <(printf '%s\n' "$bash_sources") <(printf '%s\n' "$ps_sources") >/dev/null; then
    echo "Bash sources:" >&2; printf '  %s\n' $bash_sources >&2
    echo "PowerShell sources:" >&2; printf '  %s\n' $ps_sources >&2
    die "mirror source list differs"
fi
echo "OK: mirror source list matches ($(printf '%s\n' "$bash_sources" | grep -c .) sources)"

echo "PARITY OK: bash and PowerShell share the same markers and sources"
