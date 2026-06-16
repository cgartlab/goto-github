#!/usr/bin/env python3
"""
GoToGitHub Cloud Scan — run in GitHub Actions to find valid GitHub CDN IPs
and publish results as a structured JSON file to a Gist.

Usage:
    python3 scripts/cloud-scan.py                     # Run scan, print JSON to stdout
    python3 scripts/cloud-scan.py --output hosts.json # Write JSON to file
    python3 scripts/cloud-scan.py --format hosts      # Print /etc/hosts block only

Environment Variables:
    GIST_ID  — Gist ID to update (optional, set by GitHub Actions workflow)
    GH_TOKEN — GitHub token with gist scope (optional, for Gist update)
"""

import ipaddress
import json
import os
import random
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

# ── Constants (mirrored from lib/00-constants.sh) ─────────────────────────

CIDR_RANGES = [
    "140.82.112.0/20",
    "185.199.108.0/22",
    "192.30.252.0/22",
    "143.55.64.0/20",
]

PRIORITY_IPS = [
    "140.82.112.3", "140.82.113.3", "140.82.114.3", "140.82.113.4",
    "140.82.114.4", "140.82.113.20", "140.82.114.20", "140.82.112.20",
]

CORE_DOMAINS = [
    "github.com", "www.github.com", "gist.github.com",
    "alive.github.com", "live.github.com", "central.github.com",
    "collector.github.com", "github.community",
    "desktop.github.com", "education.github.com", "status.github.com",
    "docs.github.com", "cli.github.com", "copilot.github.com",
    "login.github.com", "partner.github.com",
]

DOWNLOAD_DOMAINS = [
    "raw.githubusercontent.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
]

ASSET_DOMAINS = [
    "github.githubassets.com",
    "avatars.githubusercontent.com",
]

# 应走 DNS 解析的域名（不适合 fixed hosts IP）
DNS_ONLY_DOMAINS = {"api.github.com", "pipelines.actions.githubusercontent.com"}

ALL_DOMAINS = (
    CORE_DOMAINS +
    DOWNLOAD_DOMAINS +
    ASSET_DOMAINS +
    list(DNS_ONLY_DOMAINS)
)

CONNECT_TIMEOUT = 3
MAX_TIME = 6
MIN_CONTENT_SIZE = 100000  # bytes
CONCURRENT_BATCH = 100
PRIORITY_BATCH = 15  # Test more IPs in priority batch from cloud


def expand_cidrs():
    """Expand all CIDR ranges into a shuffled list of IPs."""
    all_ips = []
    for cidr in CIDR_RANGES:
        net = ipaddress.IPv4Network(cidr, strict=False)
        all_ips.extend(str(ip) for ip in net.hosts())
    random.shuffle(all_ips)
    return all_ips


def validate_ip(ip):
    """Test a single IP against github.com. Returns dict or None."""
    try:
        result = subprocess.run(
            [
                "curl", "--resolve", f"github.com:443:{ip}",
                "-s", "-o", "/dev/null",
                "-w", "%{http_code},%{time_total},%{size_download}",
                "--connect-timeout", str(CONNECT_TIMEOUT),
                "--max-time", str(MAX_TIME),
                "https://github.com/",
            ],
            capture_output=True, text=True, timeout=MAX_TIME + 2,
        )
        output = result.stdout.strip()
        if not output:
            return None

        parts = output.split(",")
        if len(parts) != 3:
            return None

        http_code, time_total, size_download = parts
        http_code = int(http_code)
        time_total = float(time_total)
        size_download = int(size_download)

        if http_code in (200, 301, 302) and size_download > MIN_CONTENT_SIZE:
            return {
                "ip": ip,
                "http_code": http_code,
                "time": round(time_total, 4),
                "size": size_download,
            }
    except (subprocess.TimeoutExpired, ValueError, OSError):
        pass
    return None


def test_domain_for_ip(ip, domain):
    """Test a specific IP against a domain. Returns response info or None."""
    try:
        result = subprocess.run(
            [
                "curl", "--resolve", f"{domain}:443:{ip}",
                "-s", "-o", "/dev/null",
                "-w", "%{http_code},%{time_total},%{size_download}",
                "--connect-timeout", str(CONNECT_TIMEOUT),
                "--max-time", str(MAX_TIME),
                f"https://{domain}/",
            ],
            capture_output=True, text=True, timeout=MAX_TIME + 2,
        )
        output = result.stdout.strip()
        if not output:
            return None

        parts = output.split(",")
        if len(parts) != 3:
            return None

        http_code, time_total, size_download = parts
        http_code = int(http_code)
        time_total = float(time_total)
        size_download = int(size_download)

        if http_code in (200, 301, 302):
            return {
                "http_code": http_code,
                "time": round(time_total, 4),
                "size": size_download,
            }
    except (subprocess.TimeoutExpired, ValueError, OSError):
        pass
    return None


def scan_priority_ips():
    """Test priority IPs in parallel, return sorted valid results."""
    results = []
    with ThreadPoolExecutor(max_workers=PRIORITY_BATCH) as executor:
        futures = {executor.submit(validate_ip, ip): ip for ip in PRIORITY_IPS}
        for future in as_completed(futures):
            result = future.result()
            if result:
                results.append(result)
    results.sort(key=lambda r: r["time"])
    return results


