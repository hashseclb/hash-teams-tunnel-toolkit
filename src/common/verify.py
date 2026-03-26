"""
Verification utilities for testing whether tunneled traffic is billed from the free bundle.

Usage flow:
  1. Note your current data balance (manually or via carrier app)
  2. Run the tunnel and transfer a known amount of data
  3. Check the data balance again
  4. Compare: if free bundle decreased, traffic was is billed from the free bundle
"""

import asyncio
import hashlib
import logging
import time
from dataclasses import dataclass

import httpx

logger = logging.getLogger(__name__)


CHECK_IP_URLS = [
    "https://api.ipify.org?format=json",
    "https://ifconfig.me/ip",
]


@dataclass
class VerificationResult:
    """Result of a single verification test."""

    scenario: str
    test_name: str
    passed: bool
    details: str
    bytes_transferred: int = 0
    exit_ip: str = ""
    timestamp: float = 0.0

    def __post_init__(self):
        if not self.timestamp:
            self.timestamp = time.time()

    def to_report_line(self) -> str:
        status = "PASS" if self.passed else "FAIL"
        return (
            f"[{status}] {self.scenario} / {self.test_name}\n"
            f"  Exit IP: {self.exit_ip or 'N/A'}\n"
            f"  Bytes: {self.bytes_transferred}\n"
            f"  Details: {self.details}\n"
        )


async def check_exit_ip(proxy: str = "socks5://127.0.0.1:1080") -> str:
    """Check what IP the outside world sees when traffic goes through the tunnel."""
    async with httpx.AsyncClient(proxy=proxy, timeout=15) as client:
        for url in CHECK_IP_URLS:
            try:
                resp = await client.get(url)
                ip = resp.text.strip().strip('"').strip("{}")
                if "ip" in ip:
                    import json

                    ip = json.loads(resp.text)["ip"]
                logger.info("Exit IP via %s: %s", url, ip)
                return ip
            except Exception as e:
                logger.debug("Failed to check IP via %s: %s", url, e)
                continue
    return "unknown"


async def transfer_test_data(
    size_mb: float = 1.0,
    proxy: str = "socks5://127.0.0.1:1080",
) -> int:
    """
    Transfer a known amount of data through the tunnel.
    Uses a download from a speed test server.
    Returns bytes actually transferred.
    """
    size_bytes = int(size_mb * 1024 * 1024)
    url = f"https://speed.cloudflare.com/__down?bytes={size_bytes}"

    timeout = httpx.Timeout(300, connect=30)
    async with httpx.AsyncClient(proxy=proxy, timeout=timeout) as client:
        received = 0
        async with client.stream("GET", url) as resp:
            async for chunk in resp.aiter_bytes(chunk_size=65536):
                received += len(chunk)
        logger.info("Downloaded %d bytes through tunnel", received)
        return received


async def run_verification(
    scenario_name: str,
    proxy: str = "socks5://127.0.0.1:1080",
    test_size_mb: float = 1.0,
) -> VerificationResult:
    """
    Run a standard verification: check exit IP + transfer test data.
    The tester should compare data balance before/after.
    """
    exit_ip = await check_exit_ip(proxy)
    bytes_transferred = await transfer_test_data(test_size_mb, proxy)

    return VerificationResult(
        scenario=scenario_name,
        test_name="standard_transfer",
        passed=True,
        details=(
            f"Traffic exited via {exit_ip}. "
            f"Transferred {bytes_transferred / (1024 * 1024):.2f} MB. "
            f"CHECK: Compare your data balance before/after to confirm it worked."
        ),
        bytes_transferred=bytes_transferred,
        exit_ip=exit_ip,
    )


def check_ip_in_microsoft_ranges(ip: str) -> bool:
    """
    Check if an IP falls within known Microsoft/Azure ranges.
    This helps verify the tunnel exit point is within whitelisted space.
    """
    import ipaddress

    # Subset of well-known Microsoft ranges
    # Full list: https://www.microsoft.com/en-us/download/details.aspx?id=56519
    ms_prefixes = [
        "13.64.0.0/11",
        "20.33.0.0/16",
        "20.34.0.0/15",
        "20.36.0.0/14",
        "20.40.0.0/13",
        "20.48.0.0/12",
        "20.64.0.0/10",
        "20.128.0.0/16",
        "40.64.0.0/10",
        "51.104.0.0/15",
        "52.96.0.0/12",
        "52.112.0.0/14",  # Teams-specific range
        "52.120.0.0/14",
        "104.40.0.0/13",
        "104.208.0.0/13",
    ]

    try:
        addr = ipaddress.ip_address(ip)
        for prefix in ms_prefixes:
            if addr in ipaddress.ip_network(prefix):
                return True
    except ValueError:
        pass
    return False
