/*
 * tun_interface.c — Linux TUN device management for ardop-ip
 *
 * Phase 1: skeleton implementation — symbols are defined so the build
 * links cleanly.  Full implementation is added in Phase 2 when the TUN
 * fd is wired into the ARDOPC.c event loop.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <net/if.h>
#include <linux/if_tun.h>
#include <sys/ioctl.h>

#include "tun_interface.h"

int tun_open(const char *ifname)
{
    struct ifreq ifr;
    int fd;

    fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        perror("tun_open: open /dev/net/tun");
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    if (ifname && *ifname)
        strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        perror("tun_open: TUNSETIFF");
        close(fd);
        return -1;
    }

    return fd;
}

void tun_configure(int fd, const char *ifname,
                   const char *local, const char *peer, int mtu)
{
    char cmd[256];
    (void)fd;   /* ip(8) uses the interface name, not the fd */

    snprintf(cmd, sizeof(cmd),
             "ip link set %s up mtu %d", ifname, mtu);
    if (system(cmd) != 0) {
        fprintf(stderr, "tun_configure: '%s' failed\n", cmd);
        return;
    }

    snprintf(cmd, sizeof(cmd),
             "ip addr add %s peer %s dev %s", local, peer, ifname);
    if (system(cmd) != 0) {
        fprintf(stderr, "tun_configure: '%s' failed\n", cmd);
    }
}

int tun_read(int fd, uint8_t *buf, int maxlen)
{
    int n = read(fd, buf, maxlen);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
        return 0;
    return n;
}

void tun_write(int fd, const uint8_t *pkt, int len)
{
    ssize_t n = write(fd, pkt, len);
    if (n < 0)
        perror("tun_write");
}
