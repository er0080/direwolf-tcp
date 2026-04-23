/*
 * ardopc_test_stubs.c — minimal stubs to satisfy LinSerial.o and other
 * ardopc symbols when building isolated unit test binaries.
 *
 * These do NOT replace src/stubs.c (used in the main ardop-ip binary).
 * They exist only to satisfy the test binary linker.
 */

#include <stdarg.h>
#include <stdio.h>
#include "../src/ardopc/ardop2ofdm/ARDOPC.h"

char HostPort[80]  = "";
HANDLE hCATDevice  = 0;
HANDLE hPTTDevice  = 0;

/* RS globals normally defined in ARDOPC.c */
int NPAR      = -1;
int MaxErrors = 0;

void Debugprintf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

VOID WriteDebugLog(int level, const char *fmt, ...)
{
    (void)level;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

VOID ProcessSCSPacket(UCHAR *rxbuffer, unsigned int Length)
{
    (void)rxbuffer; (void)Length;
}
