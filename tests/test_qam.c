/*
 * tests/test_qam.c — Phase 6.3a unit tests for the QAM16 OFDM modulation.
 *
 * These exercise the QAM16 code paths that were previously gated off by
 * five hard-coded "skip QAM" branches in ofdm.c.  Phase 6.3a deleted all
 * five; this suite is the regression guard that the encoder/decoder
 * constellation math still agrees with itself.
 *
 * We deliberately do NOT link the real ofdm.c / ARDOPC.c — the TX path
 * needs ALSA, templates, globals, the whole modulator state machine.
 * Instead we duplicate the tiny QAM16 pieces under test, byte-identical
 * to the production code, following the pattern established by
 * test_varsize.  If the production code drifts, the tests will diverge
 * from the observable on-air behaviour; layout invariants below catch
 * that.
 *
 * Tests:
 *   1. test_qam16_frame_info — frame-info table entry for QAM16 matches
 *      ofdm.c:GetOFDMFrameInfo (intDataLen=80, intRSLen=20, Symbols=2,
 *      Mode=8) at the default FECStrengthNPAR=20.
 *   2. test_qam16_npar_split_invariant — the RS split always sums to 100
 *      bytes per carrier regardless of FECStrengthNPAR override (the
 *      "conservation invariant" called out in ofdm.c:GetOFDMFrameInfo).
 *   3. test_qam16_roundtrip_zero_noise — every QAM16 symbol (0..15) maps
 *      through the encoder's differential-phase-plus-magnitude-bit
 *      mapping into a (phase, magnitude) pair that the decoder's
 *      8-wedge quantizer + magnitude threshold recovers exactly.  The
 *      test walks 16 consecutive symbols to exercise the differential
 *      running state.
 *   4. test_qam16_phase_bucket_boundaries — decoder wedge thresholds
 *      (393, 1179, 1965, 2751) map the 8 encoded phase centers (0,
 *      786, 1572, 2358, 3144, -2358, -1572, -786) to the correct
 *      0..7 bucket.
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "unity.h"

/* Phase 6.3b: pull in the real QAM32 constellation + label map.  These are
 * compiled into the ardop-ip binary too; the test binary links against the
 * same qam32_tables.o so any drift fails here AND on-air identically. */
#include "qam32_tables.h"

/* ---- OFDM mode constants mirrored from src/ardopc/ardop2ofdm/ARDOPC.h -- */
#define PSK2   0
#define PSK4   1
#define PSK8   2
#define QAM16  3
#define PSK16  4
#define QAM32  5

/* Phase 6.1c knob — mirrored from ARDOPC.c.  Tests set/reset in setUp. */
static int FECStrengthNPAR = 20;

/* ---- GetOFDMFrameInfo standalone copy for QAM16 --------------------------
 * Mirrors src/ardopc/ardop2ofdm/ofdm.c:GetOFDMFrameInfo() QAM16 arm, plus
 * the Phase 6.1c NPAR-override clamp logic.  If the production version
 * drifts, CI will still link ardop-ip but this test will visibly diverge
 * from on-air behaviour.  Invariant checks below minimise drift risk. */
static void test_GetOFDMFrameInfo_QAM16(int *intDataLen, int *intRSLen,
                                        int *Symbols, int *Mode)
{
    /* QAM16 base split, before NPAR override: 80 data + 20 RS = 100 bytes. */
    *intDataLen = 80;
    *intRSLen   = 20;
    *Symbols    = 2;
    *Mode       = 8;

    /* Phase 6.1c NPAR override: replace RSLen with FECStrengthNPAR,
     * shrink data by the same amount.  Conservation invariant:
     * dataLen + RSLen == 100 (the mode's per-carrier on-air size). */
    int total = *intDataLen + *intRSLen;
    int rs = FECStrengthNPAR;
    if (rs < 4) rs = 4;
    if (rs > total - 4) rs = total - 4;
    *intRSLen = rs;
    *intDataLen = total - rs;
}

