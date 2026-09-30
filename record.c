#include "record.h"

#include <string.h>

/* No trailing NUL in the signed transcript. Exact layout:
 * ASCII "TONER-AUTH" (10) | version (1) | key_id (1) |
 * chip_model=ATSHA204A (1) | sku_len (1) | sku (sku_len) |
 * color (1) | capacity_len (1) | capacity_code (capacity_len) | SN (9).
 * The 64-byte ECDSA signature is stored separately; it is NOT part of M. */
static const uint8_t domain[] = "TONER-AUTH";

static int printable_ascii(const char *data, size_t length)
{
    size_t i;
    for (i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)data[i];
        if (c < 0x21 || c > 0x7e)
            return 0;
    }
    return 1;
}

int toner_record_encode(uint8_t key_id,
                        const uint8_t sn[TONER_SN_SIZE],
                        const char *sku, size_t sku_len,
                        char color,
                        const char *capacity_code, size_t capacity_len,
                        uint8_t *out, size_t out_capacity,
                        size_t *out_len)
{
    size_t pos = 0;
    size_t needed = (sizeof(domain) - 1u) + 1u + 1u + 1u + 1u +
                    sku_len + 1u + 1u + capacity_len + TONER_SN_SIZE;

    if (out_len != NULL)
        *out_len = 0;
    if (key_id == 0 || sn == NULL || sku == NULL || capacity_code == NULL ||
        out == NULL || out_len == NULL ||
        sku_len == 0 || sku_len > TONER_MAX_SKU_SIZE ||
        capacity_len == 0 || capacity_len > TONER_MAX_CAPACITY_SIZE ||
        (color != 'K' && color != 'C' && color != 'M' && color != 'Y') ||
        needed > out_capacity || !printable_ascii(sku, sku_len) ||
        !printable_ascii(capacity_code, capacity_len))
        return 0;

    memcpy(out + pos, domain, sizeof(domain) - 1u);
    pos += sizeof(domain) - 1u;
    out[pos++] = TONER_AUTH_VERSION;
    out[pos++] = key_id;
    out[pos++] = TONER_CHIP_ATSHA204A;
    out[pos++] = (uint8_t)sku_len;
    memcpy(out + pos, sku, sku_len);
    pos += sku_len;
    out[pos++] = (uint8_t)color;
    out[pos++] = (uint8_t)capacity_len;
    memcpy(out + pos, capacity_code, capacity_len);
    pos += capacity_len;
    memcpy(out + pos, sn, TONER_SN_SIZE);
    pos += TONER_SN_SIZE;
    *out_len = pos;
    return 1;
}
