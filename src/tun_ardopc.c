/*
 * tun_ardopc.c — bridges the ardopc ARQ core to a Linux TUN interface
 *
 * Provides three entry points consumed in ARDOP_IP builds:
 *
 *   tun_ardopc_init()  — called from main() before ardopmain()
 *   TUNHostPoll()      — called each event-loop tick instead of TCPHostPoll
 *   TUNDeliverToHost() — called by HostInterface.c when ARQ delivers a frame
 */

#include <poll.h>
#include <stdint.h>
#include <string.h>

#include "ARDOPC.h"
#include "tun_interface.h"

static int  g_tun_fd         = -1;
static int  g_iss            = 0;
static char g_mycall[10]     = "";
static char g_peer[10]       = "";
static int  g_conn_triggered = 0;

/*
 * Initialise the TUN/ARQ bridge.
 * @tun_fd    — file descriptor returned by tun_open()
 * @iss       — non-zero if this instance should initiate the ARQ connect
 * @mycall    — local callsign (already copied into Callsign[] by main)
 * @peer      — target callsign for ISS connect request
 */
void tun_ardopc_init(int tun_fd, int iss, const char *mycall, const char *peer)
{
    g_tun_fd = tun_fd;
    g_iss    = iss;
    if (mycall) strncpy(g_mycall, mycall, sizeof(g_mycall) - 1);
    if (peer)   strncpy(g_peer,   peer,   sizeof(g_peer)   - 1);
}

/*
 * Called by HostInterface.c::AddTagToDataAndSendToHost() in ARDOP_IP builds.
 *
 * Forwards ARQ-delivered data to the TUN interface if the content looks like
 * a valid IP packet (IPv4 or IPv6 version nibble, minimum 20 bytes).
 * Status strings sent with the "ARQ" tag (e.g. "[ConReq2500 > KD2MYS]") are
 * silently discarded — they start with a space, not an IP version byte.
 */
void TUNDeliverToHost(UCHAR *data, const char *tag, int len)
{
    if (g_tun_fd < 0 || len < 20)
        return;
    if (strcmp(tag, "ARQ") != 0)
        return;
    if ((data[0] & 0xF0) != 0x40 && (data[0] & 0xF0) != 0x60)
        return;
    tun_write(g_tun_fd, data, len);
}

/*
 * Replaces TCPHostPoll()/SerialHostPoll() in the ardopmain() event loop.
 *
 * On the first call in ISS mode, fires SendARQConnectRequest() — audio is
 * already initialised by this point (InitSound() runs before the loop).
 * On subsequent calls, reads one IP packet from TUN into the ARQ TX queue.
 */
void TUNHostPoll(void)
{
    /* ISS: fire the connect request exactly once */
    if (g_iss && !g_conn_triggered)
    {
        g_conn_triggered = 1;
        SendARQConnectRequest(g_mycall, g_peer);
        return;
    }

    if (g_tun_fd < 0 || bytDataToSendLength > 0)
        return;

    struct pollfd pfd = { .fd = g_tun_fd, .events = POLLIN };
    if (poll(&pfd, 1, 0) <= 0)
        return;

    int len = tun_read(g_tun_fd, bytDataToSend, DATABUFFERSIZE);
    if (len > 0)
        bytDataToSendLength = len;
}