/* ---- QAM16 encoder: differential 8-phase + magnitude bit -----------------
 * Lifted byte-identical from the QAM16 branch of EncodeOFDMData() in
 * ofdm.c (symbol-mapping lines near the main loop, post-Phase 6.3a).
 *
 * Input:  `sym` is a 4-bit QAM16 symbol (0..15).  Low 3 bits = phase delta;
 *         bit 3 = magnitude bit.
 * Input:  `prev` is the encoder's per-carrier running accumulator (the
 *         bytLastSym[intCarIndex] & 7 value in ofdm.c).
 * Output: returns the symbol-to-send byte (low 3 bits = absolute phase
 *         bucket 0..7; bit 3 = magnitude bit passed through).
 */
static unsigned char qam16_encode_symbol(unsigned char sym, unsigned char prev)
{
    unsigned char bytSymToSend;
    /* From ofdm.c: bytSymToSend = ((bytLastSym & 7) + (bytSym & 7) & 7);
     * (C operator precedence: + binds tighter than &, so the inner
     * expression is ((prev & 7) + (sym & 7)) & 7 — same as production.) */
    bytSymToSend = (unsigned char)(((prev & 7) + (sym & 7)) & 7);
    /* Magnitude bit: bytSymToSend = bytSymToSend | (bytSym & 8); */
    bytSymToSend = (unsigned char)(bytSymToSend | (sym & 8));
    return bytSymToSend;
}

/* ---- QAM16 decoder: 8-wedge quantizer + magnitude threshold --------------
 * Lifted byte-identical from Decode1CarOFDM() in ofdm.c:1160-1227.  Given
 * a raw phase value (int, in the same units as intPhases[]) and a magnitude
 * comparison result (mag < threshold: 1 = inner circle, 0 = outer) returns
 * a 4-bit absolute symbol value 0..15.  The caller then differentiates
 * against its running previous-absolute-phase to recover the original symbol.
 */
static unsigned char qam16_decode_symbol(int phase, int inner_circle)
{
    unsigned char intData = 0;

    if (phase < 393 && phase > -393)
        ; /* zero bucket */
    else if (phase >= 393 && phase < 1179)
        intData += 1;
    else if (phase >= 1179 && phase < 1965)
        intData += 2;
    else if (phase >= 1965 && phase < 2751)
        intData += 3;
    else if (phase >= 2751 || phase < -2751)
        intData += 4;
    else if (phase >= -2751 && phase < -1965)
        intData += 5;
    else if (phase >= -1965 && phase <= -1179)
        intData += 6;
    else
        intData += 7;

    if (inner_circle)
        intData += 8;

    return intData;
}

/* ---- Phase centers the encoder emits for bucket 0..7 --------------------
 * Unit of intPhases[]: 1/ComputeAng1_Ang2 native.  2π = 6288 (same scale as
 * the decoder's wedge boundaries: 393 ≈ 6288/16 = π/8, which is the
 * boundary between adjacent 45° buckets.)  Bucket centers below are at
 * multiples of 6288/8 = 786.
 */
static int bucket_center_phase(int bucket)
{
    /* 0:0°  1:45°  2:90°  3:135°  4:180°  5:225°(≡-135°)  6:270°(≡-90°)
     * 7:315°(≡-45°) */
    static const int centers[8] = { 0, 786, 1572, 2358, 3144,
                                    -2358, -1572, -786 };
    return centers[bucket & 7];
}

/* ---- setUp / tearDown -------------------------------------------------- */
void setUp(void)    { FECStrengthNPAR = 20; }
void tearDown(void) {}

/* ==========================================================================
 * 1. Frame info lookup for QAM16
 * ========================================================================= */
