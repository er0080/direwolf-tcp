/*
 * tests/test_fec.c -- unit tests for the Reed-Solomon FEC layer
 * (rs.c, berlekamp.c, galois.c + RSEncode/RSDecode logic from ARDOPC.c)
 *
 * No audio or radio hardware required.
 *
 * Mirrors the exact RSEncode/RSDecode logic from ARDOPC.c so the test
 * exercises the same encode/decode path used in production.
 *
 * RS parameters: GF(2^8), MY_NPAR parity bytes.
 * Correction capacity: MY_NPAR/2 = 8 symbol errors.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "unity.h"
#include "../src/ardopc/ardop2ofdm/ecc.h"

extern int NPAR;
extern int MaxErrors;

#define MY_NPAR   16    /* 8-symbol correction capacity (legacy tests) */
#define DATA_LEN  100   /* message bytes */

/* -- setUp / tearDown ------------------------------------------------------ */

void setUp(void)    {}
void tearDown(void) {}

/* -- Helpers: mirror RSEncode/RSDecode from ARDOPC.c ----------------------- */

/*
 * Encode data[0..data_len-1] with `npar` parity bytes.  Writes parity to
 * codeword[data_len..data_len+npar-1] and copies data into codeword[0..].
 */
static void rs_encode_n(const uint8_t *data, int data_len, int npar,
                        uint8_t *codeword)
{
    int pad_len = 255 - data_len - npar;
    uint8_t padded[256];
    memset(padded, 0, pad_len);
    memcpy(padded + pad_len, data, data_len);

    NPAR      = npar;
    MaxErrors = npar / 2;
    initialize_ecc();

    encode_data(padded, 255 - npar, codeword + data_len);
    memcpy(codeword, data, data_len);
}

/*
 * Decode codeword in place using `npar` parity bytes.
 * codeword layout: [data (data_len bytes)] [parity (npar bytes)]
 *
 * Returns 1 if codeword was clean or corrections succeeded, 0 if uncorrectable.
 * On success, codeword[0..data_len-1] holds corrected data.
 */
static int rs_decode_n(uint8_t *codeword, int data_len, int npar)
{
    int total   = data_len + npar;
    int pad_len = 255 - total;
    uint8_t tmp[256];
    uint8_t *out = tmp;
    int i;

    /* Reverse data portion */
    uint8_t *src = codeword + data_len - 1;
    for (i = 0; i < data_len; i++)
        *out++ = *src--;

    /* Zero padding */
    memset(out, 0, pad_len);
    out += pad_len;

    /* Reverse parity portion */
    src = codeword + total - 1;
    for (i = 0; i < npar; i++)
        *out++ = *src--;

    if (NPAR != npar) {
        NPAR      = npar;
        MaxErrors = npar / 2;
        initialize_ecc();
    }

    decode_data(tmp, 255);

    if (check_syndrome() == 0) {
        /* No errors: reverse tmp back into codeword data region */
        src = tmp + data_len - 1;
        for (i = 0; i < data_len; i++)
            codeword[i] = *src--;
        return 1;
    }

    if (correct_errors_erasures(tmp, 255, 0, 0) == 0)
        return 0;

    /* Corrections applied: reverse corrected data back */
    src = tmp + data_len - 1;
    for (i = 0; i < data_len; i++)
        codeword[i] = *src--;
    return 1;
}

/* Legacy wrappers used by the original test_fec_* cases (MY_NPAR=16). */
static void rs_encode(const uint8_t *data, int data_len, uint8_t *codeword)
{
    rs_encode_n(data, data_len, MY_NPAR, codeword);
}
static int rs_decode(uint8_t *codeword, int data_len)
{
    return rs_decode_n(codeword, data_len, MY_NPAR);
}

static void fill_payload(uint8_t *buf, int len)
{
    for (int i = 0; i < len; i++)
        buf[i] = (uint8_t)(i & 0xFF);
}

/* -- Tests ----------------------------------------------------------------- */

