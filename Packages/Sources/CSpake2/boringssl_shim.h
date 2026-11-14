/* Copyright (c) 2014, Google Inc.
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
 * SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
 * OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
 * CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. */

// DroidDrive: the slice of BoringSSL's `crypto/internal.h`, `<openssl/mem.h>`,
// `<openssl/rand.h>`, `<openssl/sha.h>`, `<openssl/bytestring.h>` and
// `crypto/fipsmodule/bn/internal.h` that `curve25519.c` and `spake25519.c` use.
// The constant-time helpers are copied verbatim from `crypto/internal.h`;
// SHA-512 comes from CommonCrypto and randomness from arc4random_buf, so the
// target needs no library besides libSystem. See LICENSE in this folder.

#ifndef CSPAKE2_BORINGSSL_SHIM_H
#define CSPAKE2_BORINGSSL_SHIM_H

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <CommonCrypto/CommonDigest.h>
#include <malloc/malloc.h>

#include "include/cspake2.h"

// Every Mac DroidDrive runs on (x86_64, arm64) is 64-bit with __int128, so only
// the 64-bit Fiat field code is vendored. No assembly: the ADX/NEON paths stay off.
#if !defined(__LP64__) || !defined(__SIZEOF_INT128__)
#error "CSpake2 expects a 64-bit target with __int128"
#endif
#define OPENSSL_64_BIT
#define BORINGSSL_HAS_UINT128
#define OPENSSL_NO_ASM

// Keep BoringSSL's names inside this target from clashing with any other copy of
// BoringSSL in the process (Network.framework ships one).
#define SPAKE2_CTX CSPAKE2_CTX
#define spake2_role_t cspake2_role_t
#define spake2_role_alice cspake2_role_alice
#define spake2_role_bob cspake2_role_bob
#define SPAKE2_CTX_new CSPAKE2_CTX_new
#define SPAKE2_CTX_free CSPAKE2_CTX_free
#define SPAKE2_generate_msg CSPAKE2_generate_msg
#define SPAKE2_process_msg CSPAKE2_process_msg
#define SPAKE2_MAX_MSG_SIZE CSPAKE2_MAX_MSG_SIZE
#define SPAKE2_MAX_KEY_SIZE CSPAKE2_MAX_KEY_SIZE
#define x25519_ge_tobytes cspake2_x25519_ge_tobytes
#define x25519_ge_frombytes_vartime cspake2_x25519_ge_frombytes_vartime
#define x25519_ge_p3_to_cached cspake2_x25519_ge_p3_to_cached
#define x25519_ge_p1p1_to_p2 cspake2_x25519_ge_p1p1_to_p2
#define x25519_ge_p1p1_to_p3 cspake2_x25519_ge_p1p1_to_p3
#define x25519_ge_add cspake2_x25519_ge_add
#define x25519_ge_sub cspake2_x25519_ge_sub
#define x25519_ge_scalarmult_small_precomp cspake2_x25519_ge_scalarmult_small_precomp
#define x25519_ge_scalarmult_base cspake2_x25519_ge_scalarmult_base
#define x25519_ge_scalarmult cspake2_x25519_ge_scalarmult
#define x25519_sc_reduce cspake2_x25519_sc_reduce
#define k25519Precomp cspake2_k25519Precomp
#define ED25519_keypair cspake2_ED25519_keypair
#define ED25519_sign cspake2_ED25519_sign
#define ED25519_verify cspake2_ED25519_verify
#define ED25519_keypair_from_seed cspake2_ED25519_keypair_from_seed
#define X25519_keypair cspake2_X25519_keypair
#define X25519 cspake2_X25519
#define X25519_public_from_private cspake2_X25519_public_from_private

// <openssl/curve25519.h>: the X25519/Ed25519 functions curve25519.c also
// defines. DroidDrive does not call them; they are kept so the file stays as
// BoringSSL wrote it.
void ED25519_keypair(uint8_t out_public_key[32], uint8_t out_private_key[64]);
int ED25519_sign(uint8_t out_sig[64], const uint8_t *message, size_t message_len,
                 const uint8_t private_key[64]);
int ED25519_verify(const uint8_t *message, size_t message_len,
                   const uint8_t signature[64], const uint8_t public_key[32]);
void ED25519_keypair_from_seed(uint8_t out_public_key[32],
                               uint8_t out_private_key[64],
                               const uint8_t seed[32]);
void X25519_keypair(uint8_t out_public_value[32], uint8_t out_private_key[32]);
int X25519(uint8_t out_shared_key[32], const uint8_t private_key[32],
           const uint8_t peer_public_value[32]);
void X25519_public_from_private(uint8_t out_public_value[32],
                                const uint8_t private_key[32]);

// <openssl/base.h>, <openssl/mem.h>

#define OPENSSL_ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))

static inline void *OPENSSL_memcpy(void *dst, const void *src, size_t n) {
  return n == 0 ? dst : memcpy(dst, src, n);
}
static inline void *OPENSSL_memmove(void *dst, const void *src, size_t n) {
  return n == 0 ? dst : memmove(dst, src, n);
}
static inline void *OPENSSL_memset(void *dst, int c, size_t n) {
  return n == 0 ? dst : memset(dst, c, n);
}
static inline void *OPENSSL_zalloc(size_t size) { return calloc(1, size); }

// Like BoringSSL's OPENSSL_free, wipes the block first: the SPAKE2 context holds
// the private scalar and the password hash.
static inline void OPENSSL_free(void *ptr) {
  if (ptr == NULL) {
    return;
  }
  memset_s(ptr, malloc_size(ptr), 0, malloc_size(ptr));
  free(ptr);
}