static void test_qam16_frame_info(void)
{
    int intDataLen = 0, intRSLen = 0, Symbols = 0, Mode = 0;

    /* Default strength (NPAR=20). */
    FECStrengthNPAR = 20;
    test_GetOFDMFrameInfo_QAM16(&intDataLen, &intRSLen, &Symbols, &Mode);
    TEST_ASSERT_EQUAL_INT(80, intDataLen);
    TEST_ASSERT_EQUAL_INT(20, intRSLen);
    TEST_ASSERT_EQUAL_INT(2,  Symbols);
    TEST_ASSERT_EQUAL_INT(8,  Mode);

    /* The QAM16 mode reserves 100 bytes per carrier on-air; intDataLen +
     * intRSLen must always equal 100 regardless of NPAR override. */
    TEST_ASSERT_EQUAL_INT(100, intDataLen + intRSLen);
}

/* ==========================================================================
 * 2. NPAR-override conservation invariant — Phase 6.1c: override changes
 *    the RS/data split but never the total.  Exercises light/normal/strong
 *    and the defensive clamps on either end.
 * ========================================================================= */
static void test_qam16_npar_split_invariant(void)
{
    int intDataLen = 0, intRSLen = 0, Symbols = 0, Mode = 0;
    int strengths[] = { 10, 20, 40 };  /* light / normal / strong */

    for (size_t i = 0; i < sizeof(strengths)/sizeof(strengths[0]); i++) {
        FECStrengthNPAR = strengths[i];
        test_GetOFDMFrameInfo_QAM16(&intDataLen, &intRSLen, &Symbols, &Mode);
        TEST_ASSERT_EQUAL_INT(100, intDataLen + intRSLen);
        TEST_ASSERT_EQUAL_INT(strengths[i], intRSLen);
        TEST_ASSERT_EQUAL_INT(100 - strengths[i], intDataLen);
        TEST_ASSERT_TRUE(intDataLen > 0);
    }

    /* Defensive clamps: absurdly small / large NPAR values stay sane. */
    FECStrengthNPAR = 1;  /* clamps to 4 */
    test_GetOFDMFrameInfo_QAM16(&intDataLen, &intRSLen, &Symbols, &Mode);
    TEST_ASSERT_EQUAL_INT(4,  intRSLen);
    TEST_ASSERT_EQUAL_INT(96, intDataLen);

    FECStrengthNPAR = 200;  /* clamps so data stays >= 4 */
    test_GetOFDMFrameInfo_QAM16(&intDataLen, &intRSLen, &Symbols, &Mode);
    TEST_ASSERT_EQUAL_INT(96, intRSLen);
    TEST_ASSERT_EQUAL_INT(4,  intDataLen);
}

/* ==========================================================================
 * 3. QAM16 zero-noise constellation roundtrip.
 *
 * Drive every 4-bit symbol 0..15 through encoder → channel model →
 * decoder and recover the same value.  The channel model is the ideal
 * one: encoder's absolute 3-bit phase-bucket becomes intPhases[] equal
 * to that bucket's center, and the magnitude-bit becomes the inner-circle
 * flag on the decoder side.
 *
 * Differential phase means the decoder must track its own running prev
 * and subtract.  This also exercises the encoder's running-prev path.
 * ========================================================================= */
