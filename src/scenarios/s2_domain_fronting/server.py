"""
Scenario 2 — TLS Relay Server with custom certificate

Deploy this on the relay VM. It listens for TLS connections using
a self-signed certificate, then relays traffic to the actual destination.

The client will connect with SNI=teams.microsoft.com, but the carrier
won't see the actual certificate exchange (it's encrypted after ClientHello).
The DPI only sees the SNI in the unencrypted ClientHello.

Usage:
    # Generate self-signed cert on the VM first:
    openssl req -x509 -newkey rsa:2048 -keyout relay_key.pem -out relay_cert.pem \
        -days 30 -nodes -subj '/CN=relay'

    # Start the relay:
    python3 server.py --port 9443 --cert relay_cert.pem --key relay_key.pem

Protocol (inside TLS):
    Client -> Relay:
      [optional: 1B pw_len + password]
      [1B host_len][host][2B port_be]
    Relay -> Client:
      [1B status]  (0x00 = OK, 0x01 = error)
    Then bidirectional TCP relay.
"""

import argparse
import asyncio
import logging
import ssl
import struct
import subprocess
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


def generate_self_signed_cert(cert_path: str, key_path: str) -> None:
    """Generate a self-signed cert if none exists."""
    if Path(cert_path).exists() and Path(key_path).exists():
        logger.info("Using existing cert: %s", cert_path)
        return

    logger.info("Generating self-signed certificate...")
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            key_path,
            "-out",
            cert_path,
            "-days",
            "30",
            "-nodes",
            "-subj",
            "/CN=relay",
        ],
        check=True,
        capture_output=True,
    )
    logger.info("Certificate generated: %s / %s", cert_path, key_path)


class TLSRelayServer:
    def __init__(
        self,
        bind_host: str,
        bind_port: int,
        cert: str,
        key: str,
        password: str | None = None,
    ):
        self.bind_host = bind_host
        self.bind_port = bind_port
        self.cert = cert
        self.key = key
        self.password = password
        self.active_connections = 0

    def _create_ssl_context(self) -> ssl.SSLContext:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(self.cert, self.key)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        return ctx

    async def start(self) -> None:
        ssl_ctx = self._create_ssl_context()
        server = await asyncio.start_server(
            self._handle_client, self.bind_host, self.bind_port, ssl=ssl_ctx
        )
        logger.info("TLS relay listening on %s:%d", self.bind_host, self.bind_port)
        if self.password:
            logger.info("Authentication enabled")
        async with server:
            await server.serve_forever()

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        peer = writer.get_extra_info("peername")
        self.active_connections += 1
        logger.info(
            "TLS client connected from %s (active: %d)", peer, self.active_connections
        )

        try:
            if self.password:
                pw_len_byte = await reader.readexactly(1)
                pw_len = pw_len_byte[0]
                pw = (await reader.readexactly(pw_len)).decode()
                if pw != self.password:
                    logger.warning("Auth failed from %s", peer)
                    writer.write(b"\x01")
                    await writer.drain()
                    return

            # Read destination
            host_len_byte = await reader.readexactly(1)
            host_len = host_len_byte[0]
            dst_host = (await reader.readexactly(host_len)).decode()
            dst_port = struct.unpack("!H", await reader.readexactly(2))[0]

            logger.info("TLS relay %s -> %s:%d", peer, dst_host, dst_port)

            # Connect to actual destination
            try:
                dst_reader, dst_writer = await asyncio.wait_for(
                    asyncio.open_connection(dst_host, dst_port),
                    timeout=15,
                )
            except Exception as e:
                logger.error("Failed to connect to %s:%d: %s", dst_host, dst_port, e)
                writer.write(b"\x01")
                await writer.drain()
                return

            # Success
            writer.write(b"\x00")
            await writer.drain()

            # Bidirectional relay
            await asyncio.gather(
                self._pipe(reader, dst_writer, f"{peer}->dst"),
                self._pipe(dst_reader, writer, f"dst->{peer}"),
            )

        except (asyncio.IncompleteReadError, ConnectionError, OSError) as e:
            logger.debug("Connection closed: %s", e)
        finally:
            self.active_connections -= 1
            writer.close()

    async def _pipe(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, label: str
    ) -> None:
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                writer.write(data)
                await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                writer.close()
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(description="Scenario 2 — TLS Relay Server")
    parser.add_argument("--host", default="0.0.0.0", help="Bind address")
    parser.add_argument("--port", type=int, default=9443, help="Bind port (TLS)")
    parser.add_argument("--cert", default="relay_cert.pem", help="TLS certificate")
    parser.add_argument("--key", default="relay_key.pem", help="TLS private key")
    parser.add_argument("--password", default=None, help="Optional auth password")
    parser.add_argument(
        "--auto-cert", action="store_true", help="Auto-generate self-signed cert"
    )
    args = parser.parse_args()

    if args.auto_cert:
        generate_self_signed_cert(args.cert, args.key)

    server = TLSRelayServer(args.host, args.port, args.cert, args.key, args.password)
    try:
        asyncio.run(server.start())
    except KeyboardInterrupt:
        logger.info("TLS relay shutting down")


if __name__ == "__main__":
    main()
