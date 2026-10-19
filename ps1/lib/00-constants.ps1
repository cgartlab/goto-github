# goto-github constants (PowerShell)
# Dot-source this file. Do not execute directly.
# Guard against double-sourcing (use Get-Variable to avoid Set-StrictMode errors)
if (Get-Variable -Name 'GOTO_GITHUB_PS1_00_INCLUDED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_PS1_00_INCLUDED = $true

# Install directory
# Order: env var > existing install (ps1/ layout) > existing install (bin/ layout, legacy) > dev mode (repo root)
$script:INSTALL_DIR = if ($env:GOTO_GITHUB_INSTALL_DIR) { $env:GOTO_GITHUB_INSTALL_DIR }
    elseif (Test-Path 'C:\ProgramData\goto-github\ps1\goto-github.ps1') { 'C:\ProgramData\goto-github' }
    elseif (Test-Path 'C:\ProgramData\goto-github\bin\goto-github.ps1') { 'C:\ProgramData\goto-github' }
    else { Split-Path -Parent (Split-Path $PSScriptRoot -Parent) }

$script:PS1_DIR = Split-Path -Parent $PSScriptRoot  # ps1/

# Hosts file
$script:HOSTS_FILE = "$env:SystemRoot\System32\drivers\etc\hosts"

# Markers
$script:MARKER_START = '# >>> goto-github >>>'
$script:MARKER_END   = '# <<< goto-github <<<'

# Cache file
$script:CACHE_DIR = "$env:LOCALAPPDATA\goto-github"
$script:CACHE_FILE = "$script:CACHE_DIR\cache"

# Log file
$script:LOG_DIR = "$env:LOCALAPPDATA\goto-github\logs"
$script:LOG_FILE = "$script:LOG_DIR\goto-github.log"

# Scheduler label and interval
$script:SCHEDULER_LABEL = 'com.cgartlab.goto-github'
$script:SCHEDULER_INTERVAL = 10800  # 3 hours in seconds

# Priority IPs (verified-good, return real HTML)
$script:PRIORITY_IPS_0 = '140.82.112.3'
$script:PRIORITY_IPS_1 = '140.82.113.3'
$script:PRIORITY_IPS_2 = '140.82.114.3'
$script:PRIORITY_IPS_3 = '140.82.113.4'
$script:PRIORITY_IPS_4 = '140.82.114.4'
$script:PRIORITY_IPS_5 = '140.82.113.20'
$script:PRIORITY_IPS_6 = '140.82.114.20'
$script:PRIORITY_IPS_7 = '140.82.112.20'

# All priority IPs as an array
$script:PRIORITY_IPS = @(
    $script:PRIORITY_IPS_0, $script:PRIORITY_IPS_1, $script:PRIORITY_IPS_2, $script:PRIORITY_IPS_3,
    $script:PRIORITY_IPS_4, $script:PRIORITY_IPS_5, $script:PRIORITY_IPS_6, $script:PRIORITY_IPS_7
)

# CIDR ranges for GitHub
$script:CIDR_RANGES_0 = '140.82.112.0/20'
$script:CIDR_RANGES_1 = '185.199.108.0/22'
$script:CIDR_RANGES_2 = '192.30.252.0/22'
$script:CIDR_RANGES_3 = '143.55.64.0/20'

$script:CIDR_RANGES = @(
    $script:CIDR_RANGES_0, $script:CIDR_RANGES_1, $script:CIDR_RANGES_2, $script:CIDR_RANGES_3
)

# Core domains
$script:CORE_DOMAINS_0 = 'github.com'
$script:CORE_DOMAINS_1 = 'www.github.com'
$script:CORE_DOMAINS_2 = 'gist.github.com'
$script:CORE_DOMAINS_3 = 'alive.github.com'
$script:CORE_DOMAINS_4 = 'live.github.com'
$script:CORE_DOMAINS_5 = 'central.github.com'
$script:CORE_DOMAINS_6 = 'collector.github.com'
$script:CORE_DOMAINS_7 = 'github.community'

$script:CORE_DOMAINS = @(
    $script:CORE_DOMAINS_0, $script:CORE_DOMAINS_1, $script:CORE_DOMAINS_2, $script:CORE_DOMAINS_3,
    $script:CORE_DOMAINS_4, $script:CORE_DOMAINS_5, $script:CORE_DOMAINS_6, $script:CORE_DOMAINS_7
)

# Curl settings
$script:CONCURRENT_BATCH = 100
$script:CONNECT_TIMEOUT = 3
$script:MAX_TIME = 6
$script:MIN_CONTENT_SIZE = 100000
$script:MIN_CACHE_TTL = 300