static void test_qam16_roundtrip_zero_noise(void)
{
    /* 16-symbol test vector: exercises all magnitude/phase combinations. */
    unsigned char symbols[16];
    for (int i = 0; i < 16; i++) symbols[i] = (unsigned char)i;

    unsigned char enc_prev = 0;   /* encoder running state (absolute phase) */
    unsigned char dec_prev = 0;   /* decoder running state (absolute phase) */

    for (int i = 0; i < 16; i++) {
        unsigned char sym = symbols[i];

        /* Encode: get the absolute on-air symbol. */
        unsigned char on_air = qam16_encode_symbol(sym, enc_prev);

        /* Channel model: phase bucket = on_air & 7, mag-bit = (on_air & 8). */
        int phase = bucket_center_phase(on_air & 7);
        int inner_circle = (on_air & 8) ? 1 : 0;

        /* Decode: recover the absolute symbol. */
        unsigned char abs_dec = qam16_decode_symbol(phase, inner_circle);

        /* Differentiate to recover the original symbol.
         * The decoder in production does this at a higher layer (by
         * subtracting the running last-absolute-phase in Decode1CarOFDM's
         * caller) — we do the equivalent explicitly here. */
        unsigned char recovered_phase =
            (unsigned char)(((abs_dec & 7) - (dec_prev & 7)) & 7);
        unsigned char recovered_sym =
            (unsigned char)(recovered_phase | (abs_dec & 8));

        TEST_ASSERT_EQUAL_UINT8(sym, recovered_sym);

        /* Running absolute state advances for both sides. */
        enc_prev = on_air;
        dec_prev = abs_dec;
    }
}

/* ==========================================================================
 * 4. Decoder phase-bucket wedge boundaries.
 *
 * Each of the 8 bucket centers (0, 786, 1572, 2358, 3144, -2358, -1572,
 * -786) must map to its own 3-bit bucket index.  Also spot-check a few
 * points just inside / just outside the boundaries.
 * ========================================================================= */
static void test_qam16_phase_bucket_boundaries(void)
{
    /* Bucket centers must each land in their own bucket. */
    for (int b = 0; b < 8; b++) {
        int phase = bucket_center_phase(b);
        unsigned char abs_sym = qam16_decode_symbol(phase, 0);
        TEST_ASSERT_EQUAL_UINT8((unsigned char)b, abs_sym & 7);
        /* Magnitude-bit passes through unchanged. */
        abs_sym = qam16_decode_symbol(phase, 1);
        TEST_ASSERT_EQUAL_UINT8((unsigned char)(b | 8), abs_sym);
    }

    /* Boundary cases around the ±π/8 zero-bucket edge. */
    TEST_ASSERT_EQUAL_UINT8(0, qam16_decode_symbol(0,    0));
    TEST_ASSERT_EQUAL_UINT8(0, qam16_decode_symbol(392,  0));
    TEST_ASSERT_EQUAL_UINT8(0, qam16_decode_symbol(-392, 0));
    TEST_ASSERT_EQUAL_UINT8(1, qam16_decode_symbol(393,  0));
    TEST_ASSERT_EQUAL_UINT8(7, qam16_decode_symbol(-393, 0));
}

/* ==========================================================================
 * Phase 6.3b: QAM32 constellation tests
 *
 * These link against the real src/ardopc/ardop2ofdm/qam32_tables.o — the
 * same object file the ardop-ip binary uses — so any drift between the
 * production constellation / labeling and the test expectations is caught
 * at the test level.
 * ========================================================================= */

/* Same 5-byte packing the encoder uses in GetSym32QAM (ofdm.c).  The test
 * duplicates the math rather than linking the full ofdm.o, matching the
 * test_qam pattern of duplicating small pieces of the TX path. */
static uint8_t qam32_extract_symbol(const uint8_t *bytes, int k)
{
    uint64_t w = 0;
    for (int i = 0; i < 5; i++) w = (w << 8) | bytes[i];
    int shift = 5 * (7 - k);
    return (uint8_t)((w >> shift) & 0x1f);
}

/* Test 5: every label in 0..31 appears exactly once. */
static void test_qam32_table_bijective(void)
{
    int seen[32] = {0};
    for (int i = 0; i < 32; i++) {
        uint8_t label = qam32_constellation[i].label;
        TEST_ASSERT_TRUE_MESSAGE(label < 32, "label out of 0..31 range");
        TEST_ASSERT_EQUAL_INT_MESSAGE(0, seen[label],
                                      "duplicate label in qam32_constellation");
        seen[label] = 1;
    }
    for (int l = 0; l < 32; l++) {
        TEST_ASSERT_EQUAL_INT_MESSAGE(1, seen[l],
                                      "missing label in qam32_constellation");
    }
}

