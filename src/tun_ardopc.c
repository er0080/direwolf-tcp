/*
 * tun_ardopc.c — bridges the TUN interface to the ardopc FEC datagram core.
 *
 * Provides three entry points consumed in ARDOP_IP builds:
 *
 *   tun_ardopc_init()  — called from main() before ardopmain()
 *   TUNHostPoll()      — called each event-loop tick instead of TCPHostPoll
 *   TUNDeliverToHost() — called by HostInterface.c when the PHY delivers a frame
 *
 * Phase 6.1: ARQ has been excised.  ardop-ip now runs in pure FEC mode —
 * every packet the kernel sends via TUN is handed to StartFEC() which
 * encodes it with strong Reed-Solomon FEC and transmits it once.  There is
 * no ISS/IRS role, no ConReq/BREAK/IDLE state dance, and no peer callsign.
 * TCP above the link handles retransmit for us; UDP either delivers or is
 * lost (matching TCP/IP norms).
 */

#include <poll.h>
#include <stdint.h>
#include <string.h>

#include "ARDOPC.h"
#include "tun_interface.h"

static int  g_tun_fd = -1;
static char g_fec_mode[16] = "OFDM.2500.55";   /* default; set by init() */

/* ProtocolState/ProtocolMode are declared in ARDOPC.h. */

/*
 * Initialise the TUN/FEC bridge.
 * @tun_fd    — file descriptor returned by tun_open()
 * @fec_mode  — ARDOP FEC mode string (e.g. "OFDM.2500.55", "OFDM.500.55");
 *              must be one of the entries in strAllDataModes[]
 */
void tun_ardopc_init(int tun_fd, const char *fec_mode)
{
    g_tun_fd = tun_fd;
    if (fec_mode && *fec_mode) {
        strncpy(g_fec_mode, fec_mode, sizeof(g_fec_mode) - 1);
        g_fec_mode[sizeof(g_fec_mode) - 1] = '\0';
    }
    ProtocolMode = FEC;
}

/*
 * Called by HostInterface.c::AddTagToDataAndSendToHost() in ARDOP_IP builds.
 *
 * Forwards PHY-delivered data to the TUN interface if the content looks
 * like a valid IP packet (IPv4 or IPv6 version nibble, minimum 20 bytes).
 * We accept both "FEC" and "ARQ" tags — the latter survives during the
 * Phase 6.1a/b transition while the ARQ path is still linked in but
 * unused.  "ERR" (failed decode) and status strings are dropped.
 */
void TUNDeliverToHost(UCHAR *data, const char *tag, int len)
{
    if (g_tun_fd < 0 || len < 20)
        return;
    if (strcmp(tag, "FEC") != 0 && strcmp(tag, "ARQ") != 0)
        return;
    if ((data[0] & 0xF0) != 0x40 && (data[0] & 0xF0) != 0x60)
        return;
    tun_write(g_tun_fd, data, len);
}

/*
 * Replaces TCPHostPoll()/SerialHostPoll() in the ardopmain() event loop.
 *
 * Reads at most one IP packet from TUN per call, and hands it to
 * StartFEC() for transmission.  Skips when the PHY is already transmitting
 * or receiving so we don't clobber an in-flight frame.
 */
void TUNHostPoll(void)
{
    if (g_tun_fd < 0)
        return;

    /* Don't pull more data while we're mid-transmission or mid-receive:
     * - FECSend with a non-empty buffer: previous frame still being emitted.
     * - FECRcv: the PHY is decoding; cutting it off with a TX would corrupt
     *   the in-flight receive. */
    if (ProtocolState == FECSend && bytDataToSendLength > 0)
        return;
    if (ProtocolState == FECRcv)
        return;

    struct pollfd pfd = { .fd = g_tun_fd, .events = POLLIN };
    if (poll(&pfd, 1, 0) <= 0)
        return;

    UCHAR buf[DATABUFFERSIZE];
    int len = tun_read(g_tun_fd, buf, sizeof(buf));
    if (len <= 0)
        return;

    /* Sanity: only encapsulate what looks like an IPv4/IPv6 packet. */
    if (len < 20 || ((buf[0] & 0xF0) != 0x40 && (buf[0] & 0xF0) != 0x60))
        return;

    StartFEC(buf, len, g_fec_mode, /*intRepeats=*/0, /*blnSendID=*/FALSE);
}
