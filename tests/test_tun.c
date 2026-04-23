/*
 * tests/test_tun.c — unit tests for src/tun_interface.c
 *
 * Must run as root (CAP_NET_ADMIN required).
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include <sys/ioctl.h>

#include "unity.h"
#include "../src/tun_interface.h"

#define TEST_IF   "ardop_test0"
#define TEST_MTU  1460
#define LOCAL_IP  "10.99.0.1"
#define PEER_IP   "10.99.0.2"

/* ── Helpers ─────────────────────────────────────────────────────────────── */

static void cleanup_iface(void)
{
    system("ip link del " TEST_IF " 2>/dev/null");
}

static int iface_exists(void)
{
    return system("ip link show " TEST_IF " >/dev/null 2>&1") == 0;
}

static int get_kernel_mtu(void)
{
    FILE *fp = popen(
        "ip link show " TEST_IF " 2>/dev/null | grep -oP '(?<=mtu )\\d+'", "r");
    if (!fp) return -1;
    int mtu = -1;
    fscanf(fp, "%d", &mtu);
    pclose(fp);
    return mtu;
}

static int addr_assigned(void)
{
    return system("ip addr show " TEST_IF
                  " 2>/dev/null | grep -q " LOCAL_IP) == 0;
}

/* Internet checksum (RFC 1071) */
static uint16_t inet_cksum(const void *data, int len)
{
    const uint16_t *p = data;
    uint32_t sum = 0;
    while (len > 1) { sum += *p++; len -= 2; }
    if (len) sum += *(const uint8_t *)p;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)~sum;
}

/*
 * Build a minimal ICMP echo request with correct IP + ICMP checksums.
 * src = PEER_IP, dst = LOCAL_IP so the kernel (which owns LOCAL_IP)
 * generates an ICMP echo reply routed back out the TUN fd.
 */
static int build_icmp_request(uint8_t *buf, int buflen)
{
    const int total = 56;   /* 20 IP + 8 ICMP + 28 payload */
    if (buflen < total) return -1;
    memset(buf, 0, total);

    /* IPv4 header */
    buf[0]  = 0x45;             /* version=4, IHL=5 */
    buf[2]  = 0; buf[3] = total;
    buf[5]  = 0x01;             /* id */
    buf[8]  = 64;               /* TTL */
    buf[9]  = 0x01;             /* protocol: ICMP */
    /* src = 10.99.0.2 (PEER), dst = 10.99.0.1 (LOCAL) */
    buf[12] = 10; buf[13] = 99; buf[14] = 0; buf[15] = 2;
    buf[16] = 10; buf[17] = 99; buf[18] = 0; buf[19] = 1;
    /* IP checksum over 20-byte header */
    *(uint16_t *)(buf + 10) = inet_cksum(buf, 20);

    /* ICMP echo request at offset 20 */
    buf[20] = 0x08;             /* type: echo request */
    buf[21] = 0x00;             /* code */
    buf[22] = 0; buf[23] = 0;  /* checksum placeholder */
    buf[24] = 0; buf[25] = 0x01; /* identifier */
    buf[26] = 0; buf[27] = 0x01; /* sequence */
    /* 28 bytes of payload already zero */
    *(uint16_t *)(buf + 22) = inet_cksum(buf + 20, total - 20);

    return total;
}

/* ── setUp / tearDown ────────────────────────────────────────────────────── */

void setUp(void)    { cleanup_iface(); }
void tearDown(void) { cleanup_iface(); }

/* ── Tests ───────────────────────────────────────────────────────────────── */

void test_tun_open_close(void)
{
    int fd = tun_open(TEST_IF);
    TEST_ASSERT_MESSAGE(fd >= 0, "tun_open returned negative fd");
    TEST_ASSERT_MESSAGE(iface_exists(),
                        "interface not visible in ip link show after tun_open");

    close(fd);
    usleep(50000);  /* 50 ms: kernel interface teardown is async */
    TEST_ASSERT_MESSAGE(!iface_exists(),
                        "interface still present after close()");
}

void test_tun_mtu(void)
{
    int fd = tun_open(TEST_IF);
    TEST_ASSERT(fd >= 0);

    tun_configure(fd, TEST_IF, LOCAL_IP, PEER_IP, TEST_MTU);

    int mtu = get_kernel_mtu();
    TEST_ASSERT_EQUAL_INT_MESSAGE(TEST_MTU, mtu,
                                  "kernel MTU does not match configured value");
    close(fd);
}

