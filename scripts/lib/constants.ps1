# scripts/lib/constants.ps1 -- shared constants for the skill scripts
#
# Single source of truth for the skill layer. The bash twin is
# scripts/lib/constants.sh; shared/parity-check.sh asserts the two agree on
# markers and sources.
#
# Deliberately independent of ps1/lib/00-constants.ps1: that module belongs to
# the scan-based CLI implementation and does not carry the skill's contract
# (no SOURCES, no KEEP_BACKUPS, no PROBE_TEST_CAP). The skill scripts must not
# depend on another implementation's internals.

if (Get-Variable -Name 'GOTO_GITHUB_SKILL_CONSTANTS_LOADED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_SKILL_CONSTANTS_LOADED = $true

# -- Hosts file and marker block ----------------------------------------------
$script:HOSTS_FILE = if ($env:HOSTS_FILE) { $env:HOSTS_FILE } else { "$env:SystemRoot\System32\drivers\etc\hosts" }
$script:MARKER_START = '# >>> goto-github >>>'
$script:MARKER_END   = '# <<< goto-github <<<'

# -- Community hosts sources (tried in order) ---------------------------------
# Mirrors lib/00-constants.sh SOURCES.
$script:SOURCES = @(
    'https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts'
    'https://raw.hellogithub.com/hosts'
    'https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts'
)

# -- Core domains written into the marker block -------------------------------
# Deliberately shorter than the CLI's CORE_DOMAINS: the skill writes only the
# domains that carry git/API/download traffic. Extra domains (collector,
# community, ...) add noise without improving reachability.
$script:CORE_DOMAINS = @(
    'github.com'
    'api.github.com'
    'gist.github.com'
    'codeload.github.com'
)

# -- Known-good priority IPs (fast path) --------------------------------------
$script:PRIORITY_IPS = @(
    '140.82.112.3'
    '140.82.113.3'
    '140.82.114.3'
    '140.82.113.4'
    '140.82.114.4'
    '140.82.113.20'
    '140.82.114.20'
    '140.82.112.20'
)

# -- CIDR ranges (last-resort scan) -------------------------------------------
$script:CIDR_RANGES = @(
    '140.82.112.0/20'
    '185.199.108.0/22'
    '192.30.252.0/22'
    '143.55.64.0/20'
)

# -- Probe tuning -------------------------------------------------------------
$script:CONNECT_TIMEOUT = 3
$script:MAX_TIME = 6
$script:CONCURRENT_BATCH = 100
$script:PROBE_TEST_CAP = 50

# -- Backup rotation ----------------------------------------------------------
$script:KEEP_BACKUPS = 5

# -- Default repo used by the git/download probe endpoints --------------------
$script:PROBE_REPO = if ($env:PROBE_REPO) { $env:PROBE_REPO } else { 'cgartlab/goto-github' }
