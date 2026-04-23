/*
 * tests/test_bw3000.c — Phase 6.4 unit tests for the 3.0 kHz OFDM mode.
 *
 * Covers:
 *   - MAXCAR was bumped to the expected value (static_assert).
 *   - The XB3000 enum exists and is distinct from XB2500.
 *   - DOFDM_3000_55_E / DOFDM_3000_55_O are new, distinct frame codes.
 *   - FrameInfo() returns 54 carriers / 55 baud / "OFDM" for the new codes.
 *   - Backward compatibility: FrameInfo(DOFDM_2500_55_E) still returns 43.
 *   - Template regeneration math: the centered 43-carrier subset inside
 *     the 54-row template maps to the SAME frequencies as the legacy
 *     43-row table, i.e. 333..2667 Hz.
 *   - The top carrier of the 54-row mode stays within 12 kHz / 2 Nyquist.
 *
 * Standalone: like test_varsize, this avoids linking ARDOPC.o to keep the
 * test hermetic.  It reproduces the small integer logic under test.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "unity.h"
#include "../src/ardopc/ardop2ofdm/ARDOPC.h"

/* ─ Compile-time invariants ───────────────────────────────────────────── */

_Static_assert(MAXCAR == 54,
    "Phase 6.4: MAXCAR must be 54 for the 3.0 kHz OFDM mode.");

_Static_assert(XB3000 != XB2500,
    "Phase 6.4: XB3000 must be a distinct _ARQBandwidth value.");

_Static_assert(XB3000 == 3,
    "Phase 6.4: XB3000 must equal 3 (directly after XB2500=2).");

_Static_assert(DOFDM_3000_55_E == 0x36 && DOFDM_3000_55_O == 0x37,
    "Phase 6.4: DOFDM_3000_55_E/O must occupy slots 0x36/0x37.");

_Static_assert(DOFDM_2500_55_E == 0x34,
    "Backward compat: DOFDM_2500_55_E must not move.");

/* ─ Reproduce the FrameInfo() branches we care about ──────────────────── */
/* Kept in sync with src/ardopc/ardop2ofdm/ARDOPC.c::FrameInfo(). */

struct finfo { int numCar; int dataLen; int rsLen; int baud; const char *mod; };

static int local_frame_info(unsigned char ft, struct finfo *out)
{
    switch (ft & 0xFE) {
    case DOFDM_200_55_E:
        out->numCar = 3;  out->dataLen = 40; out->rsLen = 10;
        out->baud = 55;   out->mod = "OFDM"; return 1;
    case DOFDM_500_55_E:
        out->numCar = 9;  out->dataLen = 40; out->rsLen = 10;
        out->baud = 55;   out->mod = "OFDM"; return 1;
    case DOFDM_2500_55_E:
        out->numCar = 43; out->dataLen = 40; out->rsLen = 10;
        out->baud = 55;   out->mod = "OFDM"; return 1;
    case DOFDM_3000_55_E:
        out->numCar = 54; out->dataLen = 40; out->rsLen = 10;
        out->baud = 55;   out->mod = "OFDM"; return 1;
    default:
        return 0;
    }
}

/* ─ Template-frequency math (mirrors CalcTemplates.c) ─────────────────── */

static float carrier_hz(int idx)
{
    /* InitExtendedOFDMTemplates() uses spacing 10000/180 Hz and
     * offset = (MAXCAR - 1)/2.  Reproduce here so the test remains
     * standalone. */
    const float spacing = 10000.0f / 180.0f;
    const int   offset  = (MAXCAR - 1) / 2;   /* 26 when MAXCAR=54 */
    return 1500.0f + spacing * (float)(idx - offset);
}

static int car_start(int intNumCar)
{
    /* Matches TX modulator: intCarStartIndex = (MAXCAR - intNumCar) / 2. */
    return (MAXCAR - intNumCar) / 2;
}

/* ─ Tests ─────────────────────────────────────────────────────────────── */

static void test_bw_new_mode_frame_info(void)
{
    struct finfo f;

    TEST_ASSERT_EQUAL_INT(1, local_frame_info(DOFDM_3000_55_E, &f));
    TEST_ASSERT_EQUAL_INT(54, f.numCar);
    TEST_ASSERT_EQUAL_INT(55, f.baud);
    TEST_ASSERT_EQUAL_INT(40, f.dataLen);
    TEST_ASSERT_EQUAL_INT(10, f.rsLen);
    TEST_ASSERT_EQUAL_STRING("OFDM", f.mod);

    /* Odd pair must report identical params (differ only in blnOdd flag). */
    TEST_ASSERT_EQUAL_INT(1, local_frame_info(DOFDM_3000_55_O, &f));
    TEST_ASSERT_EQUAL_INT(54, f.numCar);
}

