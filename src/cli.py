"""
Teams Tunnel Toolkit — CLI Entry Point

Usage:
    uv run tunnel-test s1 --relay-host <IP> [options]
    uv run tunnel-test s2 ...
    uv run tunnel-test verify --proxy socks5://127.0.0.1:1080
"""

import argparse
import asyncio
import sys


def main():
    parser = argparse.ArgumentParser(
        description="Teams Free Bundle Usage Bypass Toolkit",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Scenarios:
  s1    REDACTED
  s2    Domain fronting / SNI bypass
  s3    REDACTED
  s4    REDACTED
  s5    REDACTED
  s6    REDACTED
  s7    REDACTED

Example:
  uv run tunnel-test s1 --relay-host 20.50.100.200 --test-mb 5
        """,
    )
    parser.add_argument(
        "scenario", choices=["s1", "s2", "s3", "s4", "s5", "s6", "s7", "verify"]
    )
    parser.add_argument("--relay-host", help="Remote relay IP/hostname")
    parser.add_argument(
        "--relay-port", type=int, default=9050, help="Remote relay port"
    )
    parser.add_argument("--password", default=None, help="Relay auth password")
    parser.add_argument(
        "--test-mb", type=float, default=1.0, help="Test transfer size in MB"
    )
    parser.add_argument(
        "--local-port", type=int, default=1080, help="Local SOCKS5 port"
    )
    parser.add_argument(
        "--proxy", default="socks5://127.0.0.1:1080", help="Proxy URL for verify"
    )
    parser.add_argument(
        "--sni", default="teams.microsoft.com", help="SNI to spoof (S2)"
    )
    parser.add_argument(
        "--test-all-sni",
        action="store_true",
        help="Test all known Teams SNI values (S2)",
    )

    args = parser.parse_args()

    if args.scenario == "s1":
        pass
    #    if not args.relay_host:
    #        parser.error("--relay-host is required for scenario s1")
    #    from src.scenarios.s1_ip_whitelist.run import run_test
    #
    #    asyncio.run(
    #        run_test(
    #            args.relay_host,
    #            args.relay_port,
    #            args.password,
    #            args.test_mb,
    #            args.local_port,
    #        )
    #    )

    elif args.scenario == "s2":
        if not args.relay_host:
            parser.error("--relay-host is required for scenario s2")
        relay_port = args.relay_port if args.relay_port != 9050 else 9443
        from src.scenarios.s2_domain_fronting.run import run_test as run_s2

        asyncio.run(
            run_s2(
                args.relay_host,
                relay_port,
                args.password,
                args.test_mb,
                args.local_port,
                args.sni,
                args.test_all_sni,
            )
        )

    elif args.scenario == "verify":
        from src.common.verify import run_verification

        result = asyncio.run(run_verification("manual", args.proxy, args.test_mb))
        print(result.to_report_line())

    else:
        print(f"Scenario {args.scenario} not yet implemented. Coming next!")
        sys.exit(1)


if __name__ == "__main__":
    main()
