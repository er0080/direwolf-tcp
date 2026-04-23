/*
 * tests/test_tun_fec.c — unit tests for Phase 6.1a TUN/FEC bridge wiring.
 *
 * Covers the filter logic in TUNDeliverToHost() — the receive-side hand-off
 * from the ARDOP PHY into the kernel TUN interface.  Specifically verifies:
 *
 *   - "FEC"-tagged IPv4/IPv6 payloads are delivered,
 *   - "ARQ"-tagged payloads are also delivered (back-compat during the
 *     Phase 6.1a → 6.1b transition while ARQ state is being removed),
 *   - "ERR" / status-string / truncated / non-IP payloads are dropped.
 *
 * We pipe the g_tun_fd to a pipe under our control and observe what is
 * actually written — so the test exercises the real predicate end-to-end,
 * not a refactored copy.  Runs without hardware (no ALSA, no RF).
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "unity.h"

/* We call into tun_ardopc.c's public entry points: */
void tun_ardopc_init(int tun_fd, const char *fec_mode, int fec_repeats);
void TUNDeliverToHost(unsigned char *data, const char *tag, int len);
void TUNHostPoll(void);

static int pipe_read = -1;
static int pipe_write = -1;

void setUp(void)
{
    int fds[2];
    TEST_ASSERT_EQUAL(0, pipe(fds));
    pipe_read  = fds[0];
    pipe_write = fds[1];
    /* Non-blocking so reads after delivery don't hang. */
    fcntl(pipe_read,  F_SETFL, O_NONBLOCK);
    fcntl(pipe_write, F_SETFL, O_NONBLOCK);
    tun_ardopc_init(pipe_write, "OFDM.2500.55", 0);
}

void tearDown(void)
{
    if (pipe_read  >= 0) close(pipe_read);
    if (pipe_write >= 0) close(pipe_write);
    pipe_read = pipe_write = -1;
}

/* Drain the pipe into buf; returns bytes read (0 if nothing queued). */
static int drain_pipe(unsigned char *buf, int maxlen)
{
    int n = read(pipe_read, buf, maxlen);
    return (n > 0) ? n : 0;
}

/* Build a minimal 20-byte IPv4 header-shaped payload starting with 0x45. */
static void make_ipv4(unsigned char *buf, int total_len)
{
    memset(buf, 0xAA, total_len);
    buf[0] = 0x45;  /* IPv4, IHL=5 */
}

static void make_ipv6(unsigned char *buf, int total_len)
{
    memset(buf, 0xBB, total_len);
    buf[0] = 0x60;  /* IPv6 version=6 */
}

void test_fec_tag_ipv4_is_delivered(void)
{
    unsigned char pkt[60], out[128];
    make_ipv4(pkt, sizeof(pkt));
    TUNDeliverToHost(pkt, "FEC", sizeof(pkt));
    int got = drain_pipe(out, sizeof(out));
    TEST_ASSERT_EQUAL(sizeof(pkt), got);
    TEST_ASSERT_EQUAL_HEX8(0x45, out[0]);
}

void test_fec_tag_ipv6_is_delivered(void)
{
    unsigned char pkt[80], out[128];
    make_ipv6(pkt, sizeof(pkt));
    TUNDeliverToHost(pkt, "FEC", sizeof(pkt));
    int got = drain_pipe(out, sizeof(out));
    TEST_ASSERT_EQUAL(sizeof(pkt), got);
    TEST_ASSERT_EQUAL_HEX8(0x60, out[0]);
}

void test_arq_tag_still_accepted_during_transition(void)
{
    unsigned char pkt[40], out[128];
    make_ipv4(pkt, sizeof(pkt));
    TUNDeliverToHost(pkt, "ARQ", sizeof(pkt));
    int got = drain_pipe(out, sizeof(out));
    TEST_ASSERT_EQUAL(sizeof(pkt), got);
}

void test_err_tag_is_dropped(void)
{
    unsigned char pkt[40], out[128];
    make_ipv4(pkt, sizeof(pkt));
    TUNDeliverToHost(pkt, "ERR", sizeof(pkt));
    int got = drain_pipe(out, sizeof(out));
    TEST_ASSERT_EQUAL(0, got);
}

void test_non_ip_first_byte_is_dropped(void)
{
    unsigned char pkt[40], out[128];
    memset(pkt, 0x00, sizeof(pkt));
    pkt[0] = 0x20;  /* neither 0x4X nor 0x6X */
    TUNDeliverToHost(pkt, "FEC", sizeof(pkt));
    int got = drain_pipe(out, sizeof(out));
    TEST_ASSERT_EQUAL(0, got);
}

void test_short_packet_is_dropped(void)
{
    unsigned char pkt[19], out[128];
    make_ipv4(pkt, sizeof(pkt));
    TUNDeliverToHost(pkt, "FEC", sizeof(pkt));
    int got = drain_pipe(out, sizeof(out));
    TEST_ASSERT_EQUAL(0, got);
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_fec_tag_ipv4_is_delivered);
    RUN_TEST(test_fec_tag_ipv6_is_delivered);
    RUN_TEST(test_arq_tag_still_accepted_during_transition);
    RUN_TEST(test_err_tag_is_dropped);
    RUN_TEST(test_non_ip_first_byte_is_dropped);
    RUN_TEST(test_short_packet_is_dropped);
    return UNITY_END();
}