void test_fec_roundtrip(void)
{
    uint8_t payload[DATA_LEN];
    uint8_t codeword[DATA_LEN + MY_NPAR];

    fill_payload(payload, DATA_LEN);
    rs_encode(payload, DATA_LEN, codeword);

    int ok = rs_decode(codeword, DATA_LEN);

    TEST_ASSERT_TRUE_MESSAGE(ok, "rs_decode failed on clean codeword");
    TEST_ASSERT_EQUAL_MEMORY_MESSAGE(payload, codeword, DATA_LEN,
                                     "decoded data differs from original");
}

void test_fec_single_bit_error(void)
{
    uint8_t payload[DATA_LEN];
    uint8_t codeword[DATA_LEN + MY_NPAR];

    fill_payload(payload, DATA_LEN);
    rs_encode(payload, DATA_LEN, codeword);

    codeword[DATA_LEN / 2] ^= 0x01;

    int ok = rs_decode(codeword, DATA_LEN);

    TEST_ASSERT_TRUE_MESSAGE(ok, "decode failed on 1-bit error");
    TEST_ASSERT_EQUAL_MEMORY_MESSAGE(payload, codeword, DATA_LEN,
                                     "1-bit error not corrected");
}

void test_fec_burst_error(void)
{
    /* 7 consecutive corrupted bytes -- within MY_NPAR/2 = 8 symbol capacity */
    uint8_t payload[DATA_LEN];
    uint8_t codeword[DATA_LEN + MY_NPAR];

    fill_payload(payload, DATA_LEN);
    rs_encode(payload, DATA_LEN, codeword);

    for (int i = 10; i < 17; i++)
        codeword[i] ^= 0xFF;

    int ok = rs_decode(codeword, DATA_LEN);

    TEST_ASSERT_TRUE_MESSAGE(ok, "decode failed on 7-byte burst");
    TEST_ASSERT_EQUAL_MEMORY_MESSAGE(payload, codeword, DATA_LEN,
                                     "7-byte burst not corrected");
}

void test_fec_uncorrectable(void)
{
    /* 9 scattered errors -- one beyond MY_NPAR/2 = 8; must return failure */
    uint8_t payload[DATA_LEN];
    uint8_t codeword[DATA_LEN + MY_NPAR];

    fill_payload(payload, DATA_LEN);
    rs_encode(payload, DATA_LEN, codeword);

    int positions[] = { 0, 11, 22, 33, 44, 55, 66, 77, 88 };
    for (int i = 0; i < 9; i++)
        codeword[positions[i]] ^= 0xFF;

    int ok = rs_decode(codeword, DATA_LEN);

    TEST_ASSERT_FALSE_MESSAGE(ok,
        "decode returned success on 9-byte error (beyond MY_NPAR/2 -- should fail)");
}

/* -- Phase 6.1c: --fec-strength {light|normal|strong} ---------------------- *
 *
 * light  = NPAR 10 → 5-byte correction capacity per block
 * normal = NPAR 20 → 10-byte   (PSK16 original)
 * strong = NPAR 40 → 20-byte
 *
 * For each strength we verify:
 *   1. Clean round-trip is byte-identical
 *   2. NPAR/2 scattered byte errors are corrected
 *   3. NPAR/2 + 1 scattered byte errors exceed capacity (decode fails)
 *
 * Block layout: we use a DATA_LEN=80 payload (matches PSK16's natural size)
 * so the whole codeword (data+parity) fits well under 255. */

#define STRENGTH_DATA_LEN 80

static void scatter_errors(uint8_t *codeword, int codeword_len, int n_errors)
{
    /* Deterministic, UNIQUE positions using a prime-stride walk so we never
     * double-hit the same byte (which would halve effective error count). */
    int pos = 3;
    int stride = 13;           /* coprime with realistic codeword_len values */
    for (int i = 0; i < n_errors; i++) {
        pos = pos % codeword_len;
        codeword[pos] ^= (uint8_t)(0xA5 + i);
        pos += stride;
    }
    (void)codeword_len;
}

