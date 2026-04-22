#!/usr/bin/env python3
"""
ardop-kiss-bridge.py — ARDOP FEC datagram mode ↔ standard KISS TCP bridge

Presents a standard KISS-over-TCP server on --kiss-port so that tncattach
can connect just as it would to Direwolf.  Internally connects to ardopcf's
command port and data port and operates in FEC (connectionless datagram) mode.

ARDOP host protocol (two TCP ports):
  cmd  port  (ardop_port):     text commands/responses, CR (0x0D) terminated
  data port  (ardop_port + 1): TX: 2-byte big-endian length + raw payload
                               RX: 2-byte big-endian length (includes 3-byte
                                   tag) + 3-byte tag ("FEC","ARQ","ERR") +
                                   raw payload

KISS protocol (TCP server, one client at a time):
  Frames delimited by FEND (0xC0).
  Content: type_byte (0x00 = data ch.0) + KISS-escaped payload.
  FEND inside payload → FESC TFEND (0xDB 0xDC)
  FESC inside payload → FESC TFESC (0xDB 0xDD)

Usage:
  python3 ardop-kiss-bridge.py \\
      --ardop-port 8515 \\
      --kiss-port  8511 \\
      --callsign   KD2MYS-5 \\
      --fecmode    4PSK.2000.100
"""

import argparse
import asyncio
import logging
import struct
import sys

# ── KISS byte constants ──────────────────────────────────────────────────────
FEND  = 0xC0   # frame end / delimiter
FESC  = 0xDB   # escape byte
TFEND = 0xDC   # transposed FEND (after FESC)
TFESC = 0xDD   # transposed FESC (after FESC)


# ── KISS helpers ─────────────────────────────────────────────────────────────
def kiss_escape(data: bytes) -> bytes:
    out = bytearray()
    for b in data:
        if b == FEND:
            out += bytes([FESC, TFEND])
        elif b == FESC:
            out += bytes([FESC, TFESC])
        else:
            out.append(b)
    return bytes(out)


