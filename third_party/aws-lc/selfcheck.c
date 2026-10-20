// Self-check of the libcrypto this package builds: known-answer tests through its public API, run on the
// execution platform as a validation of :crypto (:selfcheck_runs). Each answer is from a standard
// (FIPS 180-4 "abc", RFC 4231 case 2, the GCM spec's test case 14) or computed independently (BN_mod_word).
// It covers what the build could get wrong silently: the x86_64 assembly (SHA-2, AES-NI, CLMUL), the
// 128-bit arithmetic of bignums (__umodti3 comes from this package, not from the compiler runtime) and the
// symbol prefix (a header that renamed too little would not link).
// Prints one line, `ok sha256 sha512 hmac bn gcm`, and exits 0; any mismatch prints which and exits 1.
#include <stdio.h>
#include <string.h>

#include <openssl/aead.h>
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/digest.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>

static void hex(const unsigned char *b, size_t n, char *out) {
    static const char d[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[2 * i] = d[b[i] >> 4];
        out[2 * i + 1] = d[b[i] & 15];
    }
    out[2 * n] = 0;
}

static int expect(const char *what, const unsigned char *got, size_t n, const char *want) {
    char h[2 * 64 + 1];
    hex(got, n, h);
    if (strcmp(h, want) != 0) {
        fprintf(stderr, "selfcheck: %s: got %s want %s\n", what, h, want);
        return 1;
    }
    return 0;
}

int main(void) {
    int bad = 0;
    unsigned char md[64];

    SHA256((const unsigned char *)"abc", 3, md);
    bad |= expect("sha256", md, 32, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    SHA512((const unsigned char *)"abc", 3, md);
    bad |= expect("sha512", md, 64,
                  "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                  "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");

    unsigned int mdlen = 0;
    HMAC(EVP_sha256(), "Jefe", 4, (const unsigned char *)"what do ya want for nothing?", 28, md, &mdlen);
    bad |= mdlen != 32 || expect("hmac", md, 32, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    // 0x1234567890abcdef repeated four times, mod 97 and mod 1000000007 (python).
    BIGNUM *n = NULL;
    BN_hex2bn(&n, "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
    BN_ULONG m97 = BN_mod_word(n, 97);
    BN_ULONG mp = BN_mod_word(n, 1000000007);
    BN_free(n);
    if (m97 != 78 || mp != 509977877) {
        fprintf(stderr, "selfcheck: bn: got %lu %lu want 78 509977877\n", (unsigned long)m97, (unsigned long)mp);
        bad = 1;
    }

    // AES-256-GCM, 32 zero key bytes, 12 zero IV bytes, 16 zero plaintext bytes.
    unsigned char key[32] = {0}, iv[12] = {0}, pt[16] = {0}, out[16 + 16];
    size_t outlen = 0;
    EVP_AEAD_CTX ctx;
    if (!EVP_AEAD_CTX_init(&ctx, EVP_aead_aes_256_gcm(), key, 32, 16, NULL) ||
        !EVP_AEAD_CTX_seal(&ctx, out, &outlen, sizeof(out), iv, 12, pt, 16, NULL, 0) || outlen != 32) {
        fprintf(stderr, "selfcheck: gcm: seal failed\n");
        bad = 1;
    } else {
        bad |= expect("gcm", out, 32, "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919");
    }
    EVP_AEAD_CTX_cleanup(&ctx);

    if (bad) return 1;
    puts("ok sha256 sha512 hmac bn gcm");
    return 0;
}
