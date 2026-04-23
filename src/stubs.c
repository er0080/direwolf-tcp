/*
 * stubs.c — no-op implementations of AX.25 packet, SCS host interface,
 * and display functions removed from the ardop-ip build.
 *
 * ardop-ip replaces the host-protocol and packet layers with a TUN
 * network interface. These stubs satisfy the linker for symbols that
 * remain referenced in the kept ardopc source files but have no
 * functional role in the new design.
 */

#include <string.h>
#include "ardopc/ardop2ofdm/ARDOPC.h"

/* ── Globals from SCSHostInterface.c ─────────────────────────────────────── */

int   bytDataToSendLength = 0;
UCHAR bytEchoData[127 * 80];       /* must be at least OFDM Window size */
int   bytesEchoed         = 0;
UCHAR DelayedEcho         = '0';

/* ── Globals from pktSession.c ────────────────────────────────────────────── */

int PORTT1 = 40;   /* 4 * L2TICK (L2TICK=10) */
int PORTN2 = 6;    /* retries */

/* ── Globals from pktARDOP.c ─────────────────────────────────────────────── */

int        pktMode    = 0;
int        pktModeLen = 0;
int        pktDataLen = 0;
int        pktRSLen   = 0;
int        initMode   = 0;
int        pktRXMode  = 0;

const char    pktMod[16][12]   = {{0}};
const int     pktBW[16]        = {0};
const int     pktCarriers[16]  = {0};
const BOOL    pktFSK[16]       = {0};

/* ── SCS host interface stubs ────────────────────────────────────────────── */

void SCSSendCommandToHost(char *Cmd)        { (void)Cmd; }
void SCSSendCommandToHostQuiet(char *Cmd)   { (void)Cmd; }
void SCSSendReplyToHost(char *strText)      { (void)strText; }
void SCSQueueCommandToHost(char *Cmd)       { (void)Cmd; }
void SCSAddTagToDataAndSendToHost(UCHAR *Msg, char *Type, int Len)
{
    (void)Msg; (void)Type; (void)Len;
}

/* ── Packet session stubs ────────────────────────────────────────────────── */

VOID ClosePacketSessions(void)                              { }
BOOL CheckForPktMon(void)                                   { return FALSE; }
BOOL CheckForPktData(int Channel)                           { (void)Channel; return FALSE; }
VOID ProcessPacketHostBytes(UCHAR *RXBuffer, int Len)       { (void)RXBuffer; (void)Len; }
VOID ptkSessionBG(void)                                     { }

/* ── pktARDOP stubs ──────────────────────────────────────────────────────── */

void PktARDOPStartTX(void) { }
VOID EmCRCStuffAndSend(UCHAR *Msg, int Len) { (void)Msg; (void)Len; }
VOID L2Routine(UCHAR *Packet, int Length, int FrameQuality,
               int totalRSErrors, int NumCar, int pktRXMode_)
{
    (void)Packet; (void)Length; (void)FrameQuality;
    (void)totalRSErrors; (void)NumCar; (void)pktRXMode_;
}
VOID ProcessSCSPacket(UCHAR *rxbuffer, unsigned int Length)
{
    (void)rxbuffer; (void)Length;
}
VOID ConvertCallstoAX25(void) { }

/* ── Display stubs (i2cDisplay / Waveout replaced) ───────────────────────── */

int  initdisplay(void)                      { return 0; }
void displayLevel(int max)                  { (void)max; }
void displayState(const char *State)        { (void)State; }
void displayCall(int dirn, char *call)      { (void)dirn; (void)call; }
