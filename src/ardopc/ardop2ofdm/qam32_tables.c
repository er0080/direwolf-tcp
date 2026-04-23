/*
 * qam32_tables.c — Phase 6.3b: cross-32QAM constellation and quasi-Gray
 *                  labeling for ardop-ip.
 *
 * Geometry
 * --------
 * Standard cross-32QAM: start from the 6x6 grid of points at odd integer
 * coordinates I, Q in {-5, -3, -1, +1, +3, +5}, then remove the 4 corners
 * (+-5, +-5).  32 points remain.
 *
 * Average power of the raw (unscaled) constellation:
 *
 *     sum_{p in C} (I_p^2 + Q_p^2)
 *     = (6 * sum_I I^2) + (6 * sum_Q Q^2) - 4 * (5^2 + 5^2)
 *     = 6 * 70 + 6 * 70 - 4 * 50
 *     = 840 - 200
 *     = 640
 *
 *     mean_power = 640 / 32 = 20
 *     norm       = 1 / sqrt(20) ~ 0.223606797749979
 *
 * We bake this into the constellation so the stored (i, q) pairs have
 * unit average power.  Tests check this to 1e-6.
 *
 * Labeling (quasi-Gray, ad-hoc Smith-style)
 * -----------------------------------------
 * The 5-bit label is split:
 *
 *     bit 4..3 : quadrant code, itself 2-bit Gray across the 4 quadrants:
 *                Q1 (+I,+Q) = 00
 *                Q2 (-I,+Q) = 01
 *                Q3 (-I,-Q) = 11
 *                Q4 (+I,-Q) = 10
 *
 *     bit 2..0 : within-quadrant 3-bit label, keyed on the (|I|, |Q|)
 *                tuple.  Ordering was chosen by walking a Hamiltonian path
 *                through the 8 points of one quadrant where each step is
 *                Euclidean-adjacent (distance 2) AND Hamming-1:
 *
 *                (1,1)=000 -> (1,3)=001 -> (1,5)=011 -> (3,5)=010
 *                -> (3,3)=110 -> (3,1)=100 -> (5,1)=101 -> (5,3)=111
 *
 *                This leaves two Euclidean-adjacent pairs within a quadrant
 *                with Hamming-distance > 1: (1,1)-(3,1) and (1,3)-(3,3)
 *                have distance 1, but (1,5)-(3,5) = 011-010 = 1, (3,1)-(5,1)
 *                = 100-101 = 1, (5,1)-(5,3) = 101-111 = 1.  The worst edge
 *                left over is (1,3)-(3,3) = 001-110 = Hamming 3, which the
 *                Gray-quality test tolerates because the average over all
 *                Euclidean-adjacent edges is well under 1.5 (see
 *                tests/test_qam.c:test_qam32_gray_quality).
 *
 * Cross-quadrant Euclidean neighbours (e.g. (1,1) in Q1 and (-1,1) in Q2)
 * get Hamming distance 1 "for free" because the MSB pair is Gray-coded and
 * the 3 LSBs are identical (they depend only on |I|, |Q|).
 *
 * References
 * ----------
 * Cross-QAM geometry: any standard modulation textbook (e.g. Proakis,
 * "Digital Communications", cross-type QAM section).  The labeling here is
 * an ad-hoc quasi-Gray — it is NOT the exact scheme of Smith (1975) nor the
 * BICM-optimized scheme in Li & Kim, "Design of a Labeling Scheme for
 * 32-QAM Delayed Bit-Interleaved Coded Modulation" (MDPI Sensors, 2020,
 * doi:10.3390/s20123528), but it meets the minimum quasi-Gray property
 * (average Euclidean-adjacent Hamming distance below 1.5).  A more
 * optimized labeling is a candidate for future work once the decoder
 * (Phase 6.3c) is in place to measure BER impact directly.
 */

#include <stdint.h>
#include "qam32_tables.h"

