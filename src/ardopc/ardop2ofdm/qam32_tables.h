/*
 * qam32_tables.h — Phase 6.3b: cross-32QAM constellation + quasi-Gray
 *                  labeling.  See qam32_tables.c for design notes.
 */
#ifndef QAM32_TABLES_H
#define QAM32_TABLES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float   i;       /* in-phase (normalized to unit avg power)     */
    float   q;       /* quadrature (normalized to unit avg power)   */
    uint8_t label;   /* 5-bit quasi-Gray label, values 0..31 unique */
} qam32_point_t;

/* 32 entries, indexed in a natural geometric order.  The `label` field
 * carries the bit pattern; use qam32_map_symbol_to_iq() to go the other
 * direction.  See qam32_tables.c for the geometry and labeling derivation. */
extern const qam32_point_t qam32_constellation[32];

/* Map a 5-bit symbol value (0..31) to its (I, Q) constellation point.
 * Low 5 bits only — upper bits are masked off defensively. */
void qam32_map_symbol_to_iq(uint8_t symbol, float *i_out, float *q_out);

#ifdef __cplusplus
}
#endif

#endif /* QAM32_TABLES_H */
