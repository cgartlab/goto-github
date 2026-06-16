#!/usr/bin/env python3
"""
GoToGitHub CDN IP Scanner — per-domain-group optimized.

Scans GitHub CDN IPs and finds the fastest-working IP for each domain group
(CORE, RAW, CODELOAD, OBJECTS, ASSETS). Priority IPs are tested first; if
fewer than MIN_PRIORITY_HITS are valid, CIDR ranges are expanded (capped at
MAX_IPS_TO_SCAN).

Output is structured JSON with per-domain best IP, timing metadata, and a
ready-to-use /etc/hosts block.

Usage:
    python3 scripts/scan.py                          # stdout JSON
    python3 scripts/scan.py --output results.json    # write to file
    python3 scripts/scan.py --format hosts           # hosts block only

Environment Variables:
    GITHUB_RUN_ID  — injected by GitHub Actions, appears in output metadata
"""

import argparse
import ipaddress
import json
import os
import random
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

# ============================================================================
# Constants (mirrored from lib/00-constants.sh)
# ============================================================================

# GitHub CDN CIDR ranges to expand when priority IPs are insufficient
CIDR_RANGES = [
    "140.82.112.0/20",
    "185.199.108.0/22",
    "192.30.252.0/22",
    "143.55.64.0/20",
]

# Pre-verified IPs that are known-good — tested first
PRIORITY_IPS = [
    "140.82.112.3",
    "140.82.113.3",
    "140.82.114.3",
    "140.82.113.4",
    "140.82.114.4",
    "140.82.113.20",
    "140.82.114.20",
    "140.82.112.20",
]

# ── Domain groups ──────────────────────────────────────────────────────────
# Each group gets its own optimal IP.  Groups with multiple domains share
# a single best IP; the representative domain is used for testing.

DOMAIN_GROUPS = {
    "CORE": {
        "domains": [
            "github.com", "www.github.com", "gist.github.com",
            "alive.github.com", "live.github.com", "central.github.com",
            "collector.github.com", "github.community",
            "desktop.github.com", "education.github.com", "status.github.com",
            "docs.github.com", "cli.github.com", "copilot.github.com",
            "login.github.com", "partner.github.com",
        ],
        # Representative domain for curl testing
        "test_domain": "github.com",
        # Minimum content size threshold: CORE pages are large HTML (>100KB)
        "min_content_size": 100000,
    },
    "RAW": {
        "domains": ["raw.githubusercontent.com"],
        "test_domain": "raw.githubusercontent.com",
        "min_content_size": 1024,
    },
    "CODELOAD": {
        "domains": ["codeload.github.com"],
        "test_domain": "codeload.github.com",
        "min_content_size": 1024,
    },
    "OBJECTS": {
        "domains": ["objects.githubusercontent.com"],
        "test_domain": "objects.githubusercontent.com",
        "min_content_size": 1024,
    },
    "ASSETS": {
        "domains": ["github.githubassets.com", "avatars.githubusercontent.com"],
        "test_domain": "github.githubassets.com",
        "min_content_size": 1024,
    },
}

# DNS-only domains: these return 400 when pinned to a CDN IP via /etc/hosts.
# They are recorded in the output as mode "dns" but never included in the
# hosts block.
DNS_ONLY_DOMAINS = {"api.github.com", "pipelines.actions.githubusercontent.com"}

# All domains across every group (for reference / completeness)
ALL_DOMAINS = []
for group in DOMAIN_GROUPS.values():
    ALL_DOMAINS.extend(group["domains"])
ALL_DOMAINS.extend(DNS_ONLY_DOMAINS)

# curl test parameters
CONNECT_TIMEOUT = 3  # seconds
MAX_TIME = 6         # seconds per curl request

# Concurrency
PRIORITY_BATCH = 15   # workers for priority IP scan
CIDR_BATCH = 100      # workers for CIDR range scan

# Content size threshold for generic validation (github.com — the "gate" test)
MIN_CONTENT_SIZE = 100000

# Priority scan fallback: extend to CIDR when fewer than this many valid IPs
MIN_PRIORITY_HITS = 3

# Hard cap on CIDR IPs to scan — prevents runaway on massive ranges
MAX_IPS_TO_SCAN = 500


