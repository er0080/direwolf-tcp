/*
 * main.c — ardop-ip entry point
 *
 * Parses CLI arguments, configures ARDOPC globals, opens the TUN interface,
 * wires up Icom CI-V PTT, then calls ardopmain() which owns the event loop.
 */

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>

#include "ARDOPC.h"
#include "tun_interface.h"
#include "civ_control.h"

/* ── Forward declarations for ARDOPC globals we set before ardopmain() ─── */
extern char                  Callsign[];
extern char                  CaptureDevice[];
extern char                  PlaybackDevice[];
extern enum _ARQBandwidth    ARQBandwidth;
extern BOOL                  UseKISS;
extern BOOL                  RadioControl;
extern int                   PTTMode;
extern UCHAR                 PTTOnCmd[];
extern UCHAR                 PTTOnCmdLen;
extern UCHAR                 PTTOffCmd[];
extern UCHAR                 PTTOffCmdLen;
extern HANDLE                hCATDevice;
extern int                   FECStrengthNPAR;
extern int                   MinFrameCarriers;
extern int                   MaxFrameCarriers;

void ardopmain(void);
void tun_ardopc_init(int tun_fd, const char *fec_mode);

/* ── CI-V PTT frame builder ──────────────────────────────────────────────── */

static void build_civ_ptt(uint8_t addr)
{
    /* PTT on:  FE FE [addr] E0 1C 00 01 FD */
    PTTOnCmd[0] = 0xFE; PTTOnCmd[1] = 0xFE;
    PTTOnCmd[2] = addr; PTTOnCmd[3] = 0xE0;
    PTTOnCmd[4] = 0x1C; PTTOnCmd[5] = 0x00;
    PTTOnCmd[6] = 0x01; PTTOnCmd[7] = 0xFD;
    PTTOnCmdLen = 8;

    /* PTT off: FE FE [addr] E0 1C 00 00 FD */
    PTTOffCmd[0] = 0xFE; PTTOffCmd[1] = 0xFE;
    PTTOffCmd[2] = addr; PTTOffCmd[3] = 0xE0;
    PTTOffCmd[4] = 0x1C; PTTOffCmd[5] = 0x00;
    PTTOffCmd[6] = 0x00; PTTOffCmd[7] = 0xFD;
    PTTOffCmdLen = 8;

    PTTMode     = PTTCI_V;
    RadioControl = TRUE;
}

/* ── ARQBandwidth index from Hz string ─────────────────────────────────── */

static int bw_index(const char *s)
{
    int hz = atoi(s);
    /* enum _ARQBandwidth: XB200=0, XB500=1, XB2500=2 */
    switch (hz) {
    case 200:  return 0;
    case 500:  return 1;
    case 2500: return 2;
    default:
        fprintf(stderr, "ardop-ip: unknown bandwidth %d Hz (use 200/500/2500); using 2500\n", hz);
        return 2;
    }
}

/* ── Signal handling ────────────────────────────────────────────────────── */

extern BOOL blnClosing;

static void handle_sig(int sig)
{
    (void)sig;
    blnClosing = TRUE;

    /* Emergency PTT OFF.  write() is async-signal-safe; the frame bytes and
     * length are already populated during startup.  Sending this synchronously
     * on SIGINT/SIGTERM prevents a stuck radio when the main loop is killed
     * between PTT-ON and PTT-OFF. */
    if (hCATDevice > 0 && PTTOffCmdLen > 0)
        (void)write((int)(intptr_t)hCATDevice, PTTOffCmd, PTTOffCmdLen);
}

/* atexit() hook — runs on normal exit paths the signal handler misses. */
static void emergency_ptt_off(void)
{
    if (hCATDevice > 0 && PTTOffCmdLen > 0)
        (void)write((int)(intptr_t)hCATDevice, PTTOffCmd, PTTOffCmdLen);
}

