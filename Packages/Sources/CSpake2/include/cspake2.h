/* SPAKE2 over edwards25519, vendored from BoringSSL (plan P3-02, spec §5.4).
 *
 * The functions are BoringSSL's SPAKE2_* API from <openssl/curve25519.h>, renamed
 * with a CSPAKE2_ prefix so they cannot clash with another BoringSSL copy in the
 * process. ADB's pairing (AOSP adb/pairing_auth) is the only user: the client is
 * Alice ("adb pair client\0"), the phone is Bob ("adb pair server\0").
 * Licence: see LICENSE in the parent folder. */

#ifndef CSPAKE2_H
#define CSPAKE2_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

enum cspake2_role_t {
  cspake2_role_alice,
  cspake2_role_bob,
};

typedef struct spake2_ctx_st CSPAKE2_CTX;

/* Largest message CSPAKE2_generate_msg writes. */
#define CSPAKE2_MAX_MSG_SIZE 32
/* Largest key CSPAKE2_process_msg derives. */
#define CSPAKE2_MAX_KEY_SIZE 64

/* A context for one run of the protocol, or NULL when out of memory. Both sides
 * must use the same two names (in mirrored order). */
CSPAKE2_CTX *CSPAKE2_CTX_new(enum cspake2_role_t my_role, const uint8_t *my_name,
                             size_t my_name_len, const uint8_t *their_name,
                             size_t their_name_len);

/* Frees |ctx| after wiping it. NULL is allowed. */
void CSPAKE2_CTX_free(CSPAKE2_CTX *ctx);

/* Writes our message (32 bytes) to |out|. Returns 1 on success, 0 on misuse.
 * Can only be called once per context. */
int CSPAKE2_generate_msg(CSPAKE2_CTX *ctx, uint8_t *out, size_t *out_len,
                         size_t max_out_len, const uint8_t *password,
                         size_t password_len);

/* Derives up to 64 bytes of key from the peer's message. Returns 0 when the
 * message is not a valid point or the context is in the wrong state. A wrong
 * password still returns 1: the keys simply differ, which the caller notices
 * when decryption fails. */
int CSPAKE2_process_msg(CSPAKE2_CTX *ctx, uint8_t *out_key, size_t *out_key_len,
                        size_t max_out_key_len, const uint8_t *their_msg,
                        size_t their_msg_len);

/* Test hook: makes the next CSPAKE2_generate_msg on this thread use these 64
 * bytes instead of fresh randomness for its ephemeral scalar, so known-answer
 * vectors can be checked. Never call it outside tests. */
void cspake2_set_test_random(const uint8_t random[64]);

#if defined(__cplusplus)
}
#endif

#endif  /* CSPAKE2_H */