# ============================================================================
# IP expansion
# ============================================================================

def expand_cidrs() -> list[str]:
    """Expand all CIDR ranges into a shuffled list of individual IPs.

    The list is shuffled to distribute the scan load fairly across subnets.
    Capped at MAX_IPS_TO_SCAN.
    """
    all_ips: list[str] = []
    for cidr in CIDR_RANGES:
        net = ipaddress.IPv4Network(cidr, strict=False)
        all_ips.extend(str(ip) for ip in net.hosts())
    random.shuffle(all_ips)
    if len(all_ips) > MAX_IPS_TO_SCAN:
        all_ips = all_ips[:MAX_IPS_TO_SCAN]
    return all_ips


# ============================================================================
# curl-based IP validation
# ============================================================================

def _run_curl(ip: str, domain: str) -> dict | None:
    """Execute a single curl probe against *domain* resolved to *ip*.

    Returns a dict with keys ``http_code``, ``time``, ``size`` on success,
    or ``None`` if the request failed / timed out.
    """
    try:
        result = subprocess.run(
            [
                "curl",
                "--resolve", f"{domain}:443:{ip}",
                "-s", "-o", "/dev/null",
                "-w", "%{http_code},%{time_total},%{size_download}",
                "--connect-timeout", str(CONNECT_TIMEOUT),
                "--max-time", str(MAX_TIME),
                f"https://{domain}/",
            ],
            capture_output=True,
            text=True,
            timeout=MAX_TIME + 2,
        )
        output = result.stdout.strip()
        if not output:
            return None

        parts = output.split(",")
        if len(parts) != 3:
            return None

        http_code_str, time_str, size_str = parts
        http_code = int(http_code_str)
        time_total = float(time_str)
        size_download = int(size_str)

        return {
            "http_code": http_code,
            "time": round(time_total, 4),
            "size": size_download,
        }
    except (subprocess.TimeoutExpired, ValueError, OSError):
        return None


def validate_ip_generic(ip: str) -> dict | None:
    """Test *ip* against github.com with the content-size gate (>100 KB).

    This is the "gate" test used for the initial priority / CIDR sweep.
    Returns a dict with ``ip``, ``time``, ``size`` keys or ``None``.
    """
    result = _run_curl(ip, "github.com")
    if result is None:
        return None
    if result["http_code"] not in (200, 301, 302):
        return None
    if result["size"] <= MIN_CONTENT_SIZE:
        return None
    return {
        "ip": ip,
        "time": result["time"],
        "size": result["size"],
    }


def validate_ip_for_domain(ip: str, domain: str, min_size: int) -> dict | None:
    """Test *ip* against a specific *domain*, requiring *min_size* content.

    Returns a dict with ``ip``, ``time``, ``size`` keys or ``None``.
    """
    result = _run_curl(ip, domain)
    if result is None:
        return None
    if result["http_code"] not in (200, 301, 302):
        return None
    if result["size"] <= min_size:
        return None
    return {
        "ip": ip,
        "time": result["time"],
        "size": result["size"],
    }


# ============================================================================
# Scanning phases
# ============================================================================

def scan_priority_ips() -> list[dict]:
    """Test all PRIORITY_IPS in parallel against github.com.

    Returns results sorted by response time (fastest first).
    Uses PRIORITY_BATCH workers.
    """
    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=PRIORITY_BATCH) as executor:
        futures = {
            executor.submit(validate_ip_generic, ip): ip
            for ip in PRIORITY_IPS
        }
        for future in as_completed(futures):
            result = future.result()
            if result:
                results.append(result)
    results.sort(key=lambda r: r["time"])
    return results


def scan_cidr_ips() -> list[dict]:
    """Expand CIDR ranges and scan IPs in parallel batches.

    Returns results sorted by response time (fastest first).
    Uses CIDR_BATCH workers.  Stops early once 100 valid IPs are collected.
    """
    all_ips = expand_cidrs()
    results: list[dict] = []
    total = len(all_ips)

    for batch_start in range(0, total, CIDR_BATCH):
        batch = all_ips[batch_start: min(batch_start + CIDR_BATCH, total)]

        with ThreadPoolExecutor(max_workers=CIDR_BATCH) as executor:
            futures = {
                executor.submit(validate_ip_generic, ip): ip
                for ip in batch
            }
            for future in as_completed(futures):
                result = future.result()
                if result:
                    results.append(result)

        # Early break: enough candidates for per-group testing
        if len(results) >= 100:
            break

    results.sort(key=lambda r: r["time"])
    return results


