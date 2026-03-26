"""
Scenario 2: SNI-Based Bypass

Bypass hypothesis:
  The carrier inspects the SNI (Server Name Indication) field in the
  TLS ClientHello to decide whether traffic is headed to Teams/educational
  platforms. If so, setting SNI to 'teams.microsoft.com' on a connection
  to ANY server should trick the DPI into billing the traffic from the educational bundle.

How it works:
  1. Client opens a TCP connection to the relay server
  2. Client performs a TLS handshake with SNI = 'teams.microsoft.com'
     (the carrier's DPI sees this in the unencrypted ClientHello)
  3. The relay has a self-signed cert — we skip verification
     (the DPI can't see the cert mismatch because it's inside the
     encrypted TLS tunnel)
  4. Inside the TLS tunnel, we run the same relay protocol as S1
  5. All traffic appears to be 'teams.microsoft.com' to the carrier

What this tests:
  - Whether the carrier's traffic billing relies solely on SNI inspection
  - Whether the carrier validates that the server cert matches the SNI
  - Whether the carrier correlates SNI with destination IP ranges
"""

import asyncio
import logging
import ssl
import struct

from ...common.tunnel_base import TunnelBackend

logger = logging.getLogger(__name__)


TEAMS_SNI_OPTIONS = [
    "teams.microsoft.com",
    "teams.live.com",
    "statics.teams.cdn.office.net",
    "login.microsoftonline.com",
    "outlook.office365.com",
    "substrate.office.com",
]


class SNISpoofBackend(TunnelBackend):
    """
    Connects to a TLS relay server but spoofs the SNI to a
    Teams/Microsoft domain, tricking carrier DPI into thinking
    this is legitimate educational platform traffic.
    """

    def __init__(
        self,
        relay_host: str,
        relay_port: int = 9443,
        password: str | None = None,
        spoof_sni: str = "teams.microsoft.com",
    ):
        self.relay_host = relay_host
        self.relay_port = relay_port
        self.password = password
        self.spoof_sni = spoof_sni

    @property
    def name(self) -> str:
        return f"S2: SNI Spoof ({self.spoof_sni})"

    def _create_ssl_context(self) -> ssl.SSLContext:
        """
        Create an SSL context that:
        - Sends the spoofed SNI in ClientHello
        - Does NOT verify the server certificate (self-signed relay)
        """
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        # Disable cert verification — relay uses self-signed cert
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        return ctx

    async def start(self) -> None:
        logger.info(
            "SNI spoof backend ready — relay at %s:%d, SNI=%s",
            self.relay_host,
            self.relay_port,
            self.spoof_sni,
        )
        # Verify the relay is reachable with TLS + spoofed SNI
        try:
            ssl_ctx = self._create_ssl_context()
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(
                    self.relay_host,
                    self.relay_port,
                    ssl=ssl_ctx,
                    server_hostname=self.spoof_sni,
                ),
                timeout=10,
            )
            writer.close()
            await writer.wait_closed()
            logger.info("TLS relay is reachable (SNI=%s)", self.spoof_sni)
        except Exception as e:
            raise ConnectionError(
                f"Cannot reach TLS relay at {self.relay_host}:{self.relay_port}: {e}\n"
                f"Make sure server.py is running on the relay with TLS enabled."
            ) from e

    async def stop(self) -> None:
        logger.info("SNI spoof backend stopped")

    async def connect(
        self, dst_host: str, dst_port: int
    ) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        """
        Connect to the relay over TLS with spoofed SNI, then ask
        the relay to forward to dst_host:dst_port.
        """
        ssl_ctx = self._create_ssl_context()

        reader, writer = await asyncio.open_connection(
            self.relay_host,
            self.relay_port,
            ssl=ssl_ctx,
            server_hostname=self.spoof_sni,
        )

        # Inside the encrypted TLS tunnel, the carrier can't see this
        host_bytes = dst_host.encode()
        header = (
            struct.pack("!B", len(host_bytes))
            + host_bytes
            + struct.pack("!H", dst_port)
        )

        if self.password:
            pw_bytes = self.password.encode()
            header = struct.pack("!B", len(pw_bytes)) + pw_bytes + header

        writer.write(header)
        await writer.drain()

        status = await reader.readexactly(1)
        if status[0] != 0x00:
            writer.close()
            raise ConnectionError(
                f"Relay refused connection to {dst_host}:{dst_port} (status={status[0]})"
            )

        return reader, writer