void test_tun_loopback_write_read(void)
{
    /*
     * Inject an ICMP echo request addressed to LOCAL_IP (which the kernel
     * owns).  The kernel generates an ICMP echo reply, routes it out via
     * ardop_test0 (the only path to the requester PEER_IP), and we read it
     * back from the same fd.
     */
    int fd = tun_open(TEST_IF);
    TEST_ASSERT(fd >= 0);
    tun_configure(fd, TEST_IF, LOCAL_IP, PEER_IP, TEST_MTU);

    uint8_t req[64];
    int req_len = build_icmp_request(req, sizeof(req));
    TEST_ASSERT_MESSAGE(req_len > 0, "failed to build ICMP request");

    tun_write(fd, req, req_len);

    /* Poll for the ICMP echo reply (type=0), filtering out any stray packets */
    uint8_t buf[2048];
    int got_reply = 0;
    for (int retry = 0; retry < 50 && !got_reply; retry++) {
        usleep(10000);  /* 10 ms per retry, up to 500 ms total */
        int n = tun_read(fd, buf, sizeof(buf));
        if (n < 20) continue;
        /* Accept only IPv4 (version=4) ICMP (proto=1) echo reply (type=0) */
        if ((buf[0] >> 4) == 4 && buf[9] == 1 && buf[20] == 0)
            got_reply = 1;
    }

    TEST_ASSERT_MESSAGE(got_reply, "no ICMP echo reply received within 500 ms");
    /* Verify src IP of reply is LOCAL_IP (10.99.0.1) */
    TEST_ASSERT_EQUAL_INT_MESSAGE(10,  buf[12], "reply src IP octet 1 wrong");
    TEST_ASSERT_EQUAL_INT_MESSAGE(99,  buf[13], "reply src IP octet 2 wrong");
    TEST_ASSERT_EQUAL_INT_MESSAGE(0,   buf[14], "reply src IP octet 3 wrong");
    TEST_ASSERT_EQUAL_INT_MESSAGE(1,   buf[15], "reply src IP octet 4 wrong");

    close(fd);
}

void test_tun_oversized_drop(void)
{
    int fd = tun_open(TEST_IF);
    TEST_ASSERT(fd >= 0);
    tun_configure(fd, TEST_IF, LOCAL_IP, PEER_IP, TEST_MTU);

    uint8_t oversized[TEST_MTU + 100];
    memset(oversized, 0, sizeof(oversized));
    oversized[0] = 0x45;    /* minimal IPv4 header marker */

    /* Drain any queued kernel packets (e.g. spontaneous ICMPv6 before
     * IPv6 was disabled) so the fd is empty before we do the test. */
    uint8_t drain[4096];
    usleep(50000);  /* 50 ms: give kernel time to flush queued packets */
    while (tun_read(fd, drain, sizeof(drain)) > 0)
        ;

    /* tun_write() must silently drop packets exceeding the configured MTU */
    tun_write(fd, oversized, sizeof(oversized));

    usleep(10000);  /* 10 ms: verify nothing appears */
    uint8_t buf[4096];
    int n = tun_read(fd, buf, sizeof(buf));
    TEST_ASSERT_EQUAL_INT_MESSAGE(0, n,
                                  "oversized packet was not dropped by tun_write");

    close(fd);
}

void test_tun_addr_config(void)
{
    int fd = tun_open(TEST_IF);
    TEST_ASSERT(fd >= 0);

    tun_configure(fd, TEST_IF, LOCAL_IP, PEER_IP, TEST_MTU);

    TEST_ASSERT_MESSAGE(addr_assigned(),
                        LOCAL_IP " not assigned after tun_configure");

    close(fd);
}

/* ── Main ────────────────────────────────────────────────────────────────── */

int main(void)
{
    if (geteuid() != 0) {
        fprintf(stderr, "test_tun: must run as root (needs CAP_NET_ADMIN)\n");
        return 1;
    }

    UNITY_BEGIN();
    RUN_TEST(test_tun_open_close);
    RUN_TEST(test_tun_mtu);
    RUN_TEST(test_tun_loopback_write_read);
    RUN_TEST(test_tun_oversized_drop);
    RUN_TEST(test_tun_addr_config);
    return UNITY_END();
}
