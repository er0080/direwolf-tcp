/*
 * arq_test_stubs.c -- stubs for all external symbols needed by ARQ.o.
 *
 * Does NOT include ARDOPC.h to avoid declaration conflicts.  Types match
 * the declarations in ARDOPC.h and the forward-declarations inside ARQ.c.
 *
 * Only GenCRC8 / GenerateSessionID are exercised at runtime; the rest of
 * the stubs are never called but must be present for the linker.
 */

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

typedef unsigned char UCHAR;
typedef int           BOOL;
#define FALSE 0
#define TRUE  1

/* ── State ─────────────────────────────────────────────────────────────── */

int ProtocolState = 1;      /* 1 = DISC */
const char ARDOPStates[8][9] = {
    "OFFLINE","DISC","ISS","IRS","IDLE","IRStoISS","FECSend","FECRcv"
};

/* ARQ bandwidth enum (matches ARDOPC.h enum _ARQBandwidth) */
int ARQBandwidth = 0;           /* BW200MAX */

/* Frame type name table */
const char strFrameType[64][18] = {{0}};

/* ARQ timing parameters */
unsigned int ARQTimeout      = 120;
int          ARQConReqRepeats = 10;

/* ── Scalar globals ──────────────────────────────────────────────────────── */

int   LeaderLength          = 160;
int   intCalcLeader         = 160;
int   intNumCar             = 0;
int   intRmtLeaderMeasure   = 0;
int   intLastRcvdFrameQuality = 0;
int   intLeaderRcvdMs       = 0;
int   intRepeatCount        = 0;
int   OFDMMode              = 0;
int   LastSentOFDMMode      = 0;
int   Squelch               = 0;
int   BusyDet               = 0;
int   CarrierOk             = 0;
int   EncLen                = 0;
int   bytDataToSendLength   = 0;
int   BytesSenttoHost       = 0;
int   SessBytesSent         = 0;
int   SessBytesReceived     = 0;
int   LastDataFrameType     = 0;
int   dttLastBusyClear      = 0;
int   dttLastBusyTrip       = 0;
int   dttLastFECIDSent      = 0;
int   dttLastLeaderDetect   = 0;
int   dttLastPINGSent       = 0;
int   dttNextPlay           = 0;
int   dttPriorLastBusyTrip  = 0;
int   DecodeCompleteTime    = 0;
int   intPINGRepeats        = 0;
int   tmrSendTimeout        = 0;

int   int4FSKQuality  = 0, int4FSKQualityCnts  = 0;
int   int8FSKQuality  = 0, int8FSKQualityCnts  = 0;
int   int16FSKQuality = 0, int16FSKQualityCnts = 0;
int   intGoodQAMSummationDecodes = 0;
int   intFSKSymbolsDecoded = 0;
int   intPSKSymbolsDecoded = 0;
int   intQAMSymbolsDecoded = 0;
int   goodReceivedBlockLen = 0;
int   goodReceivedBlocks   = 0;
int   OFDMCarriersAcked    = 0;
int   OFDMCarriersDecoded  = 0;
int   OFDMCarriersNaked    = 0;
int   OFDMCarriersReceived = 0;

/* ── Bool globals ────────────────────────────────────────────────────────── */

int  AccumulateStats     = FALSE;
int  blnAbort            = FALSE;
int  blnARQDisconnect    = FALSE;
int  blnFramePending     = FALSE;
int  blnPINGrepeating    = FALSE;
int  blnTimeoutTriggered = FALSE;
int  DebugLog            = FALSE;
int  EnableOFDM          = FALSE;
int  fastStart           = FALSE;
int  FSKOnly             = FALSE;
int  Good                = FALSE;
int  NegotiateBW         = FALSE;
int  newStatus           = FALSE;
int  SoundIsPlaying      = FALSE;
int  UseOFDM             = FALSE;

/* ── Array globals ───────────────────────────────────────────────────────── */

UCHAR bytDataToSend[4096]       = {0};
UCHAR bytEncodedBytes[4500]     = {0};
char  Callsign[10]              = "KD2MYS";
char  GridSquare[9]             = "FN30";
int   intPSKQuality[2]          = {0};
int   intPSKQualityCnts[2]      = {0};
int   intQAMQuality[2]          = {0};
int   intQAMQualityCnts[2]      = {0};
int   intOFDMQuality[8]         = {0};
int   intOFDMQualityCnts[8]     = {0};
const char OFDMModes[8][6]      = {{0}};