static inline int CRYPTO_memcmp(const void *in_a, const void *in_b, size_t len) {
  const volatile uint8_t *a = in_a;
  const volatile uint8_t *b = in_b;
  uint8_t x = 0;
  for (size_t i = 0; i < len; i++) {
    x |= a[i] ^ b[i];
  }
  return x;
}

static inline uint64_t CRYPTO_load_u64_le(const void *in) {
  uint64_t v;
  OPENSSL_memcpy(&v, in, sizeof(v));
  return v;  // Both supported architectures are little-endian.
}

static inline int buffers_alias(const void *a, size_t a_bytes, const void *b,
                                size_t b_bytes) {
  uintptr_t a_u = (uintptr_t)a;
  uintptr_t b_u = (uintptr_t)b;
  return a_u + a_bytes > b_u && b_u + b_bytes > a_u;
}

// <openssl/rand.h>. `cspake2_test_random` lets the unit tests pin the ephemeral
// scalar to check known-answer vectors; it is NULL in normal use.
extern _Thread_local const uint8_t *cspake2_test_random;

static inline int RAND_bytes(uint8_t *out, size_t len) {
  if (cspake2_test_random != NULL) {
    memcpy(out, cspake2_test_random, len);
    cspake2_test_random = NULL;
    return 1;
  }
  arc4random_buf(out, len);
  return 1;
}

// <openssl/sha.h>, backed by CommonCrypto.
#define SHA512_DIGEST_LENGTH CC_SHA512_DIGEST_LENGTH
typedef CC_SHA512_CTX SHA512_CTX;
static inline int SHA512_Init(SHA512_CTX *sha) { return CC_SHA512_Init(sha); }
static inline int SHA512_Update(SHA512_CTX *sha, const void *data, size_t len) {
  return CC_SHA512_Update(sha, data, (CC_LONG)len);
}
static inline int SHA512_Final(uint8_t out[SHA512_DIGEST_LENGTH], SHA512_CTX *sha) {
  return CC_SHA512_Final(out, sha);
}
static inline uint8_t *SHA512(const uint8_t *data, size_t len,
                              uint8_t out[SHA512_DIGEST_LENGTH]) {
  SHA512_CTX ctx;
  SHA512_Init(&ctx);
  SHA512_Update(&ctx, data, len);
  SHA512_Final(out, &ctx);
  return out;
}

// <openssl/bytestring.h>: only what SPAKE2_CTX_new needs.
typedef struct {
  const uint8_t *data;
  size_t len;
} CBS;

static inline void CBS_init(CBS *cbs, const uint8_t *data, size_t len) {
  cbs->data = data;
  cbs->len = len;
}

static inline int CBS_stow(const CBS *cbs, uint8_t **out_ptr, size_t *out_len) {
  OPENSSL_free(*out_ptr);
  *out_ptr = NULL;
  *out_len = 0;
  if (cbs->len == 0) {
    return 1;
  }
  *out_ptr = malloc(cbs->len);
  if (*out_ptr == NULL) {
    return 0;
  }
  memcpy(*out_ptr, cbs->data, cbs->len);
  *out_len = cbs->len;
  return 1;
}

// crypto/fipsmodule/bn/internal.h: 64-bit words only.
typedef uint64_t BN_ULONG;
#define TOBN(hi, lo) ((BN_ULONG)(hi) << 32 | (lo))

// crypto/internal.h: constant-time helpers (verbatim).

typedef uint64_t crypto_word_t;

static inline crypto_word_t value_barrier_w(crypto_word_t a) {
  __asm__("" : "+r"(a) : /* no inputs */);
  return a;
}

static inline uint32_t value_barrier_u32(uint32_t a) {
  __asm__("" : "+r"(a) : /* no inputs */);
  return a;
}

static inline crypto_word_t constant_time_msb_w(crypto_word_t a) {
  return 0u - (a >> (sizeof(a) * 8 - 1));
}

static inline crypto_word_t constant_time_is_zero_w(crypto_word_t a) {
  return constant_time_msb_w(~a & (a - 1));
}

static inline crypto_word_t constant_time_eq_w(crypto_word_t a,
                                               crypto_word_t b) {
  return constant_time_is_zero_w(a ^ b);
}

static inline void constant_time_conditional_memxor(void *dst, const void *src,
                                                    size_t n,
                                                    const crypto_word_t mask) {
  assert(!buffers_alias(dst, n, src, n));
  uint8_t *out = (uint8_t *)dst;
  const uint8_t *in = (const uint8_t *)src;
  for (size_t i = 0; i < n; i++) {
    out[i] ^= value_barrier_w(mask) & in[i];
  }
}

static inline int constant_time_declassify_int(int v) {
  return (int)value_barrier_u32((uint32_t)v);
}

#define CONSTTIME_SECRET(ptr, len)
#define CONSTTIME_DECLASSIFY(ptr, len)
#define declassify_assert(expr) assert(constant_time_declassify_int(expr))

// bn_add_words and bn_select_words (crypto/fipsmodule/bn/generic.c and
// bn/internal.h), the generic C versions.
static inline BN_ULONG bn_add_words(BN_ULONG *r, const BN_ULONG *a,
                                    const BN_ULONG *b, size_t n) {
  BN_ULONG carry = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned __int128 sum = (unsigned __int128)a[i] + b[i] + carry;
    r[i] = (BN_ULONG)sum;
    carry = (BN_ULONG)(sum >> 64);
  }
  return carry;
}

static inline void bn_select_words(BN_ULONG *r, BN_ULONG mask, const BN_ULONG *a,
                                   const BN_ULONG *b, size_t num) {
  for (size_t i = 0; i < num; i++) {
    r[i] = (a[i] & value_barrier_w(mask)) | (b[i] & ~value_barrier_w(mask));
  }
}

#endif  // CSPAKE2_BORINGSSL_SHIM_H
