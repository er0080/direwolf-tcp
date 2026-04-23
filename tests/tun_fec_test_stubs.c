/*
 * tests/tun_fec_test_stubs.c — stubs for the Phase 6.1a TUN/FEC unit test.
 *
 * tun_ardopc.c pulls in a handful of ARDOPC globals and calls into StartFEC().
 * For the host-side test we don't care about ARDOP internals — we only need
 * the linker to resolve these symbols.  tun_write is intentionally *not*
 * stubbed here: we use the real implementation from src/tun_interface.c so
 * the test actually writes through to the fd we configure (a pipe).
 */

#include <unistd.h>

typedef unsigned char UCHAR;

/* Match the widths and storage of the real globals.  Values are untouched
 * by test_tun_fec: it exercises TUNDeliverToHost, which never reads them. */
int bytDataToSendLength = 0;
int ProtocolState       = 1;  /* DISC */
int ProtocolMode        = 1;  /* FEC */

int StartFEC(UCHAR *bytData, int Len, char *strDataMode,
             int intRepeats, int blnSendID)
{
    (void)bytData; (void)Len; (void)strDataMode;
    (void)intRepeats; (void)blnSendID;
    return 1; /* TRUE */
}
