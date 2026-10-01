/*
 * Verifier reference for the shared TONER-AUTH v2 record. The public key
 * must be pinned/trusted by firmware (selected by the signed key_id), never
 * supplied by the cartridge. Keep the existing ATSHA204A live MAC check as a
 * separate requirement: this static signature alone cannot defeat chip
 * emulation or relay.
 *
 * Compatibility target: OpenSSL 1.0.2o through 3.x. Integrators must still
 * verify the actual firmware crypto library on target hardware.
 *  - ECDSA_SIG_set0/get0, BN_bn2binpad, EVP_PKEY_is_a, core_names.h and
 *    provider parameter queries are 1.1.0/3.x-only and must not appear here.
 *  - On 1.1.x/3.x the classic APIs still work but are deprecated and
 *    ECDSA_SIG is opaque, so r/s access goes through ECDSA_SIG_set0()
 *    behind an OPENSSL_VERSION_NUMBER check; build there with
 *    -Wno-deprecated-declarations.
 *
 * Test keyring: TRUSTED_KEY_DIR/key-XX.pem, where XX is the signed key ID.
 * Only this one key is tried; missing/revoked IDs fail closed. The directory
 * must be trusted host storage. Firmware must use a pinned ID->key table.
 * Build: cc -std=c11 -Wall -Wextra -Werror verify.c record.c -o verify -lcrypto
 * Usage: ./verify TRUSTED_KEY_DIR KEY_ID_HEX SN18HEX SKU COLOR CAPACITY_CODE signature.bin
 * Exit: 0 valid, 2 invalid signature/record, 1 I/O or setup error.
 * Firmware integration: SN must come from the LIVE chip configuration read
 * (config bytes 0-3 and 8-12), never from cartridge data slots.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/opensslv.h>
#include <openssl/pem.h>
#include <openssl/sha.h>

#include "record.h"
#include "ui.h"

enum { RAW_SIG_SIZE = 64 };

static int hex_digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Must stay identical to the copy in sign.c: the hex CLI wrappers are
 * test scaffolding only; the signed bytes come from the shared record.c. */
