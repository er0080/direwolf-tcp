#ifndef CIV_CONTROL_H
#define CIV_CONTROL_H

#include <stdint.h>

/*
 * civ_control — Icom CI-V radio control for ardop-ip
 *
 * Provides PTT keying, frequency, and mode control via the Icom CI-V
 * serial bus.  Replaces the RTS/DTR PTT path used by the original ardopc.
 *
 * CI-V frame format: FE FE [radio_addr] [ctrl=0xE0] [cmd] [data...] FD
 *
 * Requires: LinSerial.c (OpenCOMPort / WriteCOMBlock / ReadCOMBlock)
 */

/* Open the CI-V serial port.
 * @port  — device path (e.g. "/dev/ttyUSB0")
 * @baud  — baud rate (typically 19200 for IC-705/7300)
 * Returns file descriptor, or -1 on error. */
int civ_open(const char *port, int baud);

/* Key or un-key the transmitter.
 * @fd         — file descriptor from civ_open()
 * @radio_addr — CI-V address (0xA4 = IC-705, 0x94 = IC-7300)
 * @on         — non-zero to key TX, zero to un-key */
void civ_ptt(int fd, uint8_t radio_addr, int on);

/* Set VFO frequency in Hz.  BCD-encoded per CI-V spec (cmd 0x05). */
void civ_set_freq(int fd, uint8_t radio_addr, uint32_t hz);

/* Set operating mode (cmd 0x06).
 * Common values: 0x01=LSB, 0x02=USB, 0x03=AM, 0x04=FM, 0x05=CW */
void civ_set_mode(int fd, uint8_t radio_addr, uint8_t mode);

/* Non-blocking poll for a CI-V response frame.
 * Returns number of bytes written to @resp, 0 if none available,
 * or -ETIMEDOUT after 500 ms with no data. */
int civ_poll(int fd, uint8_t *resp, int maxlen);

#endif /* CIV_CONTROL_H */
