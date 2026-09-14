/* ===========================================================================
 * SCA_Pro_PQC -- AES-128 (FIPS-197): plain reference + first-order masked
 * ===========================================================================
 *
 * Net-new symmetric primitive for the open-source-flow PQC folder.
 *
 *   - aes128_*           : plain reference AES-128 ECB encrypt (FIPS-197).
 *   - masked_aes128_*    : first-order (d=1) 2-share Boolean-masked AES-128
 *                          ECB encrypt.  The S-box is computed with the
 *                          Boyar-Peralta combinational circuit, every GF(2)
 *                          AND gate routed through the ISE DOM-AND gadget
 *                          (SCA_AND_LATCH / SCA_AND_REUSE) so the two shares
 *                          of each product never co-locate in a CPU register.
 *                          Fresh randomness comes from the ISE PRNG
 *                          (SCA_GET_RANDOM, drawn inside the DOM gadget).
 *
 * Both produce identical ciphertext (correctness KAT).  The masked path keeps
 * the secret split into two shares end-to-end; the only recombination is the
 * final output (masked_aes128_ecb_encrypt unmasks the 16-byte ciphertext for
 * the caller, exactly as the ML-KEM masked decode unmasks its final message).
 *
 * This is SOFTWARE only -- it adds no RTL and invents no custom instruction;
 * it reuses the existing ISE PRNG / DOM-AND hooks (sca_pqc_ise.h).
 * ===========================================================================
 */
#ifndef MASKED_AES_H
#define MASKED_AES_H

#include <stdint.h>
#include <stddef.h>

#define AES128_KEY_BYTES    16
#define AES128_BLOCK_BYTES  16
#define AES128_ROUNDS       10
/* Expanded key: 11 round keys * 16 bytes */
#define AES128_RK_BYTES     (16 * (AES128_ROUNDS + 1))

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Plain reference AES-128 (FIPS-197)
 * ========================================================================= */

/* Key expansion: rk must hold AES128_RK_BYTES bytes. */
void aes128_key_expansion(uint8_t rk[AES128_RK_BYTES],
                          const uint8_t key[AES128_KEY_BYTES]);

/* ECB encrypt a single 16-byte block with an already-expanded key. */
void aes128_encrypt_block(uint8_t out[AES128_BLOCK_BYTES],
                          const uint8_t in[AES128_BLOCK_BYTES],
                          const uint8_t rk[AES128_RK_BYTES]);

/* One-shot ECB encrypt (expands key internally). */
void aes128_ecb_encrypt(uint8_t out[AES128_BLOCK_BYTES],
                        const uint8_t in[AES128_BLOCK_BYTES],
                        const uint8_t key[AES128_KEY_BYTES]);

/* =========================================================================
 * First-order masked AES-128 (2 Boolean shares)
 * ========================================================================= */

/* Seed the ISE PRNG used by the masked S-box DOM-AND gadgets.  On the host
 * this seeds the deterministic xorshift32 emulator; on RV32 it seeds the
 * coprocessor PRNG.  Call once before masked_aes128_ecb_encrypt. */
void masked_aes128_init(uint32_t seed);

/* One-shot masked ECB encrypt.  The plaintext and key are split into two
 * fresh Boolean shares internally; the 16-byte ciphertext is unmasked on
 * output (the single permitted recombination).  Result is bit-identical to
 * aes128_ecb_encrypt for the same (in, key). */
void masked_aes128_ecb_encrypt(uint8_t out[AES128_BLOCK_BYTES],
                               const uint8_t in[AES128_BLOCK_BYTES],
                               const uint8_t key[AES128_KEY_BYTES]);

/* Variant that takes the plaintext and key already split into two Boolean
 * shares (p = p0^p1, k = k0^k1) and returns the ciphertext as two Boolean
 * shares (c0^c1).  No unmasked secret is ever materialised.  Round keys are
 * carried in shares throughout. */
void masked_aes128_ecb_encrypt_shared(uint8_t c0[AES128_BLOCK_BYTES],
                                       uint8_t c1[AES128_BLOCK_BYTES],
                                       const uint8_t p0[AES128_BLOCK_BYTES],
                                       const uint8_t p1[AES128_BLOCK_BYTES],
                                       const uint8_t k0[AES128_KEY_BYTES],
                                       const uint8_t k1[AES128_KEY_BYTES]);

#ifdef __cplusplus
}
#endif

#endif /* MASKED_AES_H */
