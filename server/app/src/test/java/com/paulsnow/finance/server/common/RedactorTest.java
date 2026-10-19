package com.paulsnow.finance.server.common;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/**
 * Operational logs must never carry tokens, account numbers, amounts or
 * signed URLs, while identifiers useful for support remain readable.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class RedactorTest {

    @Test
    void redactsBearerTokensAndJwts() {
        String jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl";
        assertThat(Redactor.redact("Authorization: Bearer " + jwt)).doesNotContain(jwt).contains("[REDACTED");
        assertThat(Redactor.redact("token=" + jwt)).doesNotContain("eyJzdWIiOiJ4In0");
    }

    @Test
    void redactsAccountNumbersAndAmounts() {
        assertThat(Redactor.redact("account 062000123456789 rejected")).doesNotContain("062000123456789");
        assertThat(Redactor.redact("amount -103.47 posted")).doesNotContain("103.47");
        assertThat(Redactor.redact("total $1,234.50")).doesNotContain("1,234.50");
    }

    @Test
    void redactsSignedUrlSecretsAndDatabaseKeyDetails() {
        String url = "https://s3/x?X-Amz-Credential=AKIA%2F2026&X-Amz-Signature=abcdef0123&X-Amz-Expires=300";
        assertThat(Redactor.redact(url)).doesNotContain("abcdef0123").doesNotContain("AKIA").contains("X-Amz-Expires=300");
        assertThat(Redactor.redact("Detail: Key (payee)=(Corner Grocer) already exists."))
                .doesNotContain("Corner Grocer");
    }

    @Test
    void redactsEmailAddresses() {
        assertThat(Redactor.redact("user someone@example.com signed in")).doesNotContain("someone@example.com");
    }

    @Test
    void keepsIdentifiersAndDatesReadable() {
        String message = "command 0199f0a2-1234-7abc-8def-123456789012 for workspace on 2026-07-01 version 4.1.1";
        assertThat(Redactor.redact(message)).isEqualTo(message);
    }
}
