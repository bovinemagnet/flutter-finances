package com.paulsnow.finance.server.inboundmail;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.common.TokenCipher;

/**
 * Forwarding addresses. Tokens are found by their hash and held encrypted.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class InboundAddressStore {

    /** An active address. */
    record Address(UUID id, UUID workspaceId, UUID userId) {
    }

    /** An active address with its encrypted token. */
    record Stored(UUID id, TokenCipher.Sealed sealed, Instant createdAt) {
    }

    private final JdbcClient jdbc;

    InboundAddressStore(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    Optional<Address> findActiveByToken(String token) {
        return jdbc.sql("select id, workspace_id, user_id from inbound_address "
                        + "where token_sha256 = ? and revoked_at is null")
                .param(sha256(token))
                .query((rs, row) -> new Address(rs.getObject("id", UUID.class),
                        rs.getObject("workspace_id", UUID.class), rs.getObject("user_id", UUID.class)))
                .optional();
    }

    Optional<Stored> findActive(UUID workspaceId, UUID userId) {
        return jdbc.sql("select id, token_nonce, token_ciphertext, created_at from inbound_address "
                        + "where workspace_id = ? and user_id = ? and revoked_at is null")
                .params(workspaceId, userId)
                .query((rs, row) -> new Stored(rs.getObject("id", UUID.class),
                        new TokenCipher.Sealed(rs.getBytes("token_nonce"), rs.getBytes("token_ciphertext")),
                        rs.getTimestamp("created_at").toInstant()))
                .optional();
    }

    void insert(UUID id, UUID workspaceId, UUID userId, String token, TokenCipher.Sealed sealed, Instant now) {
        jdbc.sql("insert into inbound_address (id, workspace_id, user_id, token_sha256, token_nonce, "
                        + "token_ciphertext, created_at) values (?, ?, ?, ?, ?, ?, ?)")
                .params(id, workspaceId, userId, sha256(token), sealed.nonce(), sealed.ciphertext(),
                        Timestamp.from(now))
                .update();
    }

    int revoke(UUID workspaceId, UUID userId, Instant now) {
        return jdbc.sql("update inbound_address set revoked_at = ? where workspace_id = ? and user_id = ? "
                        + "and revoked_at is null")
                .params(Timestamp.from(now), workspaceId, userId).update();
    }

    long purgeWorkspace(UUID workspaceId) {
        return jdbc.sql("delete from inbound_address where workspace_id = ?").param(workspaceId).update();
    }

    private static String sha256(String value) {
        try {
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is unavailable", e);
        }
    }
}