/* Test 6: exactly 32 points, all on the odd-coordinate grid minus the
 * 4 corners (+-5, +-5) of the 6x6 grid. */
static void test_qam32_32_points(void)
{
    const float NORM = 1.0f / sqrtf(20.0f);
    for (int i = 0; i < 32; i++) {
        float ir = qam32_constellation[i].i / NORM;  /* back to raw coord */
        float qr = qam32_constellation[i].q / NORM;
        int Ii = (int)lroundf(ir);
        int Qi = (int)lroundf(qr);
        /* I, Q in {-5, -3, -1, 1, 3, 5} */
        TEST_ASSERT_TRUE_MESSAGE(Ii == -5 || Ii == -3 || Ii == -1 ||
                                 Ii ==  1 || Ii ==  3 || Ii ==  5,
                                 "I coordinate not in {+-1, +-3, +-5}");
        TEST_ASSERT_TRUE_MESSAGE(Qi == -5 || Qi == -3 || Qi == -1 ||
                                 Qi ==  1 || Qi ==  3 || Qi ==  5,
                                 "Q coordinate not in {+-1, +-3, +-5}");
        /* No corner points. */
        TEST_ASSERT_FALSE_MESSAGE(abs(Ii) == 5 && abs(Qi) == 5,
                                  "cross-32QAM must not contain corner (+-5,+-5)");
    }
}

/* Test 7: unit average power. */
static void test_qam32_unit_power(void)
{
    double power = 0.0;
    for (int i = 0; i < 32; i++) {
        double I = qam32_constellation[i].i;
        double Q = qam32_constellation[i].q;
        power += I * I + Q * Q;
    }
    double avg = power / 32.0;
    /* Unity may or may not include double asserts depending on build flags;
     * do the comparison by hand for portability. */
    double err = (avg > 1.0) ? (avg - 1.0) : (1.0 - avg);
    char msg[128];
    snprintf(msg, sizeof(msg),
             "average power %.9f must be within 1e-6 of 1.0", avg);
    TEST_ASSERT_TRUE_MESSAGE(err < 1e-6, msg);
}

/* Test 8: quasi-Gray quality — average Hamming distance between
 * Euclidean-adjacent points must be at most 1.5.  Two points are
 * Euclidean-adjacent iff their distance (in raw grid units) is exactly 2
 * (i.e. they differ by +-2 in exactly one of I or Q). */
static void test_qam32_gray_quality(void)
{
    const float NORM = 1.0f / sqrtf(20.0f);
    /* Round to raw coords once. */
    int Ii[32], Qi[32];
    uint8_t Li[32];
    for (int i = 0; i < 32; i++) {
        Ii[i] = (int)lroundf(qam32_constellation[i].i / NORM);
        Qi[i] = (int)lroundf(qam32_constellation[i].q / NORM);
        Li[i] = qam32_constellation[i].label;
    }
    long total_hamming = 0;
    int  edge_count    = 0;
    for (int a = 0; a < 32; a++) {
        for (int b = a + 1; b < 32; b++) {
            int dI = Ii[a] - Ii[b];
            int dQ = Qi[a] - Qi[b];
            int adjacent =
                (dI == 0 && (dQ == 2 || dQ == -2)) ||
                (dQ == 0 && (dI == 2 || dI == -2));
            if (!adjacent) continue;
            uint8_t x = (uint8_t)(Li[a] ^ Li[b]);
            int h = 0;
            while (x) { h += (x & 1); x >>= 1; }
            total_hamming += h;
            edge_count++;
        }
    }
    TEST_ASSERT_TRUE_MESSAGE(edge_count > 0, "no adjacent edges found");
    double avg = (double)total_hamming / (double)edge_count;
    char msg[128];
    snprintf(msg, sizeof(msg),
             "avg Hamming %.3f over %d edges must be <= 1.5", avg, edge_count);
    TEST_ASSERT_TRUE_MESSAGE(avg <= 1.5, msg);
    TEST_ASSERT_TRUE_MESSAGE(avg >= 1.0, "avg Hamming < 1.0 is impossible here");
}

