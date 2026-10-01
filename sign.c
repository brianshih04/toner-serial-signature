/*
 * Test issuer: ECDSA P-256/SHA-256 over the shared TONER-AUTH v2 record.
 * Production issuer must use the HSM-held, non-exportable private key.
 * The 64-byte output is raw r[32] || s[32], NOT OpenSSL's DER encoding.
 * Do NOT assume ATSHA204A OTP is free: signature storage is a separate
 * product/configuration decision and must not disturb existing chip data.
 *
 * Compatibility target: OpenSSL 1.0.2o through 3.x. Integrators must still
 * verify the actual firmware crypto library on target hardware.
 *  - ECDSA_SIG_set0/get0, BN_bn2binpad, EVP_PKEY_is_a, core_names.h and
 *    provider parameter queries are 1.1.0/3.x-only and must not appear here.
 *  - On 1.1.x/3.x the classic APIs still work but are deprecated and
 *    ECDSA_SIG is opaque, so r/s access goes through ECDSA_SIG_get0()
 *    behind an OPENSSL_VERSION_NUMBER check; build there with
 *    -Wno-deprecated-declarations.
 *  - This test issuer uses classic ECDSA_do_sign() to keep one algorithm path
 *    across 1.0.2..3.x. Production signing must be performed by the HSM.
 *
 * Build: cc -std=c11 -Wall -Wextra -Werror sign.c record.c -o sign -lcrypto
 * Usage: TONER_DEMO_KEY_PASSWORD=<secret> ./sign private.pem KEY_ID_HEX SN18HEX SKU COLOR CAPACITY_CODE signature.bin
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

/* Must stay identical to the copy in verify.c: the hex CLI wrappers are
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

/* OpenSSL 1.0.2 has no BN_bn2binpad() (1.1.0+): left-pad to a fixed width. */
static int bn2bin_fixed(const BIGNUM *bn, unsigned char *out, size_t len)
{
    int n = BN_num_bytes(bn);

    if (n < 0 || (size_t)n > len)
        return 0;
    memset(out, 0, len);
    return BN_bn2bin(bn, out + (len - (size_t)n)) == n ? 1 : 0;
}

int main(int argc, char **argv)
{
    const char *password = getenv("TONER_DEMO_KEY_PASSWORD");
    uint8_t key_id, sn[TONER_SN_SIZE];
    unsigned char record[TONER_RECORD_MAX_SIZE];
    unsigned char digest[SHA256_DIGEST_LENGTH];
    unsigned char raw[RAW_SIG_SIZE];
    size_t record_len = 0;
    EC_KEY *ec = NULL;
    EVP_PKEY *key = NULL;
    ECDSA_SIG *sig = NULL;
    FILE *in = NULL, *out = NULL;
    int output_created = 0, result = 1;

    toner_ui_init();

    if (argc != 8 || !parse_hex(argv[2], 1, &key_id) ||
        !parse_hex(argv[3], TONER_SN_SIZE, sn) ||
        !toner_record_encode(key_id, sn, argv[4], strlen(argv[4]),
                             argv[5][0] != '\0' && argv[5][1] == '\0' ? argv[5][0] : '\0',
                             argv[6], strlen(argv[6]),
                             record, sizeof(record), &record_len)) {
        fprintf(stderr, "用法：%s private.pem KEY_ID_HEX SN18HEX SKU COLOR CAPACITY_CODE signature.bin\n", argv[0]);
        fprintf(stderr, "金鑰 ID：01-FF；序號：18 個十六進位字元；顏色：K/C/M/Y。\n");
        return 1;
    }
    if (password == NULL) {
        fprintf(stderr, "請設定 TONER_DEMO_KEY_PASSWORD。\n");
        return 1;
    }

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    /* Needed to decode the encrypted test PEM on OpenSSL 1.0.2. */
    OpenSSL_add_all_algorithms();
#endif

    in = fopen(argv[1], "rb");
    if (in == NULL) {
        fprintf(stderr, "無法開啟私鑰檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    key = PEM_read_PrivateKey(in, NULL, NULL, (void *)password);
    fclose(in);
    in = NULL;
    if (key == NULL)
        goto crypto_error;
    ec = get_p256_key(key);        /* Owned reference; free below. */
    if (ec == NULL) {
        fprintf(stderr, "私鑰必須使用 EC P-256。\n");
        goto done;
    }

    /* Random-k ECDSA over SHA-256(record): the same signature set that
     * verify.c checks. Deterministic (RFC 6979) k is not required here. */
    if (SHA256(record, record_len, digest) == NULL)
        goto crypto_error;
    sig = ECDSA_do_sign(digest, SHA256_DIGEST_LENGTH, ec);
    if (sig == NULL)
        goto crypto_error;
    {
        const BIGNUM *r, *s;
#if OPENSSL_VERSION_NUMBER >= 0x10100000L
        ECDSA_SIG_get0(sig, &r, &s);       /* struct opaque since 1.1.0 */
#else
        r = sig->r;                        /* OpenSSL 1.0.2: public fields */
        s = sig->s;
#endif
        if (r == NULL || s == NULL ||
            bn2bin_fixed(r, raw, 32) != 1 ||
            bn2bin_fixed(s, raw + 32, 32) != 1)
            goto crypto_error;
    }

    out = fopen(argv[7], "wbx");
    if (out == NULL) {
        fprintf(stderr, "無法建立簽章檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    output_created = 1;
    if (fwrite(raw, 1, sizeof(raw), out) != sizeof(raw)) {
        fprintf(stderr, "無法寫入簽章檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    if (fclose(out) != 0) {
        out = NULL;
        fprintf(stderr, "無法關閉簽章檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    out = NULL;
    printf("已建立 %zu 位元組的 ECDSA 原始簽章：%s\n", sizeof(raw), argv[7]);
    result = 0;
    goto done;

crypto_error:
    ERR_print_errors_fp(stderr);
done:
    if (in != NULL) fclose(in);
    if (out != NULL) fclose(out);
    if (result != 0 && output_created) remove(argv[7]);
    ECDSA_SIG_free(sig);
    EC_KEY_free(ec);
    EVP_PKEY_free(key);
    return result;
}