def scan_cidr_ips(all_ips):
    """Scan all CIDR IPs in parallel batches, return sorted valid results (top 50)."""
    results = []
    total = len(all_ips)

    for batch_start in range(0, total, CONCURRENT_BATCH):
        batch = all_ips[batch_start:min(batch_start + CONCURRENT_BATCH, total)]

        with ThreadPoolExecutor(max_workers=CONCURRENT_BATCH) as executor:
            futures = {executor.submit(validate_ip, ip): ip for ip in batch}
            for future in as_completed(futures):
                result = future.result()
                if result:
                    results.append(result)

        # Early break if we have enough candidates
        if len(results) >= 100:
            break

    results.sort(key=lambda r: r["time"])
    return results[:50]


def test_best_ips_against_all_domains(best_ips):
    """
    Test the top 10 IPs against all 20 domains.
    Returns a dict: {domain: {ip: info, time, ...}}
    """
    tested = {}
    top_ips = [r["ip"] for r in best_ips[:10]]

    for domain in ALL_DOMAINS:
        domain_results = []
        for ip in top_ips:
            result = test_domain_for_ip(ip, domain)
            if result:
                domain_results.append({
                    "ip": ip,
                    **result,
                })

        if domain_results:
            domain_results.sort(key=lambda r: r["time"])
            tested[domain] = domain_results
        else:
            tested[domain] = []

    return tested


def generate_hosts_block(best_ips, domain_tests):
    """Generate a recommended /etc/hosts block based on test results."""
    # Group domains by their best IP
    ip_groups = {}

    for domain, results in domain_tests.items():
        if domain.lower() in DNS_ONLY_DOMAINS:
            continue
        if not results:
            continue

        best = results[0]
        ip = best["ip"]
        if ip not in ip_groups:
            ip_groups[ip] = []
        ip_groups[ip].append(domain)

    # Generate block
    lines = []
    lines.append("# >>> goto-github >>>")
    lines.append("# Managed by GoToGitHub Cloud Scan — do not edit manually")
    lines.append(f"# Updated at {datetime.now(timezone.utc).isoformat()}")
    lines.append(f"# Source: GitHub Actions cloud scan")

    # Group domains by their best-performing IP
    if domain_tests.get("github.com"):
        for ip, domains in sorted(ip_groups.items()):
            lines.append(f"{ip:15} {' '.join(domains)}")

    lines.append("# <<< goto-github <<<")
    return "\n".join(lines)


def generate_json_output(best_ips, domain_tests):
    """Generate structured JSON output for Gist publishing."""
    servers = {}
    for domain, results in domain_tests.items():
        if dns_only := domain.lower() in DNS_ONLY_DOMAINS:
            # Mark as DNS-only, show first working result for reference
            if results:
                best = results[0]
                servers[domain] = {
                    "mode": "dns",
                    "best_ip": best["ip"],
                    "best_time": best["time"],
                    "best_size": best["size"],
                }
            else:
                servers[domain] = {"mode": "dns", "best_ip": None}
        else:
            if results:
                best = results[0]
                servers[domain] = {
                    "mode": "hosts",
                    "best_ip": best["ip"],
                    "best_time": best["time"],
                    "best_size": best["size"],
                    "all_candidates": [
                        {"ip": r["ip"], "time": r["time"], "size": r["size"]}
                        for r in results[:5]
                    ],
                }
            else:
                servers[domain] = {"mode": "unreachable"}

    # Generate hosts block
    hosts_block = generate_hosts_block(best_ips, domain_tests)

    return {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "github_actions_run": os.environ.get("GITHUB_RUN_ID", "local"),
        "servers": servers,
        "hosts_block": hosts_block,
        "meta": {
            "total_ips_tested": len(best_ips),
            "total_domains": len(ALL_DOMAINS),
            "domain_groups": {
                "core": len(CORE_DOMAINS),
                "download": len(DOWNLOAD_DOMAINS),
                "assets": len(ASSET_DOMAINS),
                "dns_only": len(DNS_ONLY_DOMAINS),
            }
        }
    }


def main():
    import argparse

    parser = argparse.ArgumentParser(description="GoToGitHub Cloud IP Scanner")
    parser.add_argument("--output", "-o",
                        help="Write JSON output to file (default: stdout)")
    parser.add_argument("--format", choices=["json", "hosts"], default="json",
                        help="Output format (json or hosts block)")
    args = parser.parse_args()

    print(f"Scanning {len(PRIORITY_IPS)} priority IPs...", file=sys.stderr)
    priority_results = scan_priority_ips()
    print(f"  Found {len(priority_results)} valid priority IPs", file=sys.stderr)

    if len(priority_results) < 5:
        print("Expanding CIDR ranges for more candidates...", file=sys.stderr)
        all_ips = expand_cidrs()
        print(f"  Generated {len(all_ips)} IPs from CIDR ranges, scanning...", file=sys.stderr)
        cidr_results = scan_cidr_ips(all_ips)
        print(f"  Found {len(cidr_results)} valid CIDR IPs", file=sys.stderr)
        best_ips = priority_results + cidr_results
    else:
        best_ips = priority_results

    best_ips.sort(key=lambda r: r["time"])

    print("Testing best IPs against all domains...", file=sys.stderr)
    domain_tests = test_best_ips_against_all_domains(best_ips)
    print(f"  Tested {len(best_ips[:10])} IPs × {len(ALL_DOMAINS)} domains", file=sys.stderr)

    output = generate_json_output(best_ips, domain_tests)

    if args.format == "hosts":
        result = output["hosts_block"]
    else:
        result = json.dumps(output, indent=2)

    if args.output:
        with open(args.output, "w") as f:
            f.write(result + "\n")
        print(f"Written to {args.output}", file=sys.stderr)
    else:
        print(result)


if __name__ == "__main__":
    main()