def kiss_unescape(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        if data[i] == FESC and i + 1 < len(data):
            i += 1
            out.append(FEND if data[i] == TFEND else FESC)
        else:
            out.append(data[i])
        i += 1
    return bytes(out)


def parse_kiss_frames(buf: bytearray) -> list[tuple[int, bytes]]:
    """
    Extract all complete KISS frames from buf (modified in-place to consume them).
    Returns list of (type_byte, payload) tuples.
    type_byte 0x00 = data frame for channel 0; other values are KISS commands.
    """
    frames = []
    # Split on FEND; all segments between two FENDs are complete frames.
    # The last segment may be incomplete — leave it in buf.
    raw = bytes(buf)
    parts = raw.split(bytes([FEND]))
    # parts[0] is whatever was before the first FEND (junk / leading bytes)
    # parts[1:-1] are complete frame contents
    # parts[-1]  is the trailing incomplete segment
    for part in parts[1:-1]:          # skip leading junk and incomplete tail
        if len(part) == 0:
            continue                  # consecutive FENDs = padding, skip
        type_byte = part[0]
        payload   = kiss_unescape(part[1:])
        frames.append((type_byte, payload))
    # Leave the incomplete tail in buf
    del buf[:]
    buf += parts[-1] if parts else b''
    return frames


def make_kiss_frame(payload: bytes, channel: int = 0) -> bytes:
    """Wrap payload in a KISS data frame for the given channel."""
    type_byte = channel & 0x0F        # 0x00 for channel 0
    return bytes([FEND, type_byte]) + kiss_escape(payload) + bytes([FEND])


# ── ARDOP helpers ─────────────────────────────────────────────────────────────
def ardop_data_frame(payload: bytes) -> bytes:
    """Wrap payload for transmission to ardopcf data port."""
    return struct.pack('>H', len(payload)) + payload


def parse_ardop_data_frames(buf: bytearray) -> list[tuple[bytes, bytes]]:
    """
    Extract complete ARDOP data frames from buf (modified in-place).
    Returns list of (tag, payload) tuples where tag is b'FEC', b'ARQ', etc.
    """
    frames = []
    while len(buf) >= 5:              # minimum: 2-byte length + 3-byte tag
        size = struct.unpack('>H', buf[:2])[0]
        if len(buf) < 2 + size:
            break                     # incomplete frame, wait for more data
        tag     = bytes(buf[2:5])
        payload = bytes(buf[5:2 + size])
        del buf[:2 + size]
        frames.append((tag, payload))
    return frames


# ── Bridge ────────────────────────────────────────────────────────────────────
class ArdopKissBridge:
    def __init__(
        self,
        ardop_host:  str,
        ardop_port:  int,
        kiss_port:   int,
        callsign:    str,
        fecmode:     str,
        fecrepeats:  int = 0,
        log:         logging.Logger = None,
    ):
        self.ardop_host  = ardop_host
        self.ardop_port  = ardop_port          # command port
        self.data_port   = ardop_port + 1      # data port
        self.kiss_port   = kiss_port
        self.callsign    = callsign.upper()
        self.fecmode     = fecmode
        self.fecrepeats  = fecrepeats
        self.log         = log or logging.getLogger(__name__)

        # Queues: kiss_tx = frames to send via ARDOP; ardop_rx = frames received from ARDOP
        self.kiss_tx_queue: asyncio.Queue[bytes]   = asyncio.Queue()
        self.ardop_rx_queue: asyncio.Queue[bytes]  = asyncio.Queue()

        # asyncio Event: set when ardopcf is in DISC state (ready to TX)
        self.ardop_idle = asyncio.Event()
        self.ardop_idle.set()                  # assume idle at start

        # Reference to the current KISS client writer (one client at a time)
        self._kiss_writer: asyncio.StreamWriter | None = None

    # ── ardopcf command socket ────────────────────────────────────────────────

    async def _ardop_cmd_reader(self, reader: asyncio.StreamReader) -> None:
        """
        Continuously read lines from ardopcf command port.
        Update ardop_idle event based on NEWSTATE messages.
        Forward BUFFER confirmations to unblock the TX coroutine.
        """
        buf = b''
        while True:
            try:
                chunk = await reader.read(1024)
            except (asyncio.IncompleteReadError, ConnectionResetError):
                self.log.error('ardopcf command socket closed')
                return
            if not chunk:
                self.log.error('ardopcf command socket EOF')
                return
            buf += chunk
            while b'\r' in buf:
                line, buf = buf.split(b'\r', 1)
                msg = line.decode('ascii', errors='replace').strip()
                if not msg:
                    continue
                self.log.debug('ARDOP CMD << %s', msg)
                if msg.startswith('NEWSTATE'):
                    state = msg.split()[-1]
                    if state == 'DISC':
                        self.ardop_idle.set()
                        self.log.info('ARDOP idle (DISC)')
                    else:
                        self.ardop_idle.clear()
                        self.log.info('ARDOP state: %s', state)

    async def _ardop_cmd_writer(self, writer: asyncio.StreamWriter, cmd: str) -> None:
        """Send a single command to ardopcf command port."""
        self.log.debug('ARDOP CMD >> %s', cmd)
        writer.write(cmd.encode() + b'\r')
        await writer.drain()

    async def _init_ardopc(
        self,
        cmd_reader: asyncio.StreamReader,
        cmd_writer: asyncio.StreamWriter,
    ) -> None:
        """Send initialization commands to ardopcf."""
        self.log.info('Initializing ardopcf (callsign=%s fecmode=%s)', self.callsign, self.fecmode)
        await asyncio.sleep(0.3)           # let ardopcf finish startup output

        for cmd in [
            'INITIALIZE',
            f'MYCALL {self.callsign}',
            'PROTOCOLMODE FEC',
            f'FECMODE {self.fecmode}',
            f'FECREPEATS {self.fecrepeats}',
            'BUSYDET 5',
            'MONITOR TRUE',
            'LISTEN TRUE',
        ]:
            await self._ardop_cmd_writer(cmd_writer, cmd)
            await asyncio.sleep(0.05)

        # Drain any startup responses
        try:
            async with asyncio.timeout(0.5):
                while True:
                    await cmd_reader.read(1024)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError):
            pass

        self.log.info('ardopcf initialized')

    # ── ardopcf data socket ───────────────────────────────────────────────────

    async def _ardop_data_reader(self, reader: asyncio.StreamReader) -> None:
        """Read received frames from ardopcf data port and enqueue them."""
        buf = bytearray()
        while True:
            try:
                chunk = await reader.read(4096)
            except (asyncio.IncompleteReadError, ConnectionResetError):
                self.log.error('ardopcf data socket closed')
                return
            if not chunk:
                return
            buf += chunk
            for tag, payload in parse_ardop_data_frames(buf):
                if tag in (b'FEC', b'ARQ'):
                    self.log.info('ARDOP RX %s frame, %d bytes → KISS', tag.decode(), len(payload))
                    await self.ardop_rx_queue.put(payload)
                else:
                    self.log.debug('ARDOP RX ignored tag=%s', tag)

    async def _ardop_tx_loop(
        self,
        data_writer: asyncio.StreamWriter,
        cmd_writer:  asyncio.StreamWriter,
    ) -> None:
        """
        Dequeue KISS payloads and transmit them one at a time via ARDOP FEC.
        Waits for ardopcf to return to DISC state before sending the next frame.
        """
        while True:
            payload = await self.kiss_tx_queue.get()

            # Wait for ardopcf to be idle (DISC state)
            await self.ardop_idle.wait()

            self.log.info('ARDOP TX FEC %d bytes', len(payload))

            # Write payload to data port
            data_writer.write(ardop_data_frame(payload))
            await data_writer.drain()

            # Brief pause — ardopcf needs to process the data write before FECSEND
            await asyncio.sleep(0.15)

            # Trigger transmission
            await self._ardop_cmd_writer(cmd_writer, 'FECSEND TRUE')

            # Mark as busy (will be cleared when NEWSTATE DISC arrives)
            self.ardop_idle.clear()

    # ── KISS TCP server ───────────────────────────────────────────────────────

    async def _kiss_rx_handler(self, reader: asyncio.StreamReader) -> None:
        """Read KISS frames from tncattach and put them on the TX queue."""
        buf = bytearray()
        while True:
            try:
                chunk = await reader.read(4096)
            except (asyncio.IncompleteReadError, ConnectionResetError):
                break
            if not chunk:
                break
            buf += chunk
            for type_byte, payload in parse_kiss_frames(buf):
                if type_byte == 0x00:              # data frame, channel 0
                    self.log.info('KISS RX %d bytes → ARDOP TX queue', len(payload))
                    await self.kiss_tx_queue.put(payload)
                else:
                    self.log.debug('KISS non-data frame type=0x%02x ignored', type_byte)
        self.log.info('KISS client disconnected')
        self._kiss_writer = None

    async def _kiss_tx_handler(self) -> None:
        """Forward frames from ardop_rx_queue to the connected KISS client."""
        while True:
            payload = await self.ardop_rx_queue.get()
            writer = self._kiss_writer
            if writer is None:
                self.log.warning('No KISS client connected; dropping %d-byte RX frame', len(payload))
                continue
            self.log.info('KISS TX %d bytes to tncattach', len(payload))
            try:
                writer.write(make_kiss_frame(payload))
                await writer.drain()
            except (ConnectionResetError, BrokenPipeError):
                self.log.warning('KISS client write failed')
                self._kiss_writer = None

    async def _kiss_client_handler(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        """Called when tncattach connects to our KISS server."""
        peer = writer.get_extra_info('peername')
        self.log.info('KISS client connected from %s', peer)
        if self._kiss_writer is not None:
            self.log.warning('Replacing previous KISS client')
            try:
                self._kiss_writer.close()
            except Exception:
                pass
        self._kiss_writer = writer
        await self._kiss_rx_handler(reader)

    # ── Top-level runner ──────────────────────────────────────────────────────

    async def run(self) -> None:
        self.log.info(
            'Connecting to ardopcf at %s:%d / %d',
            self.ardop_host, self.ardop_port, self.data_port,
        )
        try:
            cmd_reader, cmd_writer = await asyncio.open_connection(
                self.ardop_host, self.ardop_port
            )
            data_reader, data_writer = await asyncio.open_connection(
                self.ardop_host, self.data_port
            )
        except ConnectionRefusedError:
            self.log.error(
                'Cannot connect to ardopcf at %s:%d — is it running?',
                self.ardop_host, self.ardop_port,
            )
            sys.exit(1)

        await self._init_ardopc(cmd_reader, cmd_writer)

        self.log.info('Starting KISS TCP server on port %d', self.kiss_port)
        kiss_server = await asyncio.start_server(
            self._kiss_client_handler, '0.0.0.0', self.kiss_port
        )

        async with kiss_server:
            await asyncio.gather(
                kiss_server.serve_forever(),
                self._ardop_cmd_reader(cmd_reader),
                self._ardop_data_reader(data_reader),
                self._ardop_tx_loop(data_writer, cmd_writer),
                self._kiss_tx_handler(),
            )


# ── CLI ───────────────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(
        description='ARDOP FEC ↔ KISS TCP bridge',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument('--ardop-host',  default='localhost',        help='ardopcf host')
    parser.add_argument('--ardop-port',  type=int, default=8515,     help='ardopcf command port (data=port+1)')
    parser.add_argument('--kiss-port',   type=int, default=8511,     help='KISS TCP server port for tncattach')
    parser.add_argument('--callsign',    required=True,              help='Station callsign (e.g. KD2MYS-5)')
    parser.add_argument('--fecmode',     default='4PSK.2000.100',    help='ARDOP FEC frame type')
    parser.add_argument('--fecrepeats',  type=int, default=0,        help='FEC repeat count (0=none)')
    parser.add_argument('--log-level',   default='INFO',
                        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR'])
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format='%(asctime)s %(levelname)-8s [bridge:%(lineno)d] %(message)s',
        datefmt='%H:%M:%S',
    )
    log = logging.getLogger('ardop-kiss-bridge')
    log.info(
        'ardop-kiss-bridge starting: ardopcf=%s:%d  KISS port=%d  callsign=%s  fecmode=%s',
        args.ardop_host, args.ardop_port, args.kiss_port, args.callsign, args.fecmode,
    )

    bridge = ArdopKissBridge(
        ardop_host  = args.ardop_host,
        ardop_port  = args.ardop_port,
        kiss_port   = args.kiss_port,
        callsign    = args.callsign,
        fecmode     = args.fecmode,
        fecrepeats  = args.fecrepeats,
        log         = log,
    )

    try:
        asyncio.run(bridge.run())
    except KeyboardInterrupt:
        log.info('Interrupted, shutting down')


if __name__ == '__main__':
    main()
