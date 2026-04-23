/*
 * civ_control.c — Icom CI-V PTT and radio control for ardop-ip
 *
 * Phase 1: skeleton implementation — symbols are defined so the build
 * links cleanly.  Full implementation is added in Phase 3.
 *
 * CI-V frame structure:
 *   FE FE <radio_addr> <ctrl=0xE0> <cmd> [<sub-cmd>] [data...] FD
 *
 * PTT on  (cmd 0x1C, sub-cmd 0x00, data 0x01): FE FE AA E0 1C 00 01 FD
 * PTT off (cmd 0x1C, sub-cmd 0x00, data 0x00): FE FE AA E0 1C 00 00 FD
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "ardopc/ardop2ofdm/ARDOPC.h"
#include "civ_control.h"

/* LinSerial.c functions — no public header, forward-declare here */
extern HANDLE OpenCOMPort(void *Port, int speed, BOOL SetDTR, BOOL SetRTS,
                          BOOL Quiet, int Stopbits);
extern BOOL   WriteCOMBlock(HANDLE fd, char *Block, int BytesToWrite);
extern int    ReadCOMBlock(HANDLE fd, char *Block, int MaxLength);

#define CIV_PREAMBLE1  0xFE
#define CIV_PREAMBLE2  0xFE
#define CIV_CTRL       0xE0
#define CIV_EOT        0xFD

/* Maximum CI-V response frame length */
#define CIV_MAX_FRAME  32

int civ_open(const char *port, int baud)
{
    HANDLE fd = OpenCOMPort((void *)port, baud,
                            /*SetDTR=*/1, /*SetRTS=*/0,
                            /*Quiet=*/0,  /*Stopbits=*/0);
    return (int)(intptr_t)fd;
}

void civ_ptt(int fd, uint8_t radio_addr, int on)
{
    uint8_t frame[] = {
        CIV_PREAMBLE1, CIV_PREAMBLE2,
        radio_addr, CIV_CTRL,
        0x1C, 0x00,         /* PTT command */
        on ? 0x01 : 0x00,   /* data: 1=TX, 0=RX */
        CIV_EOT
    };
    HANDLE h = (HANDLE)(intptr_t)fd;
    WriteCOMBlock(h, (char *)frame, sizeof(frame));
}

void civ_set_freq(int fd, uint8_t radio_addr, uint32_t hz)
{
    /* BCD-encode 10 digits into 5 bytes, LS pair first */
    uint8_t bcd[5];
    uint32_t tmp = hz;
    for (int i = 0; i < 5; i++) {
        bcd[i] = (uint8_t)((tmp % 10) | (((tmp / 10) % 10) << 4));
        tmp /= 100;
    }
    uint8_t frame[] = {
        CIV_PREAMBLE1, CIV_PREAMBLE2,
        radio_addr, CIV_CTRL,
        0x05,                           /* set frequency */
        bcd[0], bcd[1], bcd[2], bcd[3], bcd[4],
        CIV_EOT
    };
    HANDLE h = (HANDLE)(intptr_t)fd;
    WriteCOMBlock(h, (char *)frame, sizeof(frame));
}

void civ_set_mode(int fd, uint8_t radio_addr, uint8_t mode)
{
    uint8_t frame[] = {
        CIV_PREAMBLE1, CIV_PREAMBLE2,
        radio_addr, CIV_CTRL,
        0x06,   /* set mode */
        mode,
        0x01,   /* filter: normal */
        CIV_EOT
    };
    HANDLE h = (HANDLE)(intptr_t)fd;
    WriteCOMBlock(h, (char *)frame, sizeof(frame));
}

int civ_poll(int fd, uint8_t *resp, int maxlen)
{
    HANDLE h = (HANDLE)(intptr_t)fd;
    int n = ReadCOMBlock(h, (char *)resp, maxlen);
    return n;
}
