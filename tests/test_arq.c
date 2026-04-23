/*
 * tests/test_arq.c -- unit tests for ARQ session ID and state init (ARQ.c)
 *
 * Tests the pure-computation functions GenCRC8 and GenerateSessionID without
 * requiring audio hardware.  The full ARQ state machine (connect handshake,
 * retransmit, disconnect) is validated in Phase 4 ALSA loopback integration
 * tests, where two ardop-ip instances exercise the real audio path.
 *
 * No radio hardware required.
 */

#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include "unity.h"
#include "../src/ardopc/ardop2ofdm/ARDOPC.h"

/* Forward-declare the functions under test (internal to ARQ.c, no public header) */
UCHAR GenCRC8(char *Data);
UCHAR GenerateSessionID(char *strCallingCallSign, char *strTargetCallsign);

/* ── setUp / tearDown ────────────────────────────────────────────────────── */

void setUp(void)    {}
void tearDown(void) {}

/* ── Tests ───────────────────────────────────────────────────────────────── */

void test_arq_crc8_deterministic(void)
{
    /* Same input must produce same output every time */
    UCHAR a = GenCRC8("KD2MYS");
    UCHAR b = GenCRC8("KD2MYS");
    TEST_ASSERT_EQUAL_HEX8_MESSAGE(a, b, "GenCRC8 not deterministic");
}

void test_arq_crc8_different_inputs(void)
{
    /* Different callsigns must produce different CRC values */
    UCHAR a = GenCRC8("KD2MYS");
    UCHAR b = GenCRC8("W1AW");
    TEST_ASSERT_NOT_EQUAL_MESSAGE(a, b,
        "GenCRC8 produced same value for different callsigns");
}

void test_arq_session_id_deterministic(void)
{
    /* Same (caller, target) pair must yield same session ID */
    UCHAR id1 = GenerateSessionID("KD2MYS", "W1AW");
    UCHAR id2 = GenerateSessionID("KD2MYS", "W1AW");
    TEST_ASSERT_EQUAL_HEX8_MESSAGE(id1, id2,
        "GenerateSessionID not deterministic");
}

void test_arq_session_id_not_reserved(void)
{
    /*
     * 0x3F is reserved for FEC mode.  GenerateSessionID must remap
     * any collision to 0x00.
     */
    UCHAR id = GenerateSessionID("KD2MYS", "W1AW");
    TEST_ASSERT_NOT_EQUAL_MESSAGE(0x3F, (id & 0x3F),
        "GenerateSessionID returned reserved session ID 0x3F");
}

void test_arq_session_id_direction_asymmetric(void)
{
    /*
     * (A calls B) and (B calls A) should generally produce different IDs
     * because the concatenated strings differ.
     */
    UCHAR ab = GenerateSessionID("KD2MYS",   "W1AW");
    UCHAR ba = GenerateSessionID("W1AW",     "KD2MYS");
    /* Not guaranteed to differ in all cases, but it's the normal case */
    TEST_ASSERT_NOT_EQUAL_MESSAGE(ab, ba,
        "GenerateSessionID symmetric for reversed caller/target (unexpected)");
}

void test_arq_session_id_6bit_range(void)
{
    /* Session IDs must fit in 6 bits (0x00..0x3E, since 0x3F is remapped) */
    UCHAR id = GenerateSessionID("KD2MYS", "W1AW");
    TEST_ASSERT_MESSAGE((id & ~0x3F) == 0,
        "GenerateSessionID returned value outside 6-bit range");
}

/* ── Main ────────────────────────────────────────────────────────────────── */

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_arq_crc8_deterministic);
    RUN_TEST(test_arq_crc8_different_inputs);
    RUN_TEST(test_arq_session_id_deterministic);
    RUN_TEST(test_arq_session_id_not_reserved);
    RUN_TEST(test_arq_session_id_direction_asymmetric);
    RUN_TEST(test_arq_session_id_6bit_range);
    return UNITY_END();
}
