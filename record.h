#ifndef TONER_AUTH_RECORD_H
#define TONER_AUTH_RECORD_H

#include <stddef.h>
#include <stdint.h>

/* Frozen TONER-AUTH v2 transcript. Change version for ANY wire-format change. */
#define TONER_AUTH_VERSION 2u
#define TONER_CHIP_ATSHA204A 1u
#define TONER_SN_SIZE 9u
#define TONER_MAX_SKU_SIZE 64u
#define TONER_MAX_CAPACITY_SIZE 32u
#define TONER_RECORD_MAX_SIZE 121u

/* key_id 0 is reserved. Color is one ASCII byte: K/C/M/Y.
 * SKU and capacity_code are exact printable-ASCII bytes (0x21..0x7e),
 * explicitly length-delimited, with no case folding or NUL in the record.
 * The caller must source sn from the LIVE chip configuration read. */
int toner_record_encode(uint8_t key_id,
                        const uint8_t sn[TONER_SN_SIZE],
                        const char *sku, size_t sku_len,
                        char color,
                        const char *capacity_code, size_t capacity_len,
                        uint8_t *out, size_t out_capacity,
                        size_t *out_len);

#endif