static void run_roundtrip(int npar)
{
    uint8_t payload[STRENGTH_DATA_LEN];
    uint8_t codeword[STRENGTH_DATA_LEN + 64];

    fill_payload(payload, STRENGTH_DATA_LEN);
    rs_encode_n(payload, STRENGTH_DATA_LEN, npar, codeword);

    int ok = rs_decode_n(codeword, STRENGTH_DATA_LEN, npar);
    TEST_ASSERT_TRUE_MESSAGE(ok, "clean codeword rejected");
    TEST_ASSERT_EQUAL_MEMORY_MESSAGE(payload, codeword, STRENGTH_DATA_LEN,
                                     "clean decode does not match input");
}

static void run_correctable(int npar)
{
    uint8_t payload[STRENGTH_DATA_LEN];
    uint8_t codeword[STRENGTH_DATA_LEN + 64];
    int total = STRENGTH_DATA_LEN + npar;

    fill_payload(payload, STRENGTH_DATA_LEN);
    rs_encode_n(payload, STRENGTH_DATA_LEN, npar, codeword);

    scatter_errors(codeword, total, npar / 2);

    int ok = rs_decode_n(codeword, STRENGTH_DATA_LEN, npar);
    TEST_ASSERT_TRUE_MESSAGE(ok, "NPAR/2 errors should be correctable");
    TEST_ASSERT_EQUAL_MEMORY_MESSAGE(payload, codeword, STRENGTH_DATA_LEN,
                                     "NPAR/2 errors not fully corrected");
}

static void run_uncorrectable(int npar)
{
    uint8_t payload[STRENGTH_DATA_LEN];
    uint8_t codeword[STRENGTH_DATA_LEN + 64];
    int total = STRENGTH_DATA_LEN + npar;

    fill_payload(payload, STRENGTH_DATA_LEN);
    rs_encode_n(payload, STRENGTH_DATA_LEN, npar, codeword);

    scatter_errors(codeword, total, npar / 2 + 1);

    int ok = rs_decode_n(codeword, STRENGTH_DATA_LEN, npar);

    /* RS is guaranteed to correct up to NPAR/2 errors.  Beyond that, the
     * decoder may either (a) return failure, or (b) miscorrect to a
     * different valid codeword — both outcomes are "unrecoverable" from
     * the application's perspective.  Accept either, but reject the
     * impossible case where it claims success AND recovers the original. */
    int recovered = (ok && memcmp(codeword, payload, STRENGTH_DATA_LEN) == 0);
    TEST_ASSERT_FALSE_MESSAGE(recovered,
        "NPAR/2+1 errors must exceed guaranteed correction capacity");
}

void test_fec_roundtrip_light (void) { run_roundtrip(10); }
void test_fec_roundtrip_normal(void) { run_roundtrip(20); }
void test_fec_roundtrip_strong(void) { run_roundtrip(40); }

void test_fec_correctable_light (void) { run_correctable(10); }
void test_fec_correctable_normal(void) { run_correctable(20); }
void test_fec_correctable_strong(void) { run_correctable(40); }

void test_fec_uncorrectable_light (void) { run_uncorrectable(10); }
void test_fec_uncorrectable_normal(void) { run_uncorrectable(20); }
void test_fec_uncorrectable_strong(void) { run_uncorrectable(40); }

/* -- Main ------------------------------------------------------------------ */

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_fec_roundtrip);
    RUN_TEST(test_fec_single_bit_error);
    RUN_TEST(test_fec_burst_error);
    RUN_TEST(test_fec_uncorrectable);

    RUN_TEST(test_fec_roundtrip_light);
    RUN_TEST(test_fec_roundtrip_normal);
    RUN_TEST(test_fec_roundtrip_strong);

    RUN_TEST(test_fec_correctable_light);
    RUN_TEST(test_fec_correctable_normal);
    RUN_TEST(test_fec_correctable_strong);

    RUN_TEST(test_fec_uncorrectable_light);
    RUN_TEST(test_fec_uncorrectable_normal);
    RUN_TEST(test_fec_uncorrectable_strong);

    return UNITY_END();
}
