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

#define MY_NPAR   16    /* 8-symbol correction capacity */
#define DATA_LEN  100   /* message bytes */

/* -- setUp / tearDown ------------------------------------------------------ */

void setUp(void)    {}
void tearDown(void) {}

/* -- Helpers: mirror RSEncode/RSDecode from ARDOPC.c ----------------------- */

/*
 * Encode data[0..data_len-1] and write MY_NPAR parity bytes to
 * codeword[data_len..data_len+MY_NPAR-1].  codeword[0..data_len-1] is filled
 * with a copy of data.
 */
static void rs_encode(const uint8_t *data, int data_len, uint8_t *codeword)
{
    int pad_len = 255 - data_len - MY_NPAR;
    uint8_t padded[256];
    memset(padded, 0, pad_len);
    memcpy(padded + pad_len, data, data_len);

    NPAR      = MY_NPAR;
    MaxErrors = MY_NPAR / 2;
    initialize_ecc();

    encode_data(padded, 255 - MY_NPAR, codeword + data_len);
    memcpy(codeword, data, data_len);
}

/*
 * Decode codeword in place (mirrors RSDecode from ARDOPC.c).
 * codeword layout: [data (data_len bytes)] [parity (MY_NPAR bytes)]
 *
 * Returns 1 if codeword was clean or corrections succeeded.
 * Returns 0 if uncorrectable.
 * On success, codeword[0..data_len-1] holds corrected data.
 */
static int rs_decode(uint8_t *codeword, int data_len)
{
    int total   = data_len + MY_NPAR;
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
    for (i = 0; i < MY_NPAR; i++)
        *out++ = *src--;

    if (NPAR != MY_NPAR) {
        NPAR      = MY_NPAR;
        MaxErrors = MY_NPAR / 2;
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

/* -- Main ------------------------------------------------------------------ */

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_fec_roundtrip);
    RUN_TEST(test_fec_single_bit_error);
    RUN_TEST(test_fec_burst_error);
    RUN_TEST(test_fec_uncorrectable);
    return UNITY_END();
}
