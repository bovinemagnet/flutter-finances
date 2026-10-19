package com.paulsnow.finance.server.extraction;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.event.EventListener;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.receipts.ReceiptAssetAvailable;
import com.paulsnow.finance.server.sync.EntityDeleted;
import com.paulsnow.finance.server.sync.EntityReader;
import com.paulsnow.finance.server.workspace.CurrentMember;

import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.JsonNodeFactory;

/**
 * Consent records and extraction results. Every decision to send a
 * document re-reads the consent and checks it names the configured
 * provider, so a withdrawal or a change of provider stops extraction at
 * once; storing a result locks the consent row, so a result can never be
 * stored after the withdrawal that purged the others.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class ExtractionService {

    /** Job type that sends one released document to the provider. */
    static final String EXTRACT_JOB = "receipts.extract";

    /** A workspace's consent as its owner sees it. */
    record ConsentView(UUID workspaceId, String status, String providerName, String disclosedRetention,
            Instant grantedAt, Instant withdrawnAt, boolean available, String offeredProvider,
            String offeredRetention) {
    }

    /** One stored result. */
    record Result(UUID assetId, String provider, String text, List<String> lines, Instant extractedAt) {
    }

    private record Consent(String status, String providerName, String disclosedRetention, Instant grantedAt,
            Instant withdrawnAt) {

        boolean grantedTo(String provider) {
            return "granted".equals(status) && providerName.equals(provider);
        }
    }

    private final JdbcClient jdbc;
    private final ObjectProvider<ExtractionProvider> providers;
    private final JobService jobs;
    private final EntityReader entities;
    private final JsonMapper json;
    private final Clock clock;
    private final ApplicationEventPublisher events;

    ExtractionService(JdbcClient jdbc, ObjectProvider<ExtractionProvider> providers, JobService jobs,
            EntityReader entities, JsonMapper json, Clock clock, ApplicationEventPublisher events) {
        this.jdbc = jdbc;
        this.providers = providers;
        this.jobs = jobs;
        this.entities = entities;
        this.json = json;
        this.clock = clock;
        this.events = events;
    }

    /** Returns the configured provider, if any. */
    Optional<ExtractionProvider> provider() {
        return Optional.ofNullable(providers.getIfUnique());
    }

    ConsentView consent(UUID workspaceId) {
        Optional<ExtractionProvider> provider = provider();
        Optional<Consent> consent = find(workspaceId, false);
        return new ConsentView(workspaceId, consent.map(Consent::status).orElse("none"),
                consent.map(Consent::providerName).orElse(null),
                consent.map(Consent::disclosedRetention).orElse(null),
                consent.map(Consent::grantedAt).orElse(null), consent.map(Consent::withdrawnAt).orElse(null),
                provider.isPresent(), provider.map(ExtractionProvider::name).orElse(null),
                provider.map(ExtractionProvider::disclosedRetention).orElse(null));
    }

    /**
     * Grants consent to the configured provider. The owner must name the
     * provider and retention they were shown, so consent always matches
     * what was disclosed.
     */
    @Transactional
    ConsentView grant(CurrentMember owner, String providerName, String disclosedRetention) {
        ExtractionProvider provider = provider().orElseThrow(() -> ApiException.conflict("EXTRACTION_UNAVAILABLE",
                "Cloud extraction is not offered by this service."));
        if (!provider.name().equals(providerName)) {
            throw ApiException.badRequest("PROVIDER_MISMATCH", "Consent must name the offered provider.");
        }
        if (!provider.disclosedRetention().equals(disclosedRetention)) {
            throw ApiException.badRequest("RETENTION_MISMATCH", "Consent must repeat the disclosed retention.");
        }
        Timestamp now = Timestamp.from(clock.instant());
        jdbc.sql("insert into extraction_consent (workspace_id, status, provider_name, disclosed_retention, "
                        + "granted_by, granted_at, updated_at) values (?, 'granted', ?, ?, ?, ?, ?) "
                        + "on conflict (workspace_id) do update set status = 'granted', "
                        + "provider_name = excluded.provider_name, disclosed_retention = excluded.disclosed_retention, "
                        + "granted_by = excluded.granted_by, granted_at = excluded.granted_at, withdrawn_by = null, "
                        + "withdrawn_at = null, updated_at = excluded.updated_at")
                .params(owner.workspaceId(), provider.name(), provider.disclosedRetention(), owner.user().id(), now,
                        now)
                .update();
        events.publishEvent(AuditEvent.of(owner.workspaceId(), owner.user().id(), "extraction.consent_granted",
                "workspace", owner.workspaceId()));
        return consent(owner.workspaceId());
    }

    /** Withdraws consent and deletes every stored result of the workspace. */
    @Transactional
    ConsentView withdraw(CurrentMember owner) {
        Optional<Consent> consent = find(owner.workspaceId(), true);
        if (consent.isPresent() && "granted".equals(consent.get().status())) {
            Timestamp now = Timestamp.from(clock.instant());
            jdbc.sql("update extraction_consent set status = 'withdrawn', withdrawn_by = ?, withdrawn_at = ?, "
                            + "updated_at = ? where workspace_id = ?")
                    .params(owner.user().id(), now, now, owner.workspaceId()).update();
            events.publishEvent(AuditEvent.of(owner.workspaceId(), owner.user().id(),
                    "extraction.consent_withdrawn", "workspace", owner.workspaceId()));
        }
        jdbc.sql("delete from receipt_extraction where workspace_id = ?").param(owner.workspaceId()).update();
        return consent(owner.workspaceId());
    }

    /** Queues extraction of a released source document while consent stands. */
    @EventListener
    void onAssetAvailable(ReceiptAssetAvailable event) {
        if (!"source".equals(event.kind())) {
            return;
        }
        if (provider().filter(p -> isGranted(event.workspaceId(), p.name())).isEmpty()) {
            return;
        }
        jobs.enqueue(EXTRACT_JOB, event.workspaceId(), JsonNodeFactory.instance.objectNode()
                .put("receiptId", event.receiptId().toString()).put("assetId", event.assetId().toString())
                .put("contentType", event.contentType()));
    }

    /** Deletes a deleted receipt's results in the deleting command's transaction. */
    @EventListener
    void onEntityDeleted(EntityDeleted event) {
        if ("receipt".equals(event.entityType())) {
            jdbc.sql("delete from receipt_extraction where workspace_id = ? and receipt_id = ?")
                    .params(event.workspaceId(), event.entityId()).update();
        }
    }

    boolean isGranted(UUID workspaceId, String providerName) {
        return find(workspaceId, false).filter(c -> c.grantedTo(providerName)).isPresent();
    }

    /**
     * Stores a result if consent to the same provider still stands and the
     * receipt is still live.
     *
     * @return whether it was stored
     */
    @Transactional
    boolean store(UUID workspaceId, UUID receiptId, UUID assetId, String providerName, ExtractedText text) {
        if (find(workspaceId, true).filter(c -> c.grantedTo(providerName)).isEmpty()
                || !entities.isLive(workspaceId, "receipt", receiptId)) {
            return false;
        }
        ExtractedText clean = text.sanitised();
        jdbc.sql("insert into receipt_extraction (asset_id, receipt_id, workspace_id, provider_name, text, lines, "
                        + "extracted_at) values (?, ?, ?, ?, ?, ?::jsonb, ?) on conflict (asset_id) do update set "
                        + "provider_name = excluded.provider_name, text = excluded.text, lines = excluded.lines, "
                        + "extracted_at = excluded.extracted_at")
                .params(assetId, receiptId, workspaceId, providerName, clean.text(),
                        json.writeValueAsString(clean.lines()), Timestamp.from(clock.instant()))
                .update();
        return true;
    }

    List<Result> results(UUID workspaceId, UUID receiptId) {
        return jdbc.sql("select * from receipt_extraction where workspace_id = ? and receipt_id = ? "
                        + "order by extracted_at, asset_id")
                .params(workspaceId, receiptId).query(this::mapResult).list();
    }

    /** Removes a deleted workspace's consent and results. */
    long purgeWorkspace(UUID workspaceId) {
        int results = jdbc.sql("delete from receipt_extraction where workspace_id = ?").param(workspaceId).update();
        return results + jdbc.sql("delete from extraction_consent where workspace_id = ?").param(workspaceId)
                .update();
    }

    private Optional<Consent> find(UUID workspaceId, boolean lock) {
        return jdbc.sql("select * from extraction_consent where workspace_id = ?" + (lock ? " for update" : ""))
                .param(workspaceId)
                .query((rs, row) -> new Consent(rs.getString("status"), rs.getString("provider_name"),
                        rs.getString("disclosed_retention"), instant(rs, "granted_at"), instant(rs, "withdrawn_at")))
                .optional();
    }

    private Result mapResult(ResultSet rs, int row) throws SQLException {
        List<String> lines = new ArrayList<>();
        json.readTree(rs.getString("lines")).forEach(line -> lines.add(line.asString()));
        return new Result(rs.getObject("asset_id", UUID.class), rs.getString("provider_name"), rs.getString("text"),
                lines, instant(rs, "extracted_at"));
    }

    private static Instant instant(ResultSet rs, String column) throws SQLException {
        Timestamp value = rs.getTimestamp(column);
        return value == null ? null : value.toInstant();
    }
}
