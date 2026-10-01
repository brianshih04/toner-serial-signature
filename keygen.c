/*
 * Development reference for NIST SP 800-133r2 / FIPS 186-5 style key generation.
 * Production: generate a non-exportable P-256 key inside an approved HSM/module.
 * This program writes an encrypted private PEM for TESTING ONLY; using OpenSSL
 * alone does not establish NIST/FIPS compliance.
 *
 * This compatibility demo builds with OpenSSL 1.0.2; on OpenSSL 3.x the
 * classic EC_KEY APIs are deprecated (add -Wno-deprecated-declarations when
 * using -Werror). It does not replace a production HSM key ceremony.
 *
 * Build: cc -std=c11 -Wall -Wextra -Werror keygen.c -o keygen -lcrypto
 * Usage: TONER_DEMO_KEY_PASSWORD=<secret> ./keygen private.pem public.pem
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/opensslv.h>
#include <openssl/pem.h>

#include "ui.h"

int main(int argc, char **argv)
{
    const char *password = getenv("TONER_DEMO_KEY_PASSWORD");
    EC_KEY *ec = NULL;
    EVP_PKEY *key = NULL;
    FILE *out = NULL;
    int public_created = 0;
    int private_created = 0;
    int result = 1;

    toner_ui_init();

    if (argc != 3 || strcmp(argv[1], argv[2]) == 0) {
        fprintf(stderr, "用法：%s private.pem public.pem\n", argv[0]);
        return 1;
    }
    if (password == NULL || strlen(password) < 16 || strlen(password) > 1024) {
        fprintf(stderr, "請設定 TONER_DEMO_KEY_PASSWORD（16 至 1024 位元組）。\n");
        return 1;
    }

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    /* 1.0.2 does not automatically register the PEM/PBES2 ciphers. */
    OpenSSL_add_all_algorithms();
#endif

    /* Uses the currently configured OpenSSL RAND for the 1.0.2 classic path. */
    ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    key = EVP_PKEY_new();
    if (ec == NULL || key == NULL)
        goto crypto_error;
    /* Preserve the named-curve identifier across 1.0.2 PKCS#8 encoding. */
    EC_KEY_set_asn1_flag(ec, OPENSSL_EC_NAMED_CURVE);
    if (EC_KEY_generate_key(ec) != 1 ||
        EC_KEY_check_key(ec) != 1 ||
        EVP_PKEY_assign_EC_KEY(key, ec) != 1)
        goto crypto_error;
    ec = NULL;                     /* key owns the EC_KEY now. */

    /* Exclusive create: never silently replace an existing key file. */
    out = fopen(argv[2], "wbx");
    if (out == NULL) {
        fprintf(stderr, "無法建立公鑰檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    public_created = 1;
    if (PEM_write_PUBKEY(out, key) != 1)
        goto crypto_error;
    if (fclose(out) != 0) {
        out = NULL;
        fprintf(stderr, "無法關閉公鑰檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    out = NULL;

    out = fopen(argv[1], "wbx");
    if (out == NULL) {
        fprintf(stderr, "無法建立私鑰檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    private_created = 1;
    if (PEM_write_PKCS8PrivateKey(out, key, EVP_aes_256_cbc(),
                                  (char *)password, (int)strlen(password),
                                  NULL, NULL) != 1)
        goto crypto_error;
    if (fclose(out) != 0) {
        out = NULL;
        fprintf(stderr, "無法關閉私鑰檔案（錯誤碼 %d）。\n", errno);
        goto done;
    }
    out = NULL;

    printf("已建立加密的測試私鑰：%s\n", argv[1]);
    printf("已建立驗章公鑰：%s\n", argv[2]);
    result = 0;
    goto done;

crypto_error:
    ERR_print_errors_fp(stderr);
done:
    if (out != NULL)
        fclose(out);
    if (result != 0) {
        if (private_created)
            remove(argv[1]);
        if (public_created)
            remove(argv[2]);
    }
    EC_KEY_free(ec);
    EVP_PKEY_free(key);
    return result;
}
