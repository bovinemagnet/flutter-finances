package com.paulsnow.finance.server.common;

import java.nio.ByteBuffer;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.UUID;

import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * AES-GCM encryption of secrets at rest, with a fresh 96-bit nonce
 * per encryption and the owner's identifier as associated data, so a
 * ciphertext copied to another owner does not decrypt. The key comes
 * from configuration (a secret store in production), never the database.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class TokenCipher {

    private static final int NONCE_BYTES = 12;
    private static final int TAG_BITS = 128;

    /** A nonce and the ciphertext with its authentication tag. */
    public record Sealed(byte[] nonce, byte[] ciphertext) {
    }

    private final SecretKey key;
    private final SecureRandom random = new SecureRandom();

    /**
     * Creates a cipher from a base64 key.
     *
     * @param base64Key 16, 24 or 32 bytes in base64, or blank when the feature using it is not configured
     * @throws IllegalStateException when the key is present but malformed
     */
    public TokenCipher(String base64Key) {
        if (base64Key == null || base64Key.isBlank()) {
            this.key = null;
            return;
        }
        byte[] bytes;
        try {
            bytes = Base64.getDecoder().decode(base64Key.strip());
        } catch (IllegalArgumentException e) {
            throw new IllegalStateException("The token key must be base64");
        }
        if (bytes.length != 16 && bytes.length != 24 && bytes.length != 32) {
            throw new IllegalStateException("The token key must be a 128, 192 or 256-bit AES key");
        }
        this.key = new SecretKeySpec(bytes, "AES");
    }

    /** Returns whether a key is configured. */
    public boolean available() {
        return key != null;
    }

    public Sealed encrypt(UUID connectionId, byte[] plaintext) {
        byte[] nonce = new byte[NONCE_BYTES];
        random.nextBytes(nonce);
        try {
            Cipher cipher = cipher(Cipher.ENCRYPT_MODE, nonce, connectionId);
            return new Sealed(nonce, cipher.doFinal(plaintext));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("Token encryption failed", e);
        }
    }

    public byte[] decrypt(UUID connectionId, Sealed sealed) {
        try {
            return cipher(Cipher.DECRYPT_MODE, sealed.nonce(), connectionId).doFinal(sealed.ciphertext());
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("Token decryption failed");
        }
    }

    private Cipher cipher(int mode, byte[] nonce, UUID connectionId) throws GeneralSecurityException {
        if (key == null) {
            throw new IllegalStateException("No token key configured");
        }
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode, key, new GCMParameterSpec(TAG_BITS, nonce));
        cipher.updateAAD(ByteBuffer.allocate(16).putLong(connectionId.getMostSignificantBits())
                .putLong(connectionId.getLeastSignificantBits()).array());
        return cipher;
    }
}
