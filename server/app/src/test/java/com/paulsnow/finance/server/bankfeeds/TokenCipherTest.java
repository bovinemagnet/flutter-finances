package com.paulsnow.finance.server.bankfeeds;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.UUID;

import org.junit.jupiter.api.Test;

/**
 * Provider tokens are sealed with AES-GCM bound to their connection, and
 * rate-limited refreshes back off exponentially.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class TokenCipherTest {

    private static final String KEY = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";

    private final TokenCipher cipher = new TokenCipher(KEY);

    @Test
    void roundTripsWithAFreshNonceEachTime() {
        UUID connection = UUID.randomUUID();
        byte[] plain = "secret-token".getBytes(StandardCharsets.UTF_8);
        TokenCipher.Sealed first = cipher.encrypt(connection, plain);
        TokenCipher.Sealed second = cipher.encrypt(connection, plain);
        assertThat(first.nonce()).isNotEqualTo(second.nonce());
        assertThat(new String(first.ciphertext(), StandardCharsets.ISO_8859_1)).doesNotContain("secret-token");
        assertThat(cipher.decrypt(connection, first)).isEqualTo(plain);
    }

    @Test
    void refusesTamperedCiphertextOrAnotherConnection() {
        UUID connection = UUID.randomUUID();
        TokenCipher.Sealed sealed = cipher.encrypt(connection, "token".getBytes(StandardCharsets.UTF_8));
        assertThatThrownBy(() -> cipher.decrypt(UUID.randomUUID(), sealed)).isInstanceOf(IllegalStateException.class);
        byte[] tampered = sealed.ciphertext().clone();
        tampered[0] ^= 1;
        assertThatThrownBy(() -> cipher.decrypt(connection, new TokenCipher.Sealed(sealed.nonce(), tampered)))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void isUnavailableWithoutAKeyAndRejectsMalformedKeys() {
        assertThat(new TokenCipher("").available()).isFalse();
        assertThat(cipher.available()).isTrue();
        assertThatThrownBy(() -> new TokenCipher("c2hvcnQ=")).isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> new TokenCipher("not base64!")).isInstanceOf(IllegalStateException.class);
    }

    @Test
    void backsOffExponentiallyWithinBounds() {
        BankFeedProperties properties = new BankFeedProperties(null, null, null, Duration.ofMinutes(1),
                Duration.ofMinutes(10), 0, null);
        assertThat(properties.backoff(1, Duration.ZERO)).isEqualTo(Duration.ofMinutes(1));
        assertThat(properties.backoff(2, Duration.ZERO)).isEqualTo(Duration.ofMinutes(2));
        assertThat(properties.backoff(3, Duration.ZERO)).isEqualTo(Duration.ofMinutes(4));
        assertThat(properties.backoff(3, Duration.ofMinutes(7))).isEqualTo(Duration.ofMinutes(7));
        assertThat(properties.backoff(30, Duration.ZERO)).isEqualTo(Duration.ofMinutes(10));
    }
}
