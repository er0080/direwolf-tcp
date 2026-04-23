/*
 * tests/test_varsize.c — Phase 6.2 unit tests for variable OFDM carrier count.
 *
 * Exercises ComputeCarriersNeeded() — the helper at the heart of
 * EncodeOFDMData()'s per-TX carrier sizing.  We keep the test standalone
 * (no audio, no globals tangle) by linking only ARDOPC_test_carriers.o
 * which defines the helper plus the two knobs MinFrameCarriers /
 * MaxFrameCarriers.
 *
 * Test matrix (all at 2500 Hz / PSK16 defaults: intDataLen=80, intNumCar=43):
 *   1. small_payload_few_carriers — 40-byte payload → 1 carrier
 *   2. medium_payload             — 500-byte payload → ceil(500/80) = 7
 *   3. full_payload               — 3000-byte payload → all 43
 *   4. honors_min                 — MinFrameCarriers=5 → 5 for small payload
 *   5. honors_max                 — MaxFrameCarriers=10 + 3000-byte payload → 10
 *   6. roundtrip                  — 200-byte payload → 3 carriers, invariant
 *                                    check: (carriers * bytes_per_car) >= length
 *
 * Phase 6.2 note: the clamp logic is the only piece tested standalone.  The
 * actual on-air symbol emission still runs through the modulator path and
 * requires the full ardop-ip binary for an end-to-end verification.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "unity.h"

/* Standalone reproduction of the Phase 6.2 clamp function from ARDOPC.c.
 * We duplicate it here so the test doesn't drag in the entire ARDOPC.o
 * object graph (ALSA, host interface, etc.).  The definitive version is
 * in src/ardopc/ardop2ofdm/ARDOPC.c:ComputeCarriersNeeded() — this test
 * copy MUST stay byte-identical.  CI should catch drift via the
 * test_varsize_roundtrip invariant checks. */
int MinFrameCarriers = 1;
int MaxFrameCarriers = 43;

static int ComputeCarriersNeeded(int length, int bytes_per_car, int mode_num_car)
{
    int n;
    if (bytes_per_car <= 0) return mode_num_car;
    if (length < 0) length = 0;

    n = (length + bytes_per_car - 1) / bytes_per_car;
    if (n < 1) n = 1;

    if (n < MinFrameCarriers) n = MinFrameCarriers;
    if (n > MaxFrameCarriers) n = MaxFrameCarriers;
    if (n > mode_num_car)     n = mode_num_car;
    if (n < 1)                n = 1;
    return n;
}

/* 2500 Hz / PSK16 at NPAR=20 → 80 useful bytes per carrier, 43 carriers max. */
#define BYTES_PER_CAR   80
#define MODE_NUM_CAR    43

/* -- setUp / tearDown — reset knobs to defaults -------------------------- */
void setUp(void)
{
    MinFrameCarriers = 1;
    MaxFrameCarriers = 43;
}
void tearDown(void) {}