/* ── usage ──────────────────────────────────────────────────────────────── */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s --audio DEVICE --mycall CALL [options]\n"
        "\n"
        "Required:\n"
        "  --audio DEVICE    ALSA device (e.g. plughw:CARD=CODEC,DEV=0)\n"
        "  --mycall CALL     Local callsign\n"
        "\n"
        "Network:\n"
        "  --local-ip ADDR   Local TUN address (default: 10.0.0.1)\n"
        "  --peer-ip  ADDR   Peer TUN address  (default: 10.0.0.2)\n"
        "  --tun-dev  NAME   TUN interface name (default: ardop0)\n"
        "  --mtu      N      MTU in bytes (default: 1460)\n"
        "\n"
        "FEC mode:\n"
        "  --bw   BW         Bandwidth Hz: 200|500|2500 (default: 2500)\n"
        "                    Selects the OFDM FEC mode (OFDM.{BW}.55).\n"
        "  --fec-strength S  RS parity per OFDM block: light|normal|strong\n"
        "                    (NPAR = 10 | 20 | 40, default: normal).\n"
        "                    Both peers MUST use the same value — NPAR is\n"
        "                    not signalled on-air.\n"
        "  --min-frame-carriers N   minimum OFDM carriers per TX (default 1)\n"
        "  --max-frame-carriers N   maximum OFDM carriers per TX (default 43)\n"
        "                    Phase 6.2: encoder sizes carriers to payload.\n"
        "                    Defaults preserve Phase 6.1 on-air behaviour.\n"
        "  --force-mode M    Pin OFDM mode (bypass gearshift).  One of:\n"
        "                    PSK2|PSK4|PSK8|QAM16|PSK16.  Default: unset.\n"
        "                    Phase 6.3a: for bench/RF testing only.\n"
        "\n"
        "CI-V radio control:\n"
        "  --civ-port PORT   Serial port (e.g. /dev/ic_705_a)\n"
        "  --civ-addr ADDR   Radio CI-V address hex (e.g. 0xa4 for IC-705)\n"
        "  --civ-baud BAUD   Baud rate (default: 115200)\n",
        prog);
}

