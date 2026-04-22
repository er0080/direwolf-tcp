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

PTT:
  ardopcf is started without any -p/-c PTT flag.  It sends "PTT TRUE" /
  "PTT FALSE" to the host (this bridge) on the command port.  The bridge
  handles PTT via pyserial RTS on --ptt-port (pyserial sets DTR=True on open,
  which is required by CDC-ACM USB devices like the IC-705 before they will
  respond to RTS changes).

Usage:
  python3 ardop-kiss-bridge.py \\
      --ardop-port 8515 \\
      --kiss-port  8511 \\
      --callsign   KD2MYS-5 \\
      --fecmode    4PSK.2000.100 \\
      --ptt-port   /dev/ic_705_b
"""

import argparse
import asyncio
import logging
import struct
import sys
import time

try:
    import serial as _pyserial
    _HAS_SERIAL = True
except ImportError:
    _HAS_SERIAL = False

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


# ── Half-duplex flow control constants ───────────────────────────────────────
#
# Three-layer protection against simultaneous TX (collisions):
#
#  POST_RX_HOLDOFF  — after receiving a frame (FECRCV→DISC), wait before
#                     TX.  Prevents us from stepping on the remote station
#                     while it is returning to DISC after its own TX.
#
#  POST_TX_YIELD    — after our own PTT goes FALSE, wait before TX again.
#                     This is the critical layer for TCP: without it, a
#                     bridge with a queue of segments fires them back-to-back,
#                     never yielding the channel to the other side for ACKs.
#                     Must be longer than POST_RX_HOLDOFF + TX_SETTLE_DELAY
#                     so the remote has time to start its preamble before this
#                     timer expires; once the preamble is audible, ardopcf
#                     reports BUSY/FECRCV and we block automatically.
#
#  TX_SETTLE_DELAY  — final check after both holdoffs clear.  Gives ardopcf
#                     time to register a signal that started right as DISC
#                     was seen (BUSYDET detection lag).
#
POST_RX_HOLDOFF = 1.0   # seconds  (was 0.8 — increase for safety margin)
POST_TX_YIELD   = 2.0   # seconds  (NEW — must be > POST_RX_HOLDOFF + TX_SETTLE_DELAY)
TX_SETTLE_DELAY = 0.5   # seconds  (was 0.3)

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
        ptt_port:    str = None,
        ptt_baud:    int = 19200,
        log:         logging.Logger = None,
    ):
        self.ardop_host  = ardop_host
        self.ardop_port  = ardop_port          # command port
        self.data_port   = ardop_port + 1      # data port
        self.kiss_port   = kiss_port
        self.callsign    = callsign.upper()
        self.fecmode     = fecmode
        self.fecrepeats  = fecrepeats
        self.ptt_port    = ptt_port
        self.ptt_baud    = ptt_baud
        self.log         = log or logging.getLogger(__name__)

        # Queues: kiss_tx = frames to send via ARDOP; ardop_rx = frames received from ARDOP
        self.kiss_tx_queue: asyncio.Queue[bytes]   = asyncio.Queue()
        self.ardop_rx_queue: asyncio.Queue[bytes]  = asyncio.Queue()

        # asyncio Event: set when ardopcf is in DISC state (ready to TX)
        self.ardop_idle = asyncio.Event()
        self.ardop_idle.set()                  # assume idle at start

        # Half-duplex flow control timers (monotonic timestamps).
        # _post_rx_holdoff_until: set on FECRCV→DISC (we just finished receiving)
        # _post_tx_yield_until:   set on TX→DISC    (we just finished transmitting)
        self._post_rx_holdoff_until: float = 0.0
        self._post_tx_yield_until:   float = 0.0
        self._last_ardop_state: str = 'DISC'

        # Set to True when we send FECSEND TRUE; cleared on NEWSTATE DISC.
        # Used to distinguish our TX→DISC from remote FECRCV→DISC so the
        # yield timer is set in the right handler.
        self._transmitting: bool = False

        # Set True by BUSY TRUE, cleared by BUSY FALSE.
        # Checked at the TX settle step — does not touch ardop_idle so that
        # a BUSY TRUE while already in DISC state cannot deadlock the bridge
        # (ardopcf only sends NEWSTATE DISC on transitions, not re-announcements).
        self._channel_busy: bool = False

        # Reference to the current KISS client writer (one client at a time)
        self._kiss_writer: asyncio.StreamWriter | None = None

        # pyserial handle for RTS PTT (opened in run() if --ptt-port given)
        self._ptt_serial = None

    # ── ardopcf command socket ────────────────────────────────────────────────

    async def _ardop_cmd_reader(self, reader: asyncio.StreamReader) -> None:
        """
        Continuously read lines from ardopcf command port.
        Update ardop_idle event based on NEWSTATE messages.
        Handle PTT TRUE/FALSE by asserting/clearing RTS on the PTT serial port.
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
                        if self._last_ardop_state == 'FECRCV':
                            # Remote station just finished transmitting.
                            self._post_rx_holdoff_until = time.monotonic() + POST_RX_HOLDOFF
                            self.log.debug('Post-RX hold-off %.1fs started', POST_RX_HOLDOFF)
                        elif self._transmitting:
                            # We just finished transmitting.  Set the yield
                            # timer HERE, before ardop_idle.set(), so it is
                            # guaranteed visible the instant the TX loop wakes.
                            # (PTT FALSE may arrive in a separate TCP read after
                            # NEWSTATE DISC, making it useless for this purpose.)
                            self._post_tx_yield_until = time.monotonic() + POST_TX_YIELD
                            self.log.debug('Post-TX yield %.1fs started', POST_TX_YIELD)
                        self._transmitting = False
                        self._last_ardop_state = 'DISC'
                        self.ardop_idle.set()
                        self.log.info('ARDOP idle (DISC)')
                    else:
                        self._last_ardop_state = state
                        self.ardop_idle.clear()
                        self.log.info('ARDOP state: %s', state)
                elif msg.startswith('BUSY '):
                    # ardopcf BUSYDET: audio energy detected on the channel.
                    # Track this with a separate flag; do NOT touch ardop_idle.
                    # ardopcf only sends NEWSTATE DISC on transitions, so if
                    # BUSY TRUE fires while already in DISC, clearing ardop_idle
                    # here would deadlock the bridge with no re-announcement
                    # to recover from.  The _channel_busy flag is checked at
                    # the TX settle step as an additional gate.
                    self._channel_busy = (msg.split()[-1] == 'TRUE')
                    self.log.info('BUSYDET: %s', 'busy' if self._channel_busy else 'clear')
                elif msg.startswith('PTT '):
                    ptt_on = msg.split()[-1] == 'TRUE'
                    if self._ptt_serial is not None:
                        self._ptt_serial.rts = ptt_on
                        self.log.info('PTT %s → RTS on %s', 'ON' if ptt_on else 'OFF', self.ptt_port)
                    else:
                        self.log.debug('PTT %s (no --ptt-port configured)', msg.split()[-1])
                    # Note: post-TX yield is set in the NEWSTATE DISC handler,
                    # not here.  PTT FALSE may arrive in a separate TCP read
                    # after NEWSTATE DISC, so setting the timer here would be
                    # a race — the TX loop can wake between the two messages.

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

            # Wait until the channel is confirmed clear before TX.
            # Three checks in order:
            #   1. ardopcf must be in DISC (NEWSTATE DISC or no BUSY TRUE)
            #   2. post-RX hold-off must have expired (we recently received)
            #   3. post-TX yield must have expired (we recently transmitted)
            #   4. TX_SETTLE_DELAY re-check: catches a signal that started
            #      just as DISC was seen, before BUSYDET fires
            while True:
                await self.ardop_idle.wait()

                # Post-RX hold-off: we just received a frame
                remaining = self._post_rx_holdoff_until - time.monotonic()
                if remaining > 0:
                    self.log.debug('Post-RX hold-off: waiting %.1fs', remaining)
                    await asyncio.sleep(remaining)
                    continue

                # Post-TX yield: we just transmitted — give remote a chance
                # to respond before we grab the channel again
                remaining = self._post_tx_yield_until - time.monotonic()
                if remaining > 0:
                    self.log.debug('Post-TX yield: waiting %.1fs', remaining)
                    await asyncio.sleep(remaining)
                    continue

                # Final settle: catches a signal that started just as the
                # holdoffs cleared, before ardopcf transitions to FECRCV.
                # Also re-checks BUSYDET (_channel_busy) for energy that
                # doesn't yet have a NEWSTATE change behind it.
                await asyncio.sleep(TX_SETTLE_DELAY)

                if self.ardop_idle.is_set() and not self._channel_busy:
                    break   # still DISC and no energy detected — safe to TX
                # Channel became busy during settling; loop back and wait.

            self.log.info('ARDOP TX FEC %d bytes', len(payload))

            # Write payload to data port then trigger transmission
            data_writer.write(ardop_data_frame(payload))
            await data_writer.drain()
            await asyncio.sleep(0.10)

            # Trigger transmission
            await self._ardop_cmd_writer(cmd_writer, 'FECSEND TRUE')

            # Mark that WE are transmitting so NEWSTATE DISC knows to set
            # the post-TX yield (not the post-RX holdoff).
            self._transmitting = True
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
        # Open PTT serial port before connecting to ardopcf.
        # pyserial sets DTR=True on open, which is required by CDC-ACM USB
        # devices (IC-705 ttyACM) before they will respond to RTS changes.
        if self.ptt_port:
            if not _HAS_SERIAL:
                self.log.error('--ptt-port requires pyserial: pip install pyserial')
                sys.exit(1)
            try:
                self._ptt_serial = _pyserial.Serial(self.ptt_port, self.ptt_baud)
                self._ptt_serial.rts = False   # PTT off at start
                self.log.info(
                    'PTT serial port %s opened (DTR=%s, RTS=False)',
                    self.ptt_port, self._ptt_serial.dtr,
                )
            except Exception as e:
                self.log.error('Cannot open PTT port %s: %s', self.ptt_port, e)
                sys.exit(1)

        try:
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
        finally:
            if self._ptt_serial is not None:
                try:
                    self._ptt_serial.rts = False
                    self._ptt_serial.close()
                except Exception:
                    pass


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
    parser.add_argument('--ptt-port',    default=None,               help='Serial port for RTS PTT (e.g. /dev/ic_705_b)')
    parser.add_argument('--ptt-baud',    type=int, default=19200,    help='Baud rate for PTT serial port')
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
        'ardop-kiss-bridge starting: ardopcf=%s:%d  KISS port=%d  callsign=%s  fecmode=%s  ptt=%s',
        args.ardop_host, args.ardop_port, args.kiss_port, args.callsign, args.fecmode,
        args.ptt_port or 'none',
    )

    bridge = ArdopKissBridge(
        ardop_host  = args.ardop_host,
        ardop_port  = args.ardop_port,
        kiss_port   = args.kiss_port,
        callsign    = args.callsign,
        fecmode     = args.fecmode,
        fecrepeats  = args.fecrepeats,
        ptt_port    = args.ptt_port,
        ptt_baud    = args.ptt_baud,
        log         = log,
    )

    try:
        asyncio.run(bridge.run())
    except KeyboardInterrupt:
        log.info('Interrupted, shutting down')


if __name__ == '__main__':
    main()
