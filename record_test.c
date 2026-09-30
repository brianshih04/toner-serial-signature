/* Frozen TONER-AUTH v2 byte and SHA-256 vectors; do not regenerate from
 * record.c when testing. These values are independent interoperability data. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <openssl/sha.h>

#include "record.h"

typedef struct {
    uint8_t key_id;
    const char *sn_hex;
    const char *sku;
    char color;
    const char *capacity;
    const char *record_hex;
    const char *sha256_hex;
} TEST_VECTOR;

static const TEST_VECTOR vectors[] = {
    {
        0x01, "0123AABBCCDDEEFFEE", "AV-TONER", 'K', "HC-6500",
        "544f4e45522d415554480201010841562d544f4e45524b0748432d363530300123aabbccddeeffee",
        "7452f2e3effb925176ff19b1be8b9e81bf8f312b286f5a8f16b2da583340ee52"
    },
    {
        0x2A, "0123456789ABCDEF01", "M140TC-C", 'C', "XL",
        "544f4e45522d41555448022a01084d31343054432d434302584c0123456789abcdef01",
        "f7415f2936e2cb57f9c210bc6e5f73fe798e9d2669a05cbaae78e12cd1e6aaa1"
    }
};

static int digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int decode(const char *hex, uint8_t *out, size_t capacity, size_t *out_len)
{
    size_t i, n = strlen(hex);
    if ((n & 1u) != 0 || n / 2u > capacity)
        return 0;
    for (i = 0; i < n / 2u; ++i) {
        int hi = digit(hex[2u * i]), lo = digit(hex[2u * i + 1u]);
        if (hi < 0 || lo < 0)
            return 0;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    *out_len = n / 2u;
    return 1;
}

static int check_vector(const TEST_VECTOR *v)
{
    uint8_t sn[TONER_SN_SIZE], record[TONER_RECORD_MAX_SIZE];
    uint8_t expected[TONER_RECORD_MAX_SIZE], digest[SHA256_DIGEST_LENGTH];
    uint8_t expected_digest[SHA256_DIGEST_LENGTH];
    size_t sn_len, record_len, expected_len, expected_digest_len;

    if (!decode(v->sn_hex, sn, sizeof(sn), &sn_len) || sn_len != sizeof(sn) ||
        !toner_record_encode(v->key_id, sn, v->sku, strlen(v->sku),
                             v->color, v->capacity, strlen(v->capacity),
                             record, sizeof(record), &record_len) ||
        !decode(v->record_hex, expected, sizeof(expected), &expected_len) ||
        record_len != expected_len || memcmp(record, expected, record_len) != 0 ||
        !decode(v->sha256_hex, expected_digest, sizeof(expected_digest),
                &expected_digest_len) ||
        expected_digest_len != sizeof(digest) ||
        SHA256(record, record_len, digest) == NULL ||
        memcmp(digest, expected_digest, sizeof(digest)) != 0)
        return 0;
    return 1;
}

int main(void)
{
    uint8_t sn[TONER_SN_SIZE] = {0};
    uint8_t out[TONER_RECORD_MAX_SIZE];
    size_t i, out_len = 99;

    for (i = 0; i < sizeof(vectors) / sizeof(vectors[0]); ++i) {
        if (!check_vector(&vectors[i])) {
            fprintf(stderr, "golden vector %zu FAILED\n", i + 1u);
            return 1;
        }
    }
    if (toner_record_encode(0, sn, "SKU", 3, 'K', "XL", 2,
                            out, sizeof(out), &out_len) || out_len != 0 ||
        toner_record_encode(1, sn, "SKU", 3, 'Z', "XL", 2,
                            out, sizeof(out), &out_len) || out_len != 0 ||
        toner_record_encode(1, sn, "SKU", 3, 'K', "XL", 2,
                            out, 1, &out_len) || out_len != 0 ||
        toner_record_encode(1, sn, "S KU", 4, 'K', "XL", 2,
                            out, sizeof(out), &out_len) || out_len != 0) {
        fprintf(stderr, "invalid-field rejection FAILED\n");
        return 1;
    }
    printf("%zu golden record/hash vectors and invalid-field cases PASS\n",
           sizeof(vectors) / sizeof(vectors[0]));
    return 0;
}