/* ── main ───────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    /* Defaults */
    const char *audio    = NULL;
    const char *mycall   = NULL;
    const char *local_ip = "10.0.0.1";
    const char *peer_ip  = "10.0.0.2";
    const char *tun_dev  = "ardop0";
    const char *civ_port = NULL;
    int         civ_baud = 115200;
    uint8_t     civ_addr = 0;
    int         mtu      = 1460;
    int         bw       = 2;   /* XB2500 — 2500 Hz */
    int         fec_npar = 20;  /* normal */
    int         min_car  = 1;   /* Phase 6.2 default: 1 carrier minimum */
    int         max_car  = 43;  /* Phase 6.2 default: MAXCAR ceiling */
    int         force_mode = -1; /* Phase 6.3a: disabled by default */

    static struct option long_opts[] = {
        { "audio",        required_argument, 0, 'a' },
        { "mycall",       required_argument, 0, 'm' },
        { "local-ip",     required_argument, 0, 'l' },
        { "peer-ip",      required_argument, 0, 'r' },
        { "tun-dev",      required_argument, 0, 'd' },
        { "civ-port",     required_argument, 0, 'P' },
        { "civ-addr",     required_argument, 0, 'A' },
        { "civ-baud",     required_argument, 0, 'B' },
        { "bw",           required_argument, 0, 'w' },
        { "mtu",          required_argument, 0, 'M' },
        { "fec-strength", required_argument, 0, 'S' },
        { "min-frame-carriers", required_argument, 0, 'n' },
        { "max-frame-carriers", required_argument, 0, 'x' },
        { "force-mode",   required_argument, 0, 'F' },
        { "help",         no_argument,       0, 'h' },
        { 0, 0, 0, 0 }
    };

    int c, idx;
    while ((c = getopt_long(argc, argv, "h", long_opts, &idx)) != -1)
    {
        switch (c) {
        case 'a': audio     = optarg;          break;
        case 'm': mycall    = optarg;          break;
        case 'l': local_ip  = optarg;          break;
        case 'r': peer_ip   = optarg;          break;
        case 'd': tun_dev   = optarg;          break;
        case 'P': civ_port  = optarg;          break;
        case 'A': civ_addr  = (uint8_t)strtol(optarg, NULL, 16); break;
        case 'B': civ_baud  = atoi(optarg);    break;
        case 'w': bw        = bw_index(optarg); break;
        case 'M': mtu       = atoi(optarg);    break;
        case 'S':
            if (strcmp(optarg, "light") == 0)       fec_npar = 10;
            else if (strcmp(optarg, "normal") == 0) fec_npar = 20;
            else if (strcmp(optarg, "strong") == 0) fec_npar = 40;
            else {
                fprintf(stderr, "ardop-ip: unknown --fec-strength '%s' "
                                "(use light|normal|strong)\n", optarg);
                usage(argv[0]); return 1;
            }
            break;
        case 'n': min_car = atoi(optarg); break;
        case 'x': max_car = atoi(optarg); break;
        case 'F':
            if      (strcmp(optarg, "PSK2")  == 0) force_mode = 0;
            else if (strcmp(optarg, "PSK4")  == 0) force_mode = 1;
            else if (strcmp(optarg, "PSK8")  == 0) force_mode = 2;
            else if (strcmp(optarg, "QAM16") == 0) force_mode = 3;
            else if (strcmp(optarg, "PSK16") == 0) force_mode = 4;
            else {
                fprintf(stderr, "ardop-ip: unknown --force-mode '%s' "
                                "(use PSK2|PSK4|PSK8|QAM16|PSK16)\n", optarg);
                usage(argv[0]); return 1;
            }
            break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 1;
        }
    }

    if (!audio) {
        fprintf(stderr, "ardop-ip: --audio is required\n");
        usage(argv[0]); return 1;
    }
    if (!mycall) {
        fprintf(stderr, "ardop-ip: --mycall is required\n");
        usage(argv[0]); return 1;
    }
    if (civ_port && civ_addr == 0) {
        fprintf(stderr, "ardop-ip: --civ-port requires --civ-addr\n");
        usage(argv[0]); return 1;
    }

    /* ── Set ARDOPC globals before ardopmain() ─────────────────────────── */

    strncpy(Callsign,       mycall, 9);
    strncpy(CaptureDevice,  audio,  79);
    strncpy(PlaybackDevice, audio,  79);
    ARQBandwidth = (enum _ARQBandwidth)bw;
    UseKISS      = FALSE;
    FECStrengthNPAR = fec_npar;

    /* Phase 6.2: clamp and apply min/max carrier knobs */
    if (min_car < 1)  min_car = 1;
    if (min_car > 43) min_car = 43;
    if (max_car < min_car) max_car = min_car;
    if (max_car > 43) max_car = 43;
    MinFrameCarriers = min_car;
    MaxFrameCarriers = max_car;

    /* Phase 6.3a: apply --force-mode if set.  Gearshift is bypassed at TX time. */
    ForcedOFDMMode = force_mode;

    /* FEC mode string: pick from --bw value. */
    const char *fec_mode;
    switch (bw) {
    case 0:  fec_mode = "OFDM.200.55";  break;
    case 1:  fec_mode = "OFDM.500.55";  break;
    case 2:
    default: fec_mode = "OFDM.2500.55"; break;
    }

    /* ── CI-V PTT setup ─────────────────────────────────────────────────── */

    if (civ_port) {
        hCATDevice = civ_open(civ_port, civ_baud);
        if (hCATDevice < 0) {
            fprintf(stderr, "ardop-ip: cannot open CI-V port %s\n", civ_port);
            return 1;
        }
        build_civ_ptt(civ_addr);
        atexit(emergency_ptt_off);
        printf("CI-V PTT: %s addr=0x%02X baud=%d\n", civ_port, civ_addr, civ_baud);
    }

    /* ── TUN interface ──────────────────────────────────────────────────── */

    int tun_fd = tun_open(tun_dev);
    if (tun_fd < 0) {
        fprintf(stderr, "ardop-ip: failed to open TUN device %s\n", tun_dev);
        return 1;
    }
    tun_configure(tun_fd, tun_dev, local_ip, peer_ip, mtu);
    printf("TUN: %s  %s <-> %s  MTU %d\n", tun_dev, local_ip, peer_ip, mtu);

    tun_ardopc_init(tun_fd, fec_mode);

    /* ── Signal handlers ────────────────────────────────────────────────── */

    struct sigaction act = { .sa_handler = handle_sig };
    sigaction(SIGINT,  &act, NULL);
    sigaction(SIGTERM, &act, NULL);
    act.sa_handler = SIG_IGN;
    sigaction(SIGHUP,  &act, NULL);
    sigaction(SIGPIPE, &act, NULL);

    const char *strength =
        (fec_npar == 10) ? "light"  :
        (fec_npar == 40) ? "strong" : "normal";
    static const char *ofdm_mode_names[5] = { "PSK2","PSK4","PSK8","QAM16","PSK16" };
    const char *forced = (force_mode >= 0 && force_mode <= 4)
                         ? ofdm_mode_names[force_mode] : "off";
    printf("ardop-ip: %s  %s  FEC %s  strength %s (NPAR=%d) "
           "carriers=[%d..%d]  force-mode=%s\n",
           mycall, audio, fec_mode, strength, fec_npar,
           MinFrameCarriers, MaxFrameCarriers, forced);

    ardopmain();

    return 0;
}
