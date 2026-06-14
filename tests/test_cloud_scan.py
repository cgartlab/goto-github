#!/usr/bin/env python3
"""
test-python.py — unit tests for scripts/cloud-scan.py
Run: python3 tests/test-python.py
       or: make test
"""

import json
import os
import subprocess
import sys
import unittest
from unittest.mock import patch
# Add scripts/ to path so we can import cloud_scan
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import cloud_scan


class TestValidateIp(unittest.TestCase):
    """Test cloud-scan.py::validate_ip with stubbed curl."""

    def _mock_curl_ok(self, *args, **kwargs):
        """Return a successful GitHub HTML response."""
        return subprocess.CompletedProcess(
            args, returncode=0,
            stdout="200,0.5,150000",
            stderr="",
        )

    def _mock_curl_timeout(self, *args, **kwargs):
        """Return empty (simulate timeout/reset)."""
        return subprocess.CompletedProcess(args, returncode=0, stdout="", stderr="")

    def _mock_curl_400(self, *args, **kwargs):
        """Return 400 Bad Request."""
        return subprocess.CompletedProcess(
            args, returncode=0,
            stdout="400,0.1,0",
            stderr="",
        )

    def test_validate_ip_success(self):
        with patch("subprocess.run", self._mock_curl_ok):
            result = cloud_scan.validate_ip("140.82.114.20")
        self.assertIsNotNone(result)
        self.assertEqual(result["ip"], "140.82.114.20")
        self.assertEqual(result["http_code"], 200)
        self.assertEqual(result["time"], 0.5)
        self.assertEqual(result["size"], 150000)

    def test_validate_ip_timeout(self):
        with patch("subprocess.run", self._mock_curl_timeout):
            result = cloud_scan.validate_ip("140.82.114.20")
        self.assertIsNone(result)

    def test_validate_ip_400(self):
        with patch("subprocess.run", self._mock_curl_400):
            result = cloud_scan.validate_ip("140.82.114.20")
        self.assertIsNone(result)


class TestGenerateJsonOutput(unittest.TestCase):
    """Test cloud-scan.py::generate_json_output format."""

    def test_required_keys(self):
        best_ips = [{"ip": "140.82.114.20", "http_code": 200, "time": 0.5, "size": 150000}]
        domain_tests = {
            "github.com": [{"ip": "140.82.114.20", "http_code": 200, "time": 0.5, "size": 150000}],
            "api.github.com": [{"ip": "140.82.114.20", "http_code": 200, "time": 0.6, "size": 2000}],
        }
        output = cloud_scan.generate_json_output(best_ips, domain_tests)

        self.assertIn("servers", output)
        self.assertIn("hosts_block", output)
        self.assertIn("updated_at", output)
        self.assertIn("meta", output)

    def test_github_mode_is_hosts(self):
        best_ips = [{"ip": "140.82.114.20", "http_code": 200, "time": 0.5, "size": 150000}]
        domain_tests = {
            "github.com": [{"ip": "140.82.114.20", "http_code": 200, "time": 0.5, "size": 150000}],
        }
        output = cloud_scan.generate_json_output(best_ips, domain_tests)
        self.assertEqual(output["servers"]["github.com"]["mode"], "hosts")
        self.assertEqual(output["servers"]["github.com"]["best_ip"], "140.82.114.20")

    def test_api_mode_is_dns(self):
        best_ips = [{"ip": "140.82.114.20", "http_code": 200, "time": 0.5, "size": 150000}]
        domain_tests = {
            "api.github.com": [{"ip": "140.82.114.20", "http_code": 200, "time": 0.6, "size": 2000}],
        }
        output = cloud_scan.generate_json_output(best_ips, domain_tests)
        self.assertEqual(output["servers"]["api.github.com"]["mode"], "dns")

    def test_json_is_parseable(self):
        best_ips = [{"ip": "140.82.114.20", "http_code": 200, "time": 0.5, "size": 150000}]
        domain_tests = {
            "github.com": [{"ip": "140.82.114.20", "http_code": 200, "time": 0.5, "size": 150000}],
        }
        output = cloud_scan.generate_json_output(best_ips, domain_tests)
        # Should not raise
        parsed = json.loads(json.dumps(output))
        self.assertEqual(parsed["servers"]["github.com"]["best_ip"], "140.82.114.20")


class TestDnsOnlyDomains(unittest.TestCase):
    """Test DNS_ONLY_DOMAINS consistency."""

    def test_api_is_dns_only(self):
        self.assertIn("api.github.com", cloud_scan.DNS_ONLY_DOMAINS)

    def test_github_is_not_dns_only(self):
        self.assertNotIn("github.com", cloud_scan.DNS_ONLY_DOMAINS)


class TestExpandCidrs(unittest.TestCase):
    """Test CIDR expansion."""

    def test_expand_returns_ips(self):
        ips = cloud_scan.expand_cidrs()
        self.assertIsInstance(ips, list)
        self.assertGreater(len(ips), 100)
        # All should be valid IPv4 addresses
        for ip in ips[:10]:
            self.assertRegex(ip, r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$")


if __name__ == "__main__":
    unittest.main(verbosity=2)
