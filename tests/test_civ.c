/*
 * tests/test_civ.c — unit tests for src/civ_control.c
 *
 * Uses openpty() to create a pseudo-terminal pair so CI-V frames can
 * be inspected without any radio hardware.  The "master" fd simulates
 * the radio's serial port; the "slave" fd is passed to civ_open().
 *
 * No sudo required.
 */

#include <errno.h>
#include <fcntl.h>
#include <pty.h>        /* openpty() — link with -lutil */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
#include <time.h>

#include "unity.h"
#include "../src/civ_control.h"

/* Preamble bytes used in every CI-V frame */
#define FE 0xFE
#define FD 0xFD
#define E0 0xE0     /* controller address */

static int master_fd = -1;
static int slave_fd  = -1;
static char slave_dev[64];

/* ── setUp / tearDown ────────────────────────────────────────────────────── */

void setUp(void)
{
    char slave_path[64];
    if (openpty(&master_fd, &slave_fd, slave_path, NULL, NULL) < 0) {
        perror("openpty");
        TEST_ABORT();
    }
    strncpy(slave_dev, slave_path, sizeof(slave_dev) - 1);

    /* Make master non-blocking for reads */
    int flags = fcntl(master_fd, F_GETFL, 0);
    fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);
}

void tearDown(void)
{
    if (master_fd >= 0) { close(master_fd); master_fd = -1; }
    if (slave_fd  >= 0) { close(slave_fd);  slave_fd  = -1; }
}

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/* Read up to maxlen bytes from master_fd; return count.
 * Retries for up to 200 ms to allow the slave write to propagate. */
static int read_from_radio(uint8_t *buf, int maxlen)
{
    int total = 0;
    for (int retry = 0; retry < 20 && total < maxlen; retry++) {
        int n = read(master_fd, buf + total, maxlen - total);
        if (n > 0) total += n;
        if (total > 0) {
            /* Check if we have a complete frame (ends with FD) */
            if (buf[total - 1] == FD) break;
        }
        usleep(10000);  /* 10 ms */
    }
    return total;
}

/* Open the slave pty as a CI-V port (no real serial baud needed) */
static int open_slave_as_civ(void)
{
    /* civ_open() calls OpenCOMPort() which wraps open() + tcsetattr().
     * Pass baud=9600; pty ignores it but the call must succeed. */
    return civ_open(slave_dev, 9600);
}

/* ── Tests ───────────────────────────────────────────────────────────────── */

void test_civ_ptt_frame_on(void)
{
    int civ_fd = open_slave_as_civ();
    TEST_ASSERT_MESSAGE(civ_fd >= 0, "civ_open failed");

    civ_ptt(civ_fd, 0xA4, 1);
    usleep(10000);

    uint8_t buf[16];
    int n = read_from_radio(buf, sizeof(buf));

    const uint8_t expected[] = { FE, FE, 0xA4, E0, 0x1C, 0x00, 0x01, FD };
    TEST_ASSERT_EQUAL_INT_MESSAGE(sizeof(expected), n,
                                  "PTT-on frame length wrong");
    TEST_ASSERT_EQUAL_MEMORY_MESSAGE(expected, buf, sizeof(expected),
                                     "PTT-on frame bytes wrong");
    close(civ_fd);
}

void test_civ_ptt_frame_off(void)
{
    int civ_fd = open_slave_as_civ();
    TEST_ASSERT_MESSAGE(civ_fd >= 0, "civ_open failed");

    civ_ptt(civ_fd, 0xA4, 0);
    usleep(10000);

    uint8_t buf[16];
    int n = read_from_radio(buf, sizeof(buf));

    const uint8_t expected[] = { FE, FE, 0xA4, E0, 0x1C, 0x00, 0x00, FD };
    TEST_ASSERT_EQUAL_INT_MESSAGE(sizeof(expected), n,
                                  "PTT-off frame length wrong");
    TEST_ASSERT_EQUAL_MEMORY_MESSAGE(expected, buf, sizeof(expected),
                                     "PTT-off frame bytes wrong");
    close(civ_fd);
}