/* Test 9: symbol packing.  Feed a known 5-byte input and verify the 8
 * symbols come out in MSB-first big-endian order. */
static void test_qam32_symbol_packing(void)
{
    /* Hand-built input: bit pattern 11111 00000 11111 00000 11111 00000 11111 00000
     * = 0xF8 0x3E 0x0F 0x83 0xE0
     *
     * Walk:
     *   byte0=0xF8=11111000  byte1=0x3E=00111110  byte2=0x0F=00001111
     *   byte3=0x83=10000011  byte4=0xE0=11100000
     *   concat=11111000 00111110 00001111 10000011 11100000
     *   sym 0 (bits 39..35) = 11111 = 31
     *   sym 1 (bits 34..30) = 00000 = 0
     *   sym 2 (bits 29..25) = 11111 = 31
     *   sym 3 (bits 24..20) = 00000 = 0
     *   sym 4 (bits 19..15) = 11111 = 31
     *   sym 5 (bits 14..10) = 00000 = 0
     *   sym 6 (bits  9..5)  = 11111 = 31
     *   sym 7 (bits  4..0)  = 00000 = 0
     */
    const uint8_t input[5]    = { 0xF8, 0x3E, 0x0F, 0x83, 0xE0 };
    const uint8_t expected[8] = { 31, 0, 31, 0, 31, 0, 31, 0 };
    for (int k = 0; k < 8; k++) {
        TEST_ASSERT_EQUAL_UINT8(expected[k], qam32_extract_symbol(input, k));
    }

    /* Second vector: 0x00 0x84 0x21 0x08 0x42
     * = 00000000 10000100 00100001 00001000 01000010
     * sym 0  = 00000 = 0
     * sym 1  = 00010 = 2
     * sym 2  = 00010 = 2
     * sym 3  = 00010 = 2
     * sym 4  = 00010 = 2
     * sym 5  = 00010 = 2
     * sym 6  = 00010 = 2
     * sym 7  = 00010 = 2
     */
    const uint8_t input2[5]    = { 0x00, 0x84, 0x21, 0x08, 0x42 };
    const uint8_t expected2[8] = { 0, 2, 2, 2, 2, 2, 2, 2 };
    for (int k = 0; k < 8; k++) {
        TEST_ASSERT_EQUAL_UINT8(expected2[k], qam32_extract_symbol(input2, k));
    }
}

/* Test 10: label->IQ round-trip via qam32_map_symbol_to_iq. */
static void test_qam32_map_symbol_to_iq(void)
{
    for (int i = 0; i < 32; i++) {
        uint8_t label = qam32_constellation[i].label;
        float I = 0.0f, Q = 0.0f;
        qam32_map_symbol_to_iq(label, &I, &Q);
        TEST_ASSERT_EQUAL_FLOAT(qam32_constellation[i].i, I);
        TEST_ASSERT_EQUAL_FLOAT(qam32_constellation[i].q, Q);
    }
}

/* -- main --------------------------------------------------------------- */
int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_qam16_frame_info);
    RUN_TEST(test_qam16_npar_split_invariant);
    RUN_TEST(test_qam16_roundtrip_zero_noise);
    RUN_TEST(test_qam16_phase_bucket_boundaries);
    /* Phase 6.3b */
    RUN_TEST(test_qam32_table_bijective);
    RUN_TEST(test_qam32_32_points);
    RUN_TEST(test_qam32_unit_power);
    RUN_TEST(test_qam32_gray_quality);
    RUN_TEST(test_qam32_symbol_packing);
    RUN_TEST(test_qam32_map_symbol_to_iq);
    return UNITY_END();
}
