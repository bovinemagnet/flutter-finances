package com.paulsnow.finance.server.bankfeeds;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ProviderAccount;
import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ProviderGrant;
import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ProviderTokens;

import tools.jackson.databind.json.JsonMapper;

/**
 * Persistence of connections, their shared accounts and their encrypted
 * provider tokens. Tokens are only ever decrypted here, for the refresh
 * job and revocation; they never leave the server.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ConnectionStore {

    /** A stored connection. */
    record Connection(UUID id, UUID workspaceId, String provider, String reference, String institutionId,
            String institutionName, List<String> dataScope, String purpose, String consentStatus,
            String consentStateSha256, Instant consentExpiresAt, Instant lastRefreshAt, String errorCode,
            Instant errorAt, int rateLimitAttempts, Instant nextRefreshAt, Instant createdAt, Instant revokedAt) {

        boolean collecting() {
            return "active".equals(consentStatus);
        }
    }

    /** A shared account and its cursor. */
    record Account(String id, String name, String type, String maskedNumber, String cursor) {
    }

    private final JdbcClient jdbc;
    private final TokenCipher cipher;
    private final JsonMapper json;
    private final Clock clock;

    ConnectionStore(JdbcClient jdbc, TokenCipher cipher, JsonMapper json, Clock clock) {
        this.jdbc = jdbc;
        this.cipher = cipher;
        this.json = json;
        this.clock = clock;
    }

    Optional<Connection> find(UUID workspaceId, UUID id) {
        return jdbc.sql("select * from bank_feed_connection where id = ? and workspace_id = ?")
                .params(id, workspaceId).query(this::map).optional();
    }

    Optional<Connection> findAny(UUID id) {
        return jdbc.sql("select * from bank_feed_connection where id = ?").param(id).query(this::map).optional();
    }

    Optional<Connection> findByReference(String provider, String reference) {
        return jdbc.sql("select * from bank_feed_connection where provider = ? and provider_reference = ?")
                .params(provider, reference).query(this::map).optional();
    }

    List<Connection> list(UUID workspaceId) {
        return jdbc.sql("select * from bank_feed_connection where workspace_id = ? order by created_at, id")
                .param(workspaceId).query(this::map).list();
    }

    void insertPending(UUID id, UUID workspaceId, String provider, String institutionId, List<String> dataScope,
            String purpose, String stateSha256, UUID createdBy) {
        Timestamp now = now();
        jdbc.sql("insert into bank_feed_connection (id, workspace_id, provider, institution_id, data_scope, purpose, "
                        + "consent_status, consent_state_sha256, created_by, created_at, updated_at) "
                        + "values (?, ?, ?, ?, ?::jsonb, ?, 'pending', ?, ?, ?, ?)")
                .params(id, workspaceId, provider, institutionId, json.writeValueAsString(dataScope), purpose,
                        stateSha256, createdBy, now, now)
                .update();
    }

    /** Records a new consent state hash for a reconnect that redirects. */
    void beginReconnect(UUID id, String stateSha256) {
        jdbc.sql("update bank_feed_connection set consent_state_sha256 = ?, updated_at = ? where id = ?")
                .params(stateSha256, now(), id).update();
    }

    /**
     * Activates a connection with a granted consent: stores the encrypted
     * tokens and the shared accounts, keeping existing cursors.
     */
    @Transactional
    void activate(UUID id, UUID workspaceId, ProviderGrant grant, List<ProviderAccount> accounts) {
        Timestamp now = now();
        jdbc.sql("update bank_feed_connection set provider_reference = ?, institution_id = coalesce(?, institution_id), "
                        + "institution_name = ?, consent_status = 'active', consent_state_sha256 = null, "
                        + "consent_expires_at = ?, error_code = null, error_at = null, rate_limit_attempts = 0, "
                        + "next_refresh_at = null, updated_at = ? where id = ?")
                .params(grant.reference(), grant.institutionId(), grant.institutionName(),
                        timestamp(grant.consentExpiresAt()), now, id)
                .update();
        saveTokens(id, workspaceId, grant.tokens());
        saveAccounts(id, workspaceId, accounts);
    }

    void saveAccounts(UUID id, UUID workspaceId, List<ProviderAccount> accounts) {
        for (ProviderAccount account : accounts) {
            jdbc.sql("insert into bank_feed_account (connection_id, provider_account_id, workspace_id, name, type, "
                            + "masked_number) values (?, ?, ?, ?, ?, ?) on conflict (connection_id, "
                            + "provider_account_id) do update set name = excluded.name, type = excluded.type, "
                            + "masked_number = excluded.masked_number")
                    .params(id, account.id(), workspaceId, account.name(), account.type(), account.maskedNumber())
                    .update();
        }
    }

    List<Account> accounts(UUID id) {
        return jdbc.sql("select * from bank_feed_account where connection_id = ? order by provider_account_id")
                .param(id)
                .query((rs, row) -> new Account(rs.getString("provider_account_id"), rs.getString("name"),
                        rs.getString("type"), rs.getString("masked_number"), rs.getString("provider_cursor")))
                .list();
    }

    void saveCursor(UUID id, String accountId, String cursor) {
        jdbc.sql("update bank_feed_account set provider_cursor = ? where connection_id = ? and provider_account_id = ?")
                .params(cursor, id, accountId).update();
    }

    void saveTokens(UUID id, UUID workspaceId, ProviderTokens tokens) {
        TokenCipher.Sealed sealed = cipher.encrypt(id, json.writeValueAsBytes(tokens));
        jdbc.sql("insert into bank_feed_token (connection_id, workspace_id, nonce, ciphertext, updated_at) "
                        + "values (?, ?, ?, ?, ?) on conflict (connection_id) do update set nonce = excluded.nonce, "
                        + "ciphertext = excluded.ciphertext, updated_at = excluded.updated_at")
                .params(id, workspaceId, sealed.nonce(), sealed.ciphertext(), now()).update();
    }

    Optional<ProviderTokens> tokens(UUID id) {
        return jdbc.sql("select nonce, ciphertext from bank_feed_token where connection_id = ?").param(id)
                .query((rs, row) -> new TokenCipher.Sealed(rs.getBytes("nonce"), rs.getBytes("ciphertext")))
                .optional()
                .map(sealed -> json.readValue(cipher.decrypt(id, sealed), ProviderTokens.class));
    }

    void markSucceeded(UUID id) {
        Timestamp now = now();
        jdbc.sql("update bank_feed_connection set last_refresh_at = ?, error_code = null, error_at = null, "
                        + "rate_limit_attempts = 0, next_refresh_at = null, updated_at = ? where id = ?")
                .params(now, now, id).update();
    }

    void markConsent(UUID id, String status, Instant expiresAt) {
        jdbc.sql("update bank_feed_connection set consent_status = ?, consent_expires_at = coalesce(?, "
                        + "consent_expires_at), updated_at = ? where id = ?")
                .params(status, timestamp(expiresAt), now(), id).update();
    }

    void markError(UUID id, String code, int rateLimitAttempts, Instant nextRefreshAt) {
        Timestamp now = now();
        jdbc.sql("update bank_feed_connection set error_code = ?, error_at = ?, rate_limit_attempts = ?, "
                        + "next_refresh_at = ?, updated_at = ? where id = ?")
                .params(code, now, rateLimitAttempts, timestamp(nextRefreshAt), now, id).update();
    }

    /**
     * Ends collection for good: deletes the tokens and marks the consent
     * revoked, in one transaction.
     */
    @Transactional
    void revoke(UUID id) {
        jdbc.sql("delete from bank_feed_token where connection_id = ?").param(id).update();
        Timestamp now = now();
        jdbc.sql("update bank_feed_connection set consent_status = 'revoked', consent_state_sha256 = null, "
                        + "next_refresh_at = null, revoked_at = coalesce(revoked_at, ?), updated_at = ? where id = ?")
                .params(now, now, id).update();
    }

    /** Marks an expired consent and deletes tokens that can no longer be used. */
    @Transactional
    void expire(UUID id, Instant expiresAt) {
        markConsent(id, "expired", expiresAt);
        jdbc.sql("update bank_feed_connection set next_refresh_at = null where id = ?").param(id).update();
        jdbc.sql("delete from bank_feed_token where connection_id = ?").param(id).update();
    }

    /** Removes a deleted workspace's bank feed data; records, accounts and tokens cascade. */
    long purgeWorkspace(UUID workspaceId) {
        int records = jdbc.sql("delete from bank_feed_record where workspace_id = ?").param(workspaceId).update();
        return records + jdbc.sql("delete from bank_feed_connection where workspace_id = ?").param(workspaceId)
                .update();
    }

    private Connection map(ResultSet rs, int row) throws SQLException {
        List<String> scope = new ArrayList<>();
        json.readTree(rs.getString("data_scope")).forEach(s -> scope.add(s.asString()));
        return new Connection(rs.getObject("id", UUID.class), rs.getObject("workspace_id", UUID.class),
                rs.getString("provider"), rs.getString("provider_reference"), rs.getString("institution_id"),
                rs.getString("institution_name"), scope, rs.getString("purpose"), rs.getString("consent_status"),
                rs.getString("consent_state_sha256"), instant(rs, "consent_expires_at"), instant(rs, "last_refresh_at"),
                rs.getString("error_code"), instant(rs, "error_at"), rs.getInt("rate_limit_attempts"),
                instant(rs, "next_refresh_at"), instant(rs, "created_at"), instant(rs, "revoked_at"));
    }

    private Timestamp now() {
        return Timestamp.from(clock.instant());
    }

    private static Timestamp timestamp(Instant instant) {
        return instant == null ? null : Timestamp.from(instant);
    }

    static Instant instant(ResultSet rs, String column) throws SQLException {
        Timestamp value = rs.getTimestamp(column);
        return value == null ? null : value.toInstant();
    }
}