def scan_domain_group(
    candidate_ips: list[dict],
    group_name: str,
) -> dict | None:
    """Test the top candidate IPs against a single domain group's test domain.

    *candidate_ips* should be pre-sorted by time (fastest first).
    The function tests up to 20 candidates and returns the first valid result
    for the group's representative domain.

    Returns a dict with ``ip``, ``time``, ``size`` keys or ``None``.
    """
    group = DOMAIN_GROUPS[group_name]
    test_domain = group["test_domain"]
    min_size = group["min_content_size"]

    # Test up to 20 fastest candidates against this group's domain
    top_candidates = [r["ip"] for r in candidate_ips[:20]]
    results: list[dict] = []

    with ThreadPoolExecutor(max_workers=PRIORITY_BATCH) as executor:
        futures = {
            executor.submit(
                validate_ip_for_domain, ip, test_domain, min_size
            ): ip
            for ip in top_candidates
        }
        for future in as_completed(futures):
            result = future.result()
            if result:
                results.append(result)

    if not results:
        return None

    results.sort(key=lambda r: r["time"])
    return results[0]


# ============================================================================
# Output generation
# ============================================================================

def build_hosts_block(group_results: dict[str, dict | None]) -> str:
    """Generate the ``/etc/hosts`` block from per-group scan results.

    DNS-only domains are excluded.  The block is wrapped with the standard
    ``# >>> goto-github >>>`` / ``# <<< goto-github <<<`` markers.
    """
    lines: list[str] = []
    lines.append("# >>> goto-github >>>")
    lines.append("# Managed by goto-github — do not edit manually")
    lines.append(
        f"# Updated at {datetime.now(timezone.utc).isoformat()}"
    )
    lines.append("# Download acceleration: multi-group IP optimization enabled")

    for group_name in ["CORE", "RAW", "CODELOAD", "OBJECTS", "ASSETS"]:
        result = group_results.get(group_name)
        if result is None:
            continue
        ip = result["ip"]
        domains = " ".join(DOMAIN_GROUPS[group_name]["domains"])
        lines.append(f"{ip:15} {domains}")

    lines.append("# DNS domains (not pinned):")
    lines.append(f"#   {' '.join(sorted(DNS_ONLY_DOMAINS))}")
    lines.append("# <<< goto-github <<<")
    return "\n".join(lines)


def build_servers_map(group_results: dict[str, dict | None]) -> dict:
    """Build the ``servers`` object mapping every domain to its best IP info.

    Each domain group's best IP is assigned to every domain in that group.
    DNS-only domains get ``mode: "dns"`` with no IP pinning.
    """
    servers: dict = {}

    # Per-group domains
    for group_name in ["CORE", "RAW", "CODELOAD", "OBJECTS", "ASSETS"]:
        result = group_results.get(group_name)
        domains = DOMAIN_GROUPS[group_name]["domains"]
        for domain in domains:
            if result is not None:
                servers[domain] = {
                    "mode": "hosts",
                    "best_ip": result["ip"],
                    "best_time": result["time"],
                    "best_size": result["size"],
                }
            else:
                servers[domain] = {
                    "mode": "hosts",
                    "best_ip": None,
                    "best_time": None,
                    "best_size": None,
                }

    # DNS-only domains (not pinned)
    for domain in sorted(DNS_ONLY_DOMAINS):
        servers[domain] = {
            "mode": "dns",
            "best_ip": None,
            "best_time": None,
            "best_size": None,
        }

    return servers