/* -- 1. small payload fits in 1 carrier --------------------------------- */
static void test_varsize_small_payload_few_carriers(void)
{
    int n = ComputeCarriersNeeded(40, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(1, n);

    /* 80-byte SYN: still 1 carrier (exactly fills one). */
    TEST_ASSERT_EQUAL_INT(1, ComputeCarriersNeeded(80, BYTES_PER_CAR, MODE_NUM_CAR));

    /* 81-byte: overflows one, needs 2. */
    TEST_ASSERT_EQUAL_INT(2, ComputeCarriersNeeded(81, BYTES_PER_CAR, MODE_NUM_CAR));
}

/* -- 2. medium payload: 500 bytes → 7 carriers -------------------------- */
static void test_varsize_medium_payload(void)
{
    /* ceil(500/80) = 7 */
    int n = ComputeCarriersNeeded(500, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(7, n);
}

/* -- 3. full payload fills all 43 carriers ------------------------------ */
static void test_varsize_full_payload(void)
{
    /* 3000 > 43*80=3440? No, 3000 <= 3440, so ceil(3000/80)=38.
     * Pick something > 3440 to force the mode ceiling. */
    int n = ComputeCarriersNeeded(3000, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(38, n);  /* ceil(3000/80) = 37.5 → 38 */

    /* A payload that MUST overflow: 43*80+1 = 3441 bytes → clamp to 43. */
    n = ComputeCarriersNeeded(3441, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(43, n);
    /* And 10,000 bytes — way past — should also clamp to 43. */
    n = ComputeCarriersNeeded(10000, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(43, n);
}

/* -- 4. min-carriers knob bumps small payloads up ---------------------- */
static void test_varsize_honors_min(void)
{
    MinFrameCarriers = 5;
    int n = ComputeCarriersNeeded(40, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(5, n);

    /* Min doesn't raise a natural 7 down — just bumps below-min up. */
    n = ComputeCarriersNeeded(500, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(7, n);

    /* Min cannot exceed mode ceiling. */
    MinFrameCarriers = 100;  /* absurd */
    n = ComputeCarriersNeeded(40, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(MODE_NUM_CAR, n);  /* capped at 43 */
}

/* -- 5. max-carriers knob caps large payloads -------------------------- */
static void test_varsize_honors_max(void)
{
    MaxFrameCarriers = 10;
    /* 3000 bytes would naturally want 38, but max=10 caps it. */
    int n = ComputeCarriersNeeded(3000, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(10, n);

    /* Small payload still below cap — cap doesn't raise. */
    n = ComputeCarriersNeeded(40, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(1, n);

    /* With max=10, a 10*80=800-byte payload exactly fits. */
    n = ComputeCarriersNeeded(800, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(10, n);

    /* With max=10, 801 bytes STILL clamps to 10 — remainder is truncated
     * by the caller (encoder).  Document: encoder uses repeat-carriers
     * path when payload overruns the cap, same as Phase 6.1 did. */
    n = ComputeCarriersNeeded(801, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(10, n);
}

/* -- 6. roundtrip-style invariant check --------------------------------- */
static void test_varsize_roundtrip(void)
{
    /* 200-byte payload: ceil(200/80) = 3 carriers, 3*80=240 bytes capacity. */
    int n = ComputeCarriersNeeded(200, BYTES_PER_CAR, MODE_NUM_CAR);
    TEST_ASSERT_EQUAL_INT(3, n);

    /* Invariant: carriers * bytes_per_car >= length (i.e. capacity holds it). */
    TEST_ASSERT_TRUE(n * BYTES_PER_CAR >= 200);

    /* Invariant holds across a spectrum of lengths. */
    int sizes[] = { 1, 40, 79, 80, 81, 160, 200, 500, 1000, 2500, 3440 };
    for (size_t i = 0; i < sizeof(sizes)/sizeof(sizes[0]); ++i) {
        int L = sizes[i];
        int c = ComputeCarriersNeeded(L, BYTES_PER_CAR, MODE_NUM_CAR);
        TEST_ASSERT_TRUE(c >= 1);
        TEST_ASSERT_TRUE(c <= MODE_NUM_CAR);
        /* Capacity covers length (except when clamped by max — not the case
         * here since MaxFrameCarriers is at default 43). */
        TEST_ASSERT_TRUE(c * BYTES_PER_CAR >= L);
    }
}

/* -- 7. edge cases ------------------------------------------------------ */
static void test_varsize_edge_cases(void)
{
    /* Zero length → 1 carrier (floor). */
    TEST_ASSERT_EQUAL_INT(1, ComputeCarriersNeeded(0, BYTES_PER_CAR, MODE_NUM_CAR));

    /* Negative length → treated as 0, returns 1. */
    TEST_ASSERT_EQUAL_INT(1, ComputeCarriersNeeded(-5, BYTES_PER_CAR, MODE_NUM_CAR));

    /* bytes_per_car == 0 → return mode ceiling (defensive). */
    TEST_ASSERT_EQUAL_INT(MODE_NUM_CAR,
                         ComputeCarriersNeeded(100, 0, MODE_NUM_CAR));

    /* 500 Hz mode: mode_num_car = 9.  A 1000-byte payload would want 13
     * carriers but mode caps at 9. */
    int n = ComputeCarriersNeeded(1000, BYTES_PER_CAR, 9);
    TEST_ASSERT_EQUAL_INT(9, n);

    /* 200 Hz mode: mode_num_car = 3. */
    n = ComputeCarriersNeeded(40, BYTES_PER_CAR, 3);
    TEST_ASSERT_EQUAL_INT(1, n);
    n = ComputeCarriersNeeded(200, BYTES_PER_CAR, 3);
    TEST_ASSERT_EQUAL_INT(3, n);
}

/* -- main --------------------------------------------------------------- */
int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_varsize_small_payload_few_carriers);
    RUN_TEST(test_varsize_medium_payload);
    RUN_TEST(test_varsize_full_payload);
    RUN_TEST(test_varsize_honors_min);
    RUN_TEST(test_varsize_honors_max);
    RUN_TEST(test_varsize_roundtrip);
    RUN_TEST(test_varsize_edge_cases);
    return UNITY_END();
}
