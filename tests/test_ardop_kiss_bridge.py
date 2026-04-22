#!/usr/bin/env python3
"""Unit tests for ardop-kiss-bridge.py protocol helpers."""

import struct
import sys
import os
import unittest

# Allow importing from scripts/
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))
from ardop_kiss_bridge import (
    FEND, FESC, TFEND, TFESC,
    kiss_escape, kiss_unescape,
    parse_kiss_frames, make_kiss_frame,
    ardop_data_frame, parse_ardop_data_frames,
)


class TestKissEscaping(unittest.TestCase):

    def test_escape_plain(self):
        self.assertEqual(kiss_escape(b'\x01\x02\x03'), b'\x01\x02\x03')

    def test_escape_fend(self):
        self.assertEqual(kiss_escape(bytes([FEND])), bytes([FESC, TFEND]))

    def test_escape_fesc(self):
        self.assertEqual(kiss_escape(bytes([FESC])), bytes([FESC, TFESC]))

    def test_escape_mixed(self):
        data = bytes([0x01, FEND, FESC, 0x02])
        escaped = kiss_escape(data)
        self.assertEqual(escaped, bytes([0x01, FESC, TFEND, FESC, TFESC, 0x02]))

    def test_roundtrip(self):
        for payload in [b'', b'hello', bytes(range(256)), bytes([FEND, FESC, FEND])]:
            self.assertEqual(kiss_unescape(kiss_escape(payload)), payload)

    def test_unescape_plain(self):
        self.assertEqual(kiss_unescape(b'hello'), b'hello')

    def test_unescape_fend(self):
        self.assertEqual(kiss_unescape(bytes([FESC, TFEND])), bytes([FEND]))

    def test_unescape_fesc(self):
        self.assertEqual(kiss_unescape(bytes([FESC, TFESC])), bytes([FESC]))


class TestKissFrameParsing(unittest.TestCase):

    def test_single_data_frame(self):
        payload = b'\x01\x02\x03'
        buf = bytearray(make_kiss_frame(payload))
        frames = parse_kiss_frames(buf)
        self.assertEqual(len(frames), 1)
        type_byte, parsed = frames[0]
        self.assertEqual(type_byte, 0x00)
        self.assertEqual(parsed, payload)
        self.assertEqual(len(buf), 0)  # buf fully consumed

    def test_multiple_frames(self):
        p1 = b'frame1'
        p2 = b'frame2'
        buf = bytearray(make_kiss_frame(p1) + make_kiss_frame(p2))
        frames = parse_kiss_frames(buf)
        self.assertEqual(len(frames), 2)
        self.assertEqual(frames[0][1], p1)
        self.assertEqual(frames[1][1], p2)

    def test_incomplete_frame_stays_in_buf(self):
        payload = b'incomplete'
        # Build a frame but strip the closing FEND
        full = make_kiss_frame(payload)
        buf = bytearray(full[:-1])   # missing trailing FEND
        frames = parse_kiss_frames(buf)
        self.assertEqual(frames, [])
        # The partial content should remain
        self.assertGreater(len(buf), 0)

    def test_empty_payload(self):
        buf = bytearray(make_kiss_frame(b''))
        frames = parse_kiss_frames(buf)
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0][1], b'')

    def test_fend_in_payload_roundtrip(self):
        payload = bytes([FEND, FESC, 0x42, FEND])
        buf = bytearray(make_kiss_frame(payload))
        frames = parse_kiss_frames(buf)
        self.assertEqual(frames[0][1], payload)

    def test_consecutive_fends_ignored(self):
        # Two consecutive FENDs between frames should not produce empty frames
        payload = b'data'
        frame = make_kiss_frame(payload)
        # Insert extra FEND padding
        buf = bytearray(bytes([FEND, FEND]) + frame + bytes([FEND]))
        frames = parse_kiss_frames(buf)
        data_frames = [f for f in frames if len(f[1]) > 0]
        self.assertEqual(len(data_frames), 1)
        self.assertEqual(data_frames[0][1], payload)


class TestArdopDataFraming(unittest.TestCase):

    def test_tx_frame_format(self):
        payload = b'\xAA\xBB\xCC'
        frame = ardop_data_frame(payload)
        # First two bytes: big-endian length of payload
        length = struct.unpack('>H', frame[:2])[0]
        self.assertEqual(length, len(payload))
        self.assertEqual(frame[2:], payload)

    def test_rx_frame_parsing_fec(self):
        payload = b'hello world'
        tag = b'FEC'
        size = len(tag) + len(payload)
        raw = struct.pack('>H', size) + tag + payload
        buf = bytearray(raw)
        frames = parse_ardop_data_frames(buf)
        self.assertEqual(len(frames), 1)
        parsed_tag, parsed_payload = frames[0]
        self.assertEqual(parsed_tag, b'FEC')
        self.assertEqual(parsed_payload, payload)
        self.assertEqual(len(buf), 0)

    def test_rx_frame_parsing_arq(self):
        payload = b'\x00\x01\x02'
        tag = b'ARQ'
        size = len(tag) + len(payload)
        raw = struct.pack('>H', size) + tag + payload
        buf = bytearray(raw)
        frames = parse_ardop_data_frames(buf)
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0][0], b'ARQ')
        self.assertEqual(frames[0][1], payload)

    def test_rx_multiple_frames(self):
        frames_in = [(b'FEC', b'frame1data'), (b'FEC', b'frame2data')]
        raw = bytearray()
        for tag, payload in frames_in:
            size = len(tag) + len(payload)
            raw += struct.pack('>H', size) + tag + payload
        buf = bytearray(raw)
        frames_out = parse_ardop_data_frames(buf)
        self.assertEqual(len(frames_out), 2)
        for i, (tag, payload) in enumerate(frames_in):
            self.assertEqual(frames_out[i][0], tag)
            self.assertEqual(frames_out[i][1], payload)

    def test_rx_incomplete_frame_stays(self):
        payload = b'incomplete'
        tag = b'FEC'
        size = len(tag) + len(payload)
        # Full frame data but cut off early
        raw = struct.pack('>H', size) + tag + payload[:5]
        buf = bytearray(raw)
        frames = parse_ardop_data_frames(buf)
        self.assertEqual(frames, [])
        self.assertGreater(len(buf), 0)

    def test_empty_payload(self):
        payload = b''
        tag = b'FEC'
        size = len(tag)
        raw = struct.pack('>H', size) + tag
        buf = bytearray(raw)
        frames = parse_ardop_data_frames(buf)
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0][1], b'')

    def test_tx_large_payload(self):
        payload = bytes(range(256)) * 4   # 1024 bytes
        frame = ardop_data_frame(payload)
        length = struct.unpack('>H', frame[:2])[0]
        self.assertEqual(length, 1024)
        self.assertEqual(frame[2:], payload)


class TestMakeKissFrame(unittest.TestCase):

    def test_structure(self):
        payload = b'\x01\x02'
        frame = make_kiss_frame(payload)
        self.assertEqual(frame[0], FEND)
        self.assertEqual(frame[-1], FEND)
        self.assertEqual(frame[1], 0x00)   # type byte for channel 0

    def test_channel(self):
        frame = make_kiss_frame(b'x', channel=1)
        self.assertEqual(frame[1], 0x01)

    def test_payload_is_escaped(self):
        payload = bytes([FEND])
        frame = make_kiss_frame(payload)
        # The FEND in the payload should be escaped
        inner = frame[2:-1]   # strip FEND + type_byte + trailing FEND
        self.assertEqual(inner, bytes([FESC, TFEND]))


if __name__ == '__main__':
    unittest.main(verbosity=2)