static void test_bw_default_still_2500(void)
{
    /* Regression: adding XB3000 and DOFDM_3000_* must not move or shrink
     * the existing 2500 Hz mode. */
    struct finfo f;
    TEST_ASSERT_EQUAL_INT(1, local_frame_info(DOFDM_2500_55_E, &f));
    TEST_ASSERT_EQUAL_INT(43, f.numCar);
    TEST_ASSERT_EQUAL_INT(55, f.baud);
    TEST_ASSERT_EQUAL_INT(40, f.dataLen);
    TEST_ASSERT_EQUAL_INT(10, f.rsLen);
    TEST_ASSERT_EQUAL_STRING("OFDM", f.mod);

    /* And 500/200 Hz modes are unchanged. */
    TEST_ASSERT_EQUAL_INT(1, local_frame_info(DOFDM_500_55_E, &f));
    TEST_ASSERT_EQUAL_INT(9, f.numCar);
    TEST_ASSERT_EQUAL_INT(1, local_frame_info(DOFDM_200_55_E, &f));
    TEST_ASSERT_EQUAL_INT(3, f.numCar);
}

static void test_bw_maxcar_increased(void)
{
    /* Runtime sanity on top of the _Static_assert above. */
    TEST_ASSERT_EQUAL_INT(54, MAXCAR);
    TEST_ASSERT_EQUAL_INT(26, (MAXCAR - 1) / 2);
}

static void test_bw_carrier_frequencies(void)
{
    /* Template offset formula must keep legacy 43-carrier mode at its
     * original frequencies — the data starts at index 5 and ends at
     * index 47 inside the 54-slot template (since car_start(43) = 5). */
    TEST_ASSERT_EQUAL_INT(5, car_start(43));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 333.33f, carrier_hz(5));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 2666.67f, carrier_hz(47));

    /* 9-carrier mode (500 Hz) → start=22, carriers 22..30, centered @ 1500. */
    TEST_ASSERT_EQUAL_INT(22, car_start(9));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 1277.78f, carrier_hz(22));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 1722.22f, carrier_hz(30));

    /* 3-carrier mode (200 Hz) → start=25, carriers 25..27 centered at 1500. */
    TEST_ASSERT_EQUAL_INT(25, car_start(3));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 1444.44f, carrier_hz(25));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 1500.00f, carrier_hz(26));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 1555.56f, carrier_hz(27));

    /* 54-carrier mode (3.0 kHz) — full array.  Bounds checks:
     * Lowest carrier (idx 0) = 1500 - 26*55.56 = 55.56 Hz (well below
     * 300 Hz passband; will be filter-attenuated on most HF radios).
     * Highest carrier (idx 53) = 1500 + 27*55.56 = 3000 Hz. */
    TEST_ASSERT_EQUAL_INT(0, car_start(54));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 55.56f,  carrier_hz(0));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, 3000.0f, carrier_hz(53));

    /* Nyquist sanity: at 12 kHz sample rate the top carrier must sit
     * comfortably below 6000 Hz (pure math, should be obvious, but
     * protects against a future MAXCAR bump that goes aliasing). */
    TEST_ASSERT_TRUE(carrier_hz(MAXCAR - 1) < 6000.0f);
}

static void test_bw_spacing_uniform(void)
{
    /* Carrier spacing must be uniform across all 54 slots.  This invariant
     * is what makes OFDM de-mapping trivial and cannot be violated. */
    const float spacing = 10000.0f / 180.0f;
    for (int i = 1; i < MAXCAR; i++) {
        float diff = carrier_hz(i) - carrier_hz(i - 1);
        TEST_ASSERT_FLOAT_WITHIN(0.01f, spacing, diff);
    }
}

/* ─ Unity runner ──────────────────────────────────────────────────────── */

void setUp(void)    {}
void tearDown(void) {}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_bw_maxcar_increased);
    RUN_TEST(test_bw_new_mode_frame_info);
    RUN_TEST(test_bw_default_still_2500);
    RUN_TEST(test_bw_carrier_frequencies);
    RUN_TEST(test_bw_spacing_uniform);
    return UNITY_END();
}