void test_civ_freq_bcd(void)
{
    /*
     * 14.074 MHz = 14074000 Hz
     * BCD-encoded LS-pair first in 5 bytes:
     *   14074000 → 00 40 07 41 00  (pairs: 00, 40, 07, 41, 00)
     *
     * Manual calculation:
     *   14074000 ÷  1 = pair 0: 00 (digits 0,0)
     *   14074000 ÷100 =  140740  pair 1: 00→wait
     *
     * Let's work it out digit by digit:
     *   14074000 in decimal: 1 4 0 7 4 0 0 0  (8 digits, padded to 10 = 0014074000)
     *   BCD pairs LS first: 00, 00, 07, 40, 01
     *   byte0 = (0 << 4) | 0 = 0x00
     *   byte1 = (0 << 4) | 0 = 0x00
     *   byte2 = (7 << 4) | 0 = 0x70  ← wait
     *
     * Correct: each BCD byte = (tens_digit << 4) | units_digit, starting from Hz units
     *   14074000 Hz:
     *   digit pairs from right: 00, 00, 07, 40, 01  → wait:
     *   14074000 → 0 1 4 0 7 4 0 0 0 0 (10 digits)
     *   pair 0 (Hz 1s & 10s): 00 → 0x00
     *   pair 1 (Hz 100s & 1000s): 00 → 0x00
     *   pair 2 (kHz 1s & 10s): 74 → 0x74
     *   pair 3 (kHz 100s & MHz 1s): 40 → 0x40  (4 at 100kHz, 0 at 1MHz)
     *   pair 4 (MHz 10s): 01 → 0x01  (0 at 10MHz, 1 at 10MHz)
     *
     * Final BCD bytes: 0x00, 0x00, 0x74, 0x40, 0x01
     *
     * Frame: FE FE A4 E0 05 00 00 74 40 01 FD
     */
    int civ_fd = open_slave_as_civ();
    TEST_ASSERT_MESSAGE(civ_fd >= 0, "civ_open failed");

    civ_set_freq(civ_fd, 0xA4, 14074000);
    usleep(10000);

    uint8_t buf[16];
    int n = read_from_radio(buf, sizeof(buf));

    /*
     * 14074000 Hz BCD (LS pair first, each byte = tens<<4 | units):
     *   pos 1-2  (Hz 1s/10s):     00 → 0x00
     *   pos 3-4  (Hz 100s/kHz 1): 04 → 0x40  (4 in tens nibble)
     *   pos 5-6  (kHz 10/100):    07 → 0x07  (7 in units nibble)
     *   pos 7-8  (MHz 1/10):      14 → 0x14  (1 in tens nibble, 4 units)
     *   pos 9-10 (MHz 100+):      00 → 0x00
     */
    const uint8_t expected[] = {
        FE, FE, 0xA4, E0, 0x05,
        0x00, 0x40, 0x07, 0x14, 0x00,
        FD
    };
    TEST_ASSERT_EQUAL_INT_MESSAGE(sizeof(expected), n,
                                  "freq frame length wrong");
    TEST_ASSERT_EQUAL_MEMORY_MESSAGE(expected, buf, sizeof(expected),
                                     "freq BCD encoding wrong");
    close(civ_fd);
}

void test_civ_addr_variants(void)
{
    /* IC-705 (0xA4) */
    {
        int fd = open_slave_as_civ();
        TEST_ASSERT(fd >= 0);
        civ_ptt(fd, 0xA4, 1);
        usleep(10000);
        uint8_t buf[16];
        int n = read_from_radio(buf, sizeof(buf));
        TEST_ASSERT(n >= 4);
        TEST_ASSERT_EQUAL_HEX8_MESSAGE(0xA4, buf[2], "IC-705 addr wrong");
        close(fd);
    }

    /* Need fresh pty for each sub-test */
    tearDown(); setUp();

    /* IC-7300 (0x94) */
    {
        int fd = open_slave_as_civ();
        TEST_ASSERT(fd >= 0);
        civ_ptt(fd, 0x94, 1);
        usleep(10000);
        uint8_t buf[16];
        int n = read_from_radio(buf, sizeof(buf));
        TEST_ASSERT(n >= 4);
        TEST_ASSERT_EQUAL_HEX8_MESSAGE(0x94, buf[2], "IC-7300 addr wrong");
        close(fd);
    }

    tearDown(); setUp();

    /* Arbitrary address (0x70) */
    {
        int fd = open_slave_as_civ();
        TEST_ASSERT(fd >= 0);
        civ_ptt(fd, 0x70, 0);
        usleep(10000);
        uint8_t buf[16];
        int n = read_from_radio(buf, sizeof(buf));
        TEST_ASSERT(n >= 4);
        TEST_ASSERT_EQUAL_HEX8_MESSAGE(0x70, buf[2], "arbitrary addr wrong");
        close(fd);
    }
}

void test_civ_timeout(void)
{
    /*
     * Write nothing to master_fd (simulating a radio that never responds).
     * civ_poll() should return -ETIMEDOUT after ~500 ms.
     */
    int civ_fd = open_slave_as_civ();
    TEST_ASSERT_MESSAGE(civ_fd >= 0, "civ_open failed");

    uint8_t resp[32];
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    int n = civ_poll(civ_fd, resp, sizeof(resp));

    clock_gettime(CLOCK_MONOTONIC, &t1);
    long elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000
                    + (t1.tv_nsec - t0.tv_nsec) / 1000000;

    TEST_ASSERT_EQUAL_INT_MESSAGE(-ETIMEDOUT, n,
                                  "civ_poll did not return -ETIMEDOUT");
    TEST_ASSERT_MESSAGE(elapsed_ms >= 450 && elapsed_ms <= 2000,
                        "civ_poll timeout outside expected 450-2000 ms window");

    close(civ_fd);
}

/* ── Main ────────────────────────────────────────────────────────────────── */

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_civ_ptt_frame_on);
    RUN_TEST(test_civ_ptt_frame_off);
    RUN_TEST(test_civ_freq_bcd);
    RUN_TEST(test_civ_addr_variants);
    RUN_TEST(test_civ_timeout);
    return UNITY_END();
}
