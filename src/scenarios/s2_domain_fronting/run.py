"""
Scenario 2 Runner — SNI-Based Bypass Test

Usage:
    uv run tunnel-test s2 --relay-host <VM_IP> --relay-port 9443 --test-mb 5

    Try different SNI values:
    uv run tunnel-test s2 --relay-host <VM_IP> --sni teams.live.com

This will:
  1. Start the local SOCKS5 proxy (127.0.0.1:1080)
  2. Connect to the relay over TLS with SNI=teams.microsoft.com
  3. All traffic appears as Teams traffic to the carrier's DPI
  4. Transfer test data to verify
"""

import argparse
import asyncio
import logging
import signal

from ...common.tunnel_base import Socks5Server
from ...common.verify import (
    check_exit_ip,
    check_ip_in_microsoft_ranges,
    run_verification,
)
from .backend import TEAMS_SNI_OPTIONS, SNISpoofBackend

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


async def run_test(
    relay_host: str,
    relay_port: int,
    password: str | None,
    test_mb: float,
    local_port: int,
    spoof_sni: str,
    test_all_sni: bool,
):
    sni_list = TEAMS_SNI_OPTIONS if test_all_sni else [spoof_sni]

    for sni in sni_list:
        print(f"\n{'=' * 60}")
        print("  SCENARIO 2: SNI Spoof Bypass")
        print(f"  Relay: {relay_host}:{relay_port}")
        print(f"  Spoofed SNI: {sni}")
        print(f"  Local SOCKS5 proxy: 127.0.0.1:{local_port}")
        print(f"{'=' * 60}\n")

        backend = SNISpoofBackend(relay_host, relay_port, password, spoof_sni=sni)
        proxy_server = Socks5Server(backend, bind_port=local_port)

        loop = asyncio.get_running_loop()
        stop_event = asyncio.Event()

        def _signal_handler():
            logger.info("Shutting down...")
            stop_event.set()

        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, _signal_handler)

        try:
            await proxy_server.start()
        except ConnectionError as e:
            print(f"  [!] Failed to connect with SNI={sni}: {e}")
            continue

        # Auto-verification
        if test_mb > 0:
            print("[*] Running automated verification...")

            proxy_url = f"socks5://127.0.0.1:{local_port}"
            exit_ip = await check_exit_ip(proxy_url)
            in_ms_range = check_ip_in_microsoft_ranges(exit_ip)

            print(f"\n  Exit IP: {exit_ip}")
            print(f"  In Microsoft IP range: {'YES' if in_ms_range else 'NO'}")
            print(f"  Spoofed SNI: {sni}")

            result = await run_verification(f"S2: SNI={sni}", proxy_url, test_mb)
            print(f"\n  {result.details}")
            print(f"  Bytes transferred: {result.bytes_transferred:,}")
            print()
            print("  ACTION REQUIRED: Compare your data balance before/after")
            print(
                f"  to confirm whether SNI={sni} triggers educational bundle billing."
            )
            print()
            print(result.to_report_line())

        if test_all_sni:
            await proxy_server.stop()
            print(f"  Stats for SNI={sni}: {proxy_server.stats.summary()}\n")
            continue

        # Keep running for manual testing
        print("[*] Tunnel is active. Press Ctrl+C to stop.\n")
        await stop_event.wait()
        await proxy_server.stop()
        print(f"\nFinal stats: {proxy_server.stats.summary()}")


def main():
    parser = argparse.ArgumentParser(description="Scenario 2 — SNI Spoof Bypass Test")
    parser.add_argument("--relay-host", required=True, help="Relay VM IP address")
    parser.add_argument(
        "--relay-port", type=int, default=9443, help="Relay TLS port (default: 9443)"
    )
    parser.add_argument("--password", default=None, help="Relay auth password")
    parser.add_argument(
        "--test-mb",
        type=float,
        default=1.0,
        help="MB to transfer for verification (0 to skip)",
    )
    parser.add_argument(
        "--local-port", type=int, default=1080, help="Local SOCKS5 port"
    )
    parser.add_argument("--sni", default="teams.microsoft.com", help="SNI to spoof")
    parser.add_argument(
        "--test-all-sni", action="store_true", help="Test all known Teams SNI values"
    )
    args = parser.parse_args()

    asyncio.run(
        run_test(
            args.relay_host,
            args.relay_port,
            args.password,
            args.test_mb,
            args.local_port,
            args.sni,
            args.test_all_sni,
        )
    )


if __name__ == "__main__":
    main()