/* ── Function stubs ──────────────────────────────────────────────────────── */

unsigned int getTicks(void) { return 0; }

void  AddTagToDataAndSendToHost(UCHAR *m, char *t, int l) { (void)m;(void)t;(void)l; }
void  ClearBusy(void)           {}
void  ClearDataToSend(void)     { bytDataToSendLength = 0; }
void  ClearOFDMVariables(void)  {}
void  CloseDebugLog(void)       {}
void  CloseStatsLog(void)       {}
void  DrawTXMode(const char *s) { (void)s; }
int   Encode4FSKIDFrame(char *a, char *b, UCHAR *c, UCHAR d)
      { (void)a;(void)b;(void)c;(void)d; return 0; }
void  EncodeAndSend4FSKControl(UCHAR t, UCHAR s, int l) { (void)t;(void)s;(void)l; }
void  EncodeAndSendOFDMACK(UCHAR s, int l)              { (void)s;(void)l; }
int   EncodeARQConRequest(char *a, char *b, int bw, UCHAR *r)
      { (void)a;(void)b;(void)bw;(void)r; return 0; }
int   EncodeFSKData(UCHAR t, UCHAR *d, int l, UCHAR *out)
      { (void)t;(void)d;(void)l;(void)out; return 0; }
int   EncodePSKData(UCHAR t, UCHAR *d, int l, UCHAR *out)
      { (void)t;(void)d;(void)l;(void)out; return 0; }
int   EncodeOFDMData(UCHAR t, UCHAR *d, int l, UCHAR *out)
      { (void)t;(void)d;(void)l;(void)out; return 0; }
int   FrameInfo(UCHAR t, int *b1, int *nc, char *s, int *n, int *r, int *w, int *rs)
      { (void)t;(void)b1;(void)nc;(void)s;(void)n;(void)r;(void)w;(void)rs; return 0; }
void  FreeSemaphore(void)       {}
void  GetOFDMFrameInfo(int m, int *dl, int *rl, int *mo, int *sy)
      { (void)m;(void)dl;(void)rl;(void)mo;(void)sy; }
void  GetSemaphore(void)        {}
int   IsConReqFrame(int t)      { (void)t; return 0; }
int   IsDataFrame(int t)        { (void)t; return 0; }
void  Mod4FSKDataAndPlay(UCHAR *d, int l, int leader) { (void)d;(void)l;(void)leader; }
void  ModOFDMDataAndPlay(UCHAR *d, int l, int leader) { (void)d;(void)l;(void)leader; }
void  ModPSKDataAndPlay(UCHAR *d, int l, int leader)  { (void)d;(void)l;(void)leader; }
const char *Name(UCHAR t)       { (void)t; return ""; }
const char *shortName(UCHAR t)  { (void)t; return ""; }
int   ProcessOFDMAck(int t)     { (void)t; return 0; }
void  ProcessOFDMNak(int t)     { (void)t; }
void  ProcessCQFrame(char *d)   { (void)d; }
void  ProcessPingFrame(UCHAR t, UCHAR *d, BOOL ok)
      { (void)t;(void)d;(void)ok; }
void  QueueCommandToHost(char *s)   { (void)s; }
void  RemoveDataFromQueue(int n)    { (void)n; }
void  RemoveProcessedOFDMData(void) {}
void  SaveQueueOnBreak(void)        {}
void  SendCommandToHost(char *s)    { (void)s; }
void  SetLED(int id, int on)        { (void)id;(void)on; }
void  Statsprintf(const char *fmt, ...)
      { va_list a; va_start(a,fmt); va_end(a); }
void  txSleep(int ms)               { (void)ms; }
void  PlatformSleep(int ms)         { (void)ms; }
void  updateDisplay(void)           {}
int   CheckValidCallsignSyntax(char *s) { (void)s; return 1; }

void  displayState(const char *s)   { (void)s; }
void  displayCall(int d, char *c)   { (void)d;(void)c; }

char *strlop(char *buf, char delim)
{
    /* Strip everything from delim onward; return pointer past delim or NULL */
    char *p = buf;
    while (*p && *p != delim) p++;
    if (*p == delim) { *p = '\0'; return p + 1; }
    return NULL;
}

/* Already in ardopc_test_stubs.c: WriteDebugLog, Debugprintf, NPAR, MaxErrors,
   HostPort, hCATDevice, hPTTDevice, ProcessSCSPacket                            */
