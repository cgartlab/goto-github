#!/usr/bin/env bash
# =============================================================================
# shared/parity-check.sh — assert the Bash and PowerShell implementations agree
# on the data constants they must share (markers + mirror source list).
# Run in CI / locally on PRs that touch either implementation.
# Exit 0 = in sync, 1 = drift detected.
# =============================================================================
# The implementations are independent but MUST write the same marker block, or a
# hosts file written by one is invisible to the other. This script guards that
# contract across every PowerShell implementation it can find:
#
#   1. goto-github.ps1            — pull-based (single file, always tracked)
#   2. ps1/lib/00-constants.ps1   — scan-based (WIP, may not be committed yet)
#
# A missing optional file is reported as an explicit SKIP, never as a pass:
# silently "passing" on a file that is simply absent would be a lie about what
# was actually checked.
#
# The mirror source list is only compared against the pull-based implementation:
# the scan-based one fetches nothing, so it has no SOURCES contract to match.
#
# Requires: bash, grep, sed (no pwsh needed — it parses the PS source as text).
# =============================================================================

set -o nounset -o pipefail -o errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_CONST="$REPO_ROOT/lib/00-constants.sh"
PS1_ENTRY="$REPO_ROOT/goto-github.ps1"
PS1_LIB_CONST="$REPO_ROOT/ps1/lib/00-constants.ps1"

die() { echo "PARITY FAIL: $*" >&2; exit 1; }

[ -f "$BASH_CONST" ] || die "missing $BASH_CONST"
[ -f "$PS1_ENTRY" ]  || die "missing $PS1_ENTRY"

# ── 1. Marker lines ──────────────────────────────────────────────────────────
bash_marker_start=$(grep -E '^MARKER_START=' "$BASH_CONST" | head -1 | cut -d= -f2- | tr -d '"')
bash_marker_end=$(grep -E '^MARKER_END='   "$BASH_CONST" | head -1 | cut -d= -f2- | tr -d '"')

# Extract a marker from a PowerShell source. Both implementations declare it as
# "$script:MARKER_START = '...'"; a missing variable yields empty output and a
# non-zero status, so callers can tell "not declared" apart from "wrong value".
extract_ps_marker() {
    local file="$1" var="$2"
    # Regex assembled by concatenation: inlining "\$script:" inside a double
    # quoted pattern makes shellcheck 0.11 parse it as an array expansion
    # (SC1087), so the prefix stays in its own single-quoted literal.
    local re='^[[:space:]]*\$?script:'"$var"'[[:space:]]*='
    grep -E "$re" "$file" | head -1 \
        | sed "s/^[^=]*=[[:space:]]*//; s/^'//; s/'[[:space:]]*\$//"
    return 0
}

ps_marker_start=$(extract_ps_marker "$PS1_ENTRY" MARKER_START)
ps_marker_end=$(extract_ps_marker "$PS1_ENTRY" MARKER_END)

[ -n "$ps_marker_start" ] || die "MARKER_START not declared in $PS1_ENTRY"
[ -n "$ps_marker_end" ]   || die "MARKER_END not declared in $PS1_ENTRY"

[ "$bash_marker_start" = "$ps_marker_start" ] || die "MARKER_START differs: bash='$bash_marker_start' ps='$ps_marker_start'"
[ "$bash_marker_end"   = "$ps_marker_end" ]   || die "MARKER_END differs: bash='$bash_marker_end' ps='$ps_marker_end'"
echo "OK: marker lines match ('$bash_marker_start' / '$bash_marker_end')"

# ── 1b. Marker lines, scan-based implementation (optional) ───────────────────
if [ -f "$PS1_LIB_CONST" ]; then
    pslib_marker_start=$(extract_ps_marker "$PS1_LIB_CONST" MARKER_START)
    pslib_marker_end=$(extract_ps_marker "$PS1_LIB_CONST" MARKER_END)

    # An empty extraction means the variable is not declared at all — that is a
    # drift, not a pass. Say so explicitly instead of comparing two empty
    # strings (which would silently "match").
    [ -n "$pslib_marker_start" ] || die "MARKER_START not declared in $PS1_LIB_CONST"
    [ -n "$pslib_marker_end" ]   || die "MARKER_END not declared in $PS1_LIB_CONST"

    [ "$bash_marker_start" = "$pslib_marker_start" ] || \
        die "MARKER_START differs in ps1/lib: bash='$bash_marker_start' ps1-lib='$pslib_marker_start'"
    [ "$bash_marker_end" = "$pslib_marker_end" ] || \
        die "MARKER_END differs in ps1/lib: bash='$bash_marker_end' ps1-lib='$pslib_marker_end'"

    echo "OK: ps1/lib/00-constants.ps1 markers match"
else
    echo "SKIP: ps1/lib/00-constants.ps1 not present — its markers were NOT checked"
fi

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
