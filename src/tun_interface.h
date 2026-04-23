#ifndef TUN_INTERFACE_H
#define TUN_INTERFACE_H

#include <stdint.h>

/*
 * tun_interface — Linux TUN device for ardop-ip
 *
 * Creates and manages the /dev/net/tun device that replaces the host
 * serial/TCP protocol used by the original ardopc.  IP packets from the
 * kernel are handed directly to the ARQ TX queue; received frames from
 * the radio are written back to the kernel via tun_write().
 *
 * Requires CAP_NET_ADMIN (run as root or setcap).
 */

/* Open (or create) a TUN interface named @ifname.
 * Returns the open file descriptor, or -1 on error (errno set). */
int tun_open(const char *ifname);

/* Configure @ifname with /30 point-to-point addresses and @mtu.
 * @local  — address assigned to this end  (e.g. "10.0.0.1")
 * @peer   — address of the remote end     (e.g. "10.0.0.2")
 * @mtu    — maximum IP packet size the radio layer can carry
 * Calls ip(8) via system(); dies with perror on failure. */
void tun_configure(int fd, const char *ifname,
                   const char *local, const char *peer, int mtu);

/* Read one IP packet from the TUN fd into @buf (max @maxlen bytes).
 * Returns number of bytes read, 0 if no packet available (non-blocking),
 * or -1 on error. */
int tun_read(int fd, uint8_t *buf, int maxlen);

/* Write an IP packet @pkt of @len bytes to the TUN fd.
 * Silently drops packets larger than the interface MTU. */
void tun_write(int fd, const uint8_t *pkt, int len);

#endif /* TUN_INTERFACE_H */