/* Normalization factor: 1 / sqrt(20), to 17 significant digits.  The
 * constellation entries below are the raw (I, Q) coordinates in
 * {-5, -3, -1, 1, 3, 5} multiplied by this factor.  Computed here as a
 * compile-time constant so the resulting floats are identical on every
 * build; the test suite re-derives it and asserts unit power to 1e-6. */
#define QAM32_NORM (0.22360679774997896964f)    /* 1.0 / sqrt(20)        */

/* Convenience: short macros so the table below is readable. */
#define N QAM32_NORM
#define P(I, Q, L) { (float)(I) * N, (float)(Q) * N, (uint8_t)(L) }

const qam32_point_t qam32_constellation[32] = {
    /* ---- Q1  (+I, +Q) -- MSBs = 00 ---- */
    P( 1,  1, 0x00 | 0 /*000*/),   /* 0 */
    P( 1,  3, 0x00 | 1 /*001*/),   /* 1 */
    P( 1,  5, 0x00 | 3 /*011*/),   /* 2 */
    P( 3,  5, 0x00 | 2 /*010*/),   /* 3 */
    P( 3,  3, 0x00 | 6 /*110*/),   /* 4 */
    P( 3,  1, 0x00 | 4 /*100*/),   /* 5 */
    P( 5,  1, 0x00 | 5 /*101*/),   /* 6 */
    P( 5,  3, 0x00 | 7 /*111*/),   /* 7 */

    /* ---- Q2  (-I, +Q) -- MSBs = 01 ---- */
    P(-1,  1, 0x08 | 0),           /* 8 */
    P(-1,  3, 0x08 | 1),           /* 9 */
    P(-1,  5, 0x08 | 3),           /* 10 */
    P(-3,  5, 0x08 | 2),           /* 11 */
    P(-3,  3, 0x08 | 6),           /* 12 */
    P(-3,  1, 0x08 | 4),           /* 13 */
    P(-5,  1, 0x08 | 5),           /* 14 */
    P(-5,  3, 0x08 | 7),           /* 15 */

    /* ---- Q3  (-I, -Q) -- MSBs = 11 ---- */
    P(-1, -1, 0x18 | 0),           /* 16 */
    P(-1, -3, 0x18 | 1),           /* 17 */
    P(-1, -5, 0x18 | 3),           /* 18 */
    P(-3, -5, 0x18 | 2),           /* 19 */
    P(-3, -3, 0x18 | 6),           /* 20 */
    P(-3, -1, 0x18 | 4),           /* 21 */
    P(-5, -1, 0x18 | 5),           /* 22 */
    P(-5, -3, 0x18 | 7),           /* 23 */

    /* ---- Q4  (+I, -Q) -- MSBs = 10 ---- */
    P( 1, -1, 0x10 | 0),           /* 24 */
    P( 1, -3, 0x10 | 1),           /* 25 */
    P( 1, -5, 0x10 | 3),           /* 26 */
    P( 3, -5, 0x10 | 2),           /* 27 */
    P( 3, -3, 0x10 | 6),           /* 28 */
    P( 3, -1, 0x10 | 4),           /* 29 */
    P( 5, -1, 0x10 | 5),           /* 30 */
    P( 5, -3, 0x10 | 7),           /* 31 */
};

#undef N
#undef P

/* Inverse map: label (0..31) -> index into qam32_constellation[].
 * Built lazily on first call; O(1) thereafter.  The encoder calls this
 * in its inner sample loop so the lookup must be cheap. */
static uint8_t label_to_index_tbl[32];
static int label_to_index_built = 0;

static void qam32_build_label_to_index(void)
{
    int i;
    for (i = 0; i < 32; i++)
        label_to_index_tbl[qam32_constellation[i].label] = (uint8_t)i;
    label_to_index_built = 1;
}

void qam32_map_symbol_to_iq(uint8_t symbol, float *i_out, float *q_out)
{
    if (!label_to_index_built)
        qam32_build_label_to_index();

    symbol &= 0x1f;   /* clamp to 5 bits — defensive */
    const qam32_point_t *p = &qam32_constellation[label_to_index_tbl[symbol]];
    *i_out = p->i;
    *q_out = p->q;
}
