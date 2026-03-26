"""
Base tunnel abstraction.

Each scenario implements a TunnelBackend that defines how traffic is
forwarded through the whitelisted channel. The local SOCKS5 proxy
captures PC traffic and hands it to the active backend.
"""

import abc
import asyncio
import logging
import struct
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


@dataclass
class TunnelStats:
    """Live counters for the tunnel session."""

    bytes_up: int = 0
    bytes_down: int = 0
    connections: int = 0
    start_time: float = field(default_factory=lambda: __import__("time").time())

    @property
    def elapsed(self) -> float:
        import time

        return time.time() - self.start_time

    def summary(self) -> str:
        up_mb = self.bytes_up / (1024 * 1024)
        down_mb = self.bytes_down / (1024 * 1024)
        return (
            f"Connections: {self.connections} | "
            f"Up: {up_mb:.2f} MB | Down: {down_mb:.2f} MB | "
            f"Elapsed: {self.elapsed:.0f}s"
        )


class TunnelBackend(abc.ABC):
    """
    Abstract backend that each scenario implements.

    The backend receives raw TCP connection data from the local SOCKS5
    proxy and is responsible for forwarding it through the whitelisted
    channel and returning the response data.
    """

    @abc.abstractmethod
    async def connect(
        self, dst_host: str, dst_port: int
    ) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        """
        Establish a tunnel connection to the destination through the
        whitelisted channel. Returns (reader, writer) for the tunneled
        stream.
        """
        ...

    @abc.abstractmethod
    async def start(self) -> None:
        """Initialize the backend (connect to relay, authenticate, ...)."""
        ...

    @abc.abstractmethod
    async def stop(self) -> None:
        """Tear down the backend."""
        ...

    @property
    @abc.abstractmethod
    def name(self) -> str:
        """Human-readable scenario name for logging/reports."""
        ...


class Socks5Server:
    """
    Local SOCKS5 proxy that captures all PC traffic and forwards it
    through a TunnelBackend.

    Configure the OS / browser to use this as a SOCKS5 proxy
    (default 127.0.0.1:1080) to route all traffic through the tunnel.
    """

    SOCKS5_VER = 0x05
    CONNECT = 0x01
    ATYP_IPV4 = 0x01
    ATYP_DOMAIN = 0x03
    ATYP_IPV6 = 0x04

    def __init__(
        self,
        backend: TunnelBackend,
        bind_host: str = "127.0.0.1",
        bind_port: int = 1080,
    ):
        self.backend = backend
        self.bind_host = bind_host
        self.bind_port = bind_port
        self.stats = TunnelStats()
        self._server: asyncio.Server | None = None

    async def start(self) -> None:
        await self.backend.start()
        self._server = await asyncio.start_server(
            self._handle_client, self.bind_host, self.bind_port
        )
        logger.info(
            "SOCKS5 proxy listening on %s:%d (backend: %s)",
            self.bind_host,
            self.bind_port,
            self.backend.name,
        )

    async def stop(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        await self.backend.stop()
        logger.info("Tunnel stopped. %s", self.stats.summary())

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        peer = writer.get_extra_info("peername")
        try:
            # --- SOCKS5 handshake ---
            header = await reader.readexactly(2)
            ver, nmethods = header
            if ver != self.SOCKS5_VER:
                writer.close()
                return
            await reader.readexactly(nmethods)  # consume method list

            # No-auth response
            writer.write(struct.pack("!BB", self.SOCKS5_VER, 0x00))
            await writer.drain()

            # --- SOCKS5 request ---
            req = await reader.readexactly(4)
            ver, cmd, _, atyp = req

            if cmd != self.CONNECT:
                await self._send_reply(writer, 0x07)  # command not supported
                return

            dst_host, dst_port = await self._parse_address(reader, atyp)
            logger.info("CONNECT %s:%d from %s", dst_host, dst_port, peer)

            # --- Connect through tunnel backend ---
            try:
                remote_reader, remote_writer = await self.backend.connect(
                    dst_host, dst_port
                )
            except Exception as e:
                logger.error("Backend connect failed: %s", e)
                await self._send_reply(writer, 0x05)  # connection refused
                return

            await self._send_reply(writer, 0x00)  # success
            self.stats.connections += 1

            # --- Bidirectional relay ---
            await asyncio.gather(
                self._relay(reader, remote_writer, "up"),
                self._relay(remote_reader, writer, "down"),
            )

        except (asyncio.IncompleteReadError, ConnectionError, OSError) as e:
            logger.debug("Client connection closed: %s", e)
        finally:
            writer.close()

    async def _parse_address(
        self, reader: asyncio.StreamReader, atyp: int
    ) -> tuple[str, int]:
        if atyp == self.ATYP_IPV4:
            raw = await reader.readexactly(4)
            import socket

            host = socket.inet_ntoa(raw)
        elif atyp == self.ATYP_DOMAIN:
            length = (await reader.readexactly(1))[0]
            host = (await reader.readexactly(length)).decode()
        elif atyp == self.ATYP_IPV6:
            raw = await reader.readexactly(16)
            import socket

            host = socket.inet_ntop(socket.AF_INET6, raw)
        else:
            raise ValueError(f"Unsupported address type: {atyp}")

        port_data = await reader.readexactly(2)
        port = struct.unpack("!H", port_data)[0]
        return host, port

    async def _send_reply(self, writer: asyncio.StreamWriter, status: int) -> None:
        # Minimal SOCKS5 reply: VER, STATUS, RSV, ATYP=IPv4, BND.ADDR=0, BND.PORT=0
        reply = struct.pack(
            "!BBBB4sH",
            self.SOCKS5_VER,
            status,
            0x00,
            self.ATYP_IPV4,
            b"\x00\x00\x00\x00",
            0,
        )
        writer.write(reply)
        await writer.drain()
        if status != 0x00:
            writer.close()

    async def _relay(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, direction: str
    ) -> None:
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                writer.write(data)
                await writer.drain()
                if direction == "up":
                    self.stats.bytes_up += len(data)
                else:
                    self.stats.bytes_down += len(data)
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                writer.close()
            except OSError:
                pass