def build_output(group_results: dict[str, dict | None]) -> dict:
    """Assemble the final JSON payload.

    Structure:
        updated_at          — ISO-8601 timestamp
        github_actions_run  — GITHUB_RUN_ID or "local"
        servers             — per-domain best-IP map
        hosts_block         — ready-to-use /etc/hosts block
        meta                — scan metadata (IPs tested, domains covered)
    """
    servers = build_servers_map(group_results)
    hosts_block = build_hosts_block(group_results)

    # Count how many IPs/domains were meaningful
    total_tested = 0
    groups_found = 0
    for group_name in ["CORE", "RAW", "CODELOAD", "OBJECTS", "ASSETS"]:
        result = group_results.get(group_name)
        if result is not None:
            total_tested += 1
            groups_found += 1

    return {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "github_actions_run": os.environ.get("GITHUB_RUN_ID", "local"),
        "servers": servers,
        "hosts_block": hosts_block,
        "meta": {
            "groups_optimized": groups_found,
            "total_groups": len(DOMAIN_GROUPS),
            "domain_groups": {
                name: {
                    "domains": len(g["domains"]),
                    "test_domain": g["test_domain"],
                    "min_content_size": g["min_content_size"],
                }
                for name, g in DOMAIN_GROUPS.items()
            },
            "dns_only_domains": list(sorted(DNS_ONLY_DOMAINS)),
        },
    }


# ============================================================================
# Main entry point
# ============================================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="GoToGitHub CDN IP Scanner — per-domain-group optimized"
    )
    parser.add_argument(
        "--output", "-o",
        help="Write JSON output to file (default: stdout)",
    )
    parser.add_argument(
        "--format",
        choices=["json", "hosts"],
        default="json",
        help="Output format: json (full) or hosts (block only)",
    )
    args = parser.parse_args()

    # ── Phase 1: Priority IPs ────────────────────────────────────────────
    print(
        f"Phase 1: Testing {len(PRIORITY_IPS)} priority IPs "
        f"(workers={PRIORITY_BATCH})...",
        file=sys.stderr,
    )
    priority_results = scan_priority_ips()
    print(
        f"  -> {len(priority_results)} valid (need >= {MIN_PRIORITY_HITS})",
        file=sys.stderr,
    )

    candidate_ips: list[dict] = list(priority_results)

    # ── Phase 2: CIDR expansion if needed ─────────────────────────────────
    if len(priority_results) < MIN_PRIORITY_HITS:
        print(
            f"Phase 2: Expanding CIDR ranges (cap={MAX_IPS_TO_SCAN})...",
            file=sys.stderr,
        )
        cidr_results = scan_cidr_ips()
        print(
            f"  -> {len(cidr_results)} additional valid IPs from CIDR",
            file=sys.stderr,
        )
        # Merge, deduplicate by IP, and re-sort
        seen = {r["ip"] for r in candidate_ips}
        for r in cidr_results:
            if r["ip"] not in seen:
                candidate_ips.append(r)
                seen.add(r["ip"])
        candidate_ips.sort(key=lambda r: r["time"])
        print(
            f"  -> Total candidates: {len(candidate_ips)}",
            file=sys.stderr,
        )

    # ── Phase 3: Per-domain-group optimization ────────────────────────────
    print(
        "Phase 3: Per-domain-group optimization...",
        file=sys.stderr,
    )
    group_results: dict[str, dict | None] = {}
    for group_name in ["CORE", "RAW", "CODELOAD", "OBJECTS", "ASSETS"]:
        group = DOMAIN_GROUPS[group_name]
        best = scan_domain_group(candidate_ips, group_name)
        if best is not None:
            group_results[group_name] = best
            print(
                f"  {group_name:8s} -> {best['ip']:15s}  "
                f"{best['time']:.4f}s  {best['size']} bytes",
                file=sys.stderr,
            )
        else:
            group_results[group_name] = None
            print(
                f"  {group_name:8s} -> NO VALID IP (fallback to DNS)",
                file=sys.stderr,
            )

    # ── Phase 4: Build output ─────────────────────────────────────────────
    output = build_output(group_results)
    result: str

    if args.format == "hosts":
        result = output["hosts_block"] + "\n"
    else:
        result = json.dumps(output, indent=2) + "\n"

    if args.output:
        with open(args.output, "w") as f:
            f.write(result)
        print(f"Written to {args.output}", file=sys.stderr)
    else:
        print(result, end="")


if __name__ == "__main__":
    main()