static int parse_hex(const char *hex, size_t out_len, uint8_t *out)
{
    size_t i;
    if (strlen(hex) != out_len * 2u)
        return 0;
    for (i = 0; i < out_len; ++i) {
        int hi = hex_digit(hex[2 * i]);
        int lo = hex_digit(hex[2 * i + 1]);
        if (hi < 0 || lo < 0)
            return 0;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return 1;
}

/* get1 is available in OpenSSL 1.0.2 and returns an owned reference. */
static EC_KEY *get_p256_key(EVP_PKEY *key)
{
    EC_KEY *ec;
    const EC_GROUP *group;

    ec = EVP_PKEY_get1_EC_KEY(key);
    if (ec == NULL) {
        ERR_print_errors_fp(stderr);
        return NULL;
    }
    group = EC_KEY_get0_group(ec);
    if (group == NULL || EC_GROUP_get_curve_name(group) != NID_X9_62_prime256v1) {
        fprintf(stderr, "EC 金鑰曲線錯誤或未命名（NID=%d）。\n",
                group == NULL ? 0 : EC_GROUP_get_curve_name(group));
        EC_KEY_free(ec);
        return NULL;
    }
    return ec;
}

int main(int argc, char **argv)
{
    uint8_t key_id, sn[TONER_SN_SIZE];
    unsigned char record[TONER_RECORD_MAX_SIZE];
    unsigned char digest[SHA256_DIGEST_LENGTH];
    unsigned char raw[RAW_SIG_SIZE];
    char key_path[1024];
    size_t record_len = 0;
    int path_len, verdict, result = 1;
    BIGNUM *r = NULL, *s = NULL;
    ECDSA_SIG *sig = NULL;
    EC_KEY *ec = NULL;
    EVP_PKEY *key = NULL;
    FILE *in = NULL;

    toner_ui_init();

    if (argc != 8) {
        fprintf(stderr, "用法：%s TRUSTED_KEY_DIR KEY_ID_HEX SN18HEX SKU COLOR CAPACITY_CODE signature.bin\n", argv[0]);
        return 1;
    }
    if (!parse_hex(argv[2], 1, &key_id) ||
        !parse_hex(argv[3], TONER_SN_SIZE, sn) ||
        !toner_record_encode(key_id, sn, argv[4], strlen(argv[4]),
                             argv[5][0] != '\0' && argv[5][1] == '\0' ? argv[5][0] : '\0',
                             argv[6], strlen(argv[6]),
                             record, sizeof(record), &record_len)) {
        puts("驗證失敗：紀錄欄位格式不正確");
        return 2;
    }

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    OpenSSL_add_all_algorithms();
#endif

    in = fopen(argv[7], "rb");
    if (in == NULL) {
        fprintf(stderr, "無法開啟簽章檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    if (fread(raw, 1, sizeof(raw), in) != sizeof(raw) ||
        fgetc(in) != EOF || ferror(in)) {
        puts("驗證失敗：簽章長度必須恰好為 64 位元組");
        result = 2;
        goto done;
    }
    fclose(in);
    in = NULL;

    /* key_id is untrusted metadata, used only as an exact lookup selector.
     * The keyring is trusted host state, not cartridge-supplied data. */
    path_len = snprintf(key_path, sizeof(key_path), "%s/key-%02X.pem", argv[1], key_id);
    if (path_len < 0 || (size_t)path_len >= sizeof(key_path)) {
        fprintf(stderr, "受信任公鑰目錄路徑過長。\n");
        goto done;
    }
    in = fopen(key_path, "rb");
    if (in == NULL) {
        if (errno == ENOENT) {
            puts("驗證失敗：金鑰 ID 不在有效的受信任公鑰表中");
            result = 2;
        } else {
            fprintf(stderr, "無法開啟受信任公鑰檔案（錯誤碼 %d）。\n", errno);
        }
        goto done;
    }
    key = PEM_read_PUBKEY(in, NULL, NULL, NULL);
    fclose(in);
    in = NULL;
    if (key == NULL)
        goto crypto_error;
    ec = get_p256_key(key);        /* Owned reference; free below. */
    if (ec == NULL) {
        fprintf(stderr, "公鑰必須使用 EC P-256。\n");
        goto done;
    }

    sig = ECDSA_SIG_new();
    if (sig == NULL)
        goto crypto_error;
#if OPENSSL_VERSION_NUMBER >= 0x10100000L
    r = BN_bin2bn(raw, 32, NULL);
    s = BN_bin2bn(raw + 32, 32, NULL);
    if (r == NULL || s == NULL)
        goto crypto_error;
    if (ECDSA_SIG_set0(sig, r, s) != 1)   /* struct opaque since 1.1.0 */
        goto crypto_error;
    r = s = NULL;                  /* sig owns r/s now. */
#else
    /* 1.0.2 ECDSA_SIG_new() already allocated r/s. Reuse them; assigning
     * fresh BIGNUMs here would leak both existing components. */
    if (sig->r == NULL || sig->s == NULL ||
        BN_bin2bn(raw, 32, sig->r) == NULL ||
        BN_bin2bn(raw + 32, 32, sig->s) == NULL)
        goto crypto_error;
#endif

    if (SHA256(record, record_len, digest) == NULL)
        goto crypto_error;
    verdict = ECDSA_do_verify(digest, SHA256_DIGEST_LENGTH, sig, ec);
    if (verdict == 1) {            /* 0 = bad signature, -1 = error:    */
        puts("驗證通過");           /* both are a rejection.             */
        result = 0;
    } else {
        puts("驗證失敗");
        result = 2;
    }
    goto done;

crypto_error:
    ERR_print_errors_fp(stderr);
done:
    if (in != NULL) fclose(in);
    BN_free(r);
    BN_free(s);
    ECDSA_SIG_free(sig);           /* Frees the r/s it owns. */
    EC_KEY_free(ec);
    EVP_PKEY_free(key);
    return result;
}
