package com.paulsnow.finance.server.receipts;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.DigestOutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.Timestamp;
import java.time.Clock;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.UUID;
import java.util.regex.Pattern;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.core.documents.ContentSniffer;
import com.paulsnow.finance.core.documents.PdfInspector;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.storage.Retention;
import com.paulsnow.finance.server.storage.PresignedRequest;
import com.paulsnow.finance.server.sync.EntityReader;
import com.paulsnow.finance.server.sync.VisibilityService;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import tools.jackson.databind.node.JsonNodeFactory;

/**
 * Receipt document lifecycle. Clients upload to a per-asset staging key;
 * completion verifies the staged bytes and copies them to the asset's
 * permanent key, so a repeated or late upload can never replace a verified
 * document. Every lookup is scoped to the caller's workspace and answers
 * 404 for anything else, so an identifier alone reveals nothing (A17).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class ReceiptService {

    /** Job type of the quarantine scan. */
    static final String SCAN_JOB = "receipts.scan";

    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
    private static final List<String> FAILURE_REASONS = List.of("OBJECT_MISSING", "CHECKSUM_MISMATCH",
            "CONTENT_TYPE_MISMATCH", "TOO_MANY_PAGES", "SCAN_REJECTED");

    /** A stored document asset. */
    record Asset(UUID assetId, UUID receiptId, UUID workspaceId, String kind, String contentType, long sizeBytes,
            String sha256, String objectKey, String status) {
    }

    private final JdbcClient jdbc;
    private final ObjectStorage storage;
    private final EntityReader entities;
    private final JobService jobs;
    private final ReceiptProperties properties;
    private final Clock clock;
    private final MeterRegistry meters;
    private final VisibilityService visibility;
    private final ApplicationEventPublisher events;

    ReceiptService(JdbcClient jdbc, ObjectStorage storage, EntityReader entities, JobService jobs,
            ReceiptProperties properties, Clock clock, MeterRegistry meters, VisibilityService visibility,
            ApplicationEventPublisher events) {
        this.visibility = visibility;
        this.events = events;
        this.jdbc = jdbc;
        this.storage = storage;
        this.entities = entities;
        this.jobs = jobs;
        this.properties = properties;
        this.clock = clock;
        this.meters = meters;
        FAILURE_REASONS.forEach(this::failureCounter);
    }

    @Transactional
    PresignedRequest createUploadIntent(UUID workspaceId, UUID receiptId, UUID assetId, String kind,
            String contentType, long sizeBytes, String sha256) {
        String checksum = sha256 == null ? "" : sha256.strip().toLowerCase(Locale.ROOT);
        if (!"source".equals(kind) && !"derivative".equals(kind)) {
            throw ApiException.badRequest("INVALID_KIND", "kind must be source or derivative.");
        }
        if (contentType == null || !ContentTypes.ACCEPTED.contains(contentType)) {
            throw ApiException.badRequest("UNSUPPORTED_CONTENT_TYPE", "Upload JPEG, PNG, HEIC, HEIF or PDF.");
        }
        if (sizeBytes <= 0) {
            throw ApiException.badRequest("INVALID_REQUEST", "sizeBytes must be positive.");
        }
        if (sizeBytes > properties.maxSizeBytes()) {
            throw ApiException.badRequest("TOO_LARGE", "The document is larger than the upload limit.");
        }
        if (!SHA256.matcher(checksum).matches()) {
            throw ApiException.badRequest("INVALID_CHECKSUM", "sha256 must be 64 hexadecimal characters.");
        }
        if (!entities.isLive(workspaceId, "receipt", receiptId)) {
            throw receiptNotFound();
        }
        Timestamp now = Timestamp.from(clock.instant());
        jdbc.sql("insert into receipt_document (receipt_id, workspace_id, created_at) values (?, ?, ?) "
                        + "on conflict (receipt_id) do nothing")
                .params(receiptId, workspaceId, now).update();
        UUID owner = jdbc.sql("select workspace_id from receipt_document where receipt_id = ?").param(receiptId)
                .query(UUID.class).single();
        if (!owner.equals(workspaceId)) {
            throw receiptNotFound();
        }
        Optional<Asset> existing = findAsset(assetId);
        if (existing.isPresent()) {
            Asset asset = existing.get();
            if (!asset.workspaceId().equals(workspaceId) || !asset.receiptId().equals(receiptId)) {
                throw receiptNotFound();
            }
            if ("pending_upload".equals(asset.status())) {
                jdbc.sql("update receipt_asset set kind = ?, content_type = ?, size_bytes = ?, sha256 = ?, "
                                + "updated_at = ? where asset_id = ?")
                        .params(kind, contentType, sizeBytes, checksum, now, assetId).update();
            } else if (!asset.sha256().equals(checksum)) {
                throw ApiException.conflict("ASSET_ALREADY_COMPLETE",
                        "This asset was already uploaded with different content; use a new assetId.");
            }
        } else {
            jdbc.sql("insert into receipt_asset (asset_id, receipt_id, workspace_id, kind, content_type, size_bytes, "
                            + "sha256, object_key, status, created_at, updated_at) "
                            + "values (?, ?, ?, ?, ?, ?, ?, ?, 'pending_upload', ?, ?)")
                    .params(assetId, receiptId, workspaceId, kind, contentType, sizeBytes, checksum,
                            assetKey(workspaceId, receiptId, assetId), now, now)
                    .update();
        }
        return storage.presignPut(uploadKey(workspaceId, assetId), contentType, Retention.STAGING);
    }

    /**
     * Verifies an uploaded asset and moves it into quarantine. Completing an
     * asset that is already past upload only reports its status.
     *
     * @return the asset status
     */
    @Transactional
    String complete(UUID workspaceId, UUID receiptId, UUID assetId) {
        // Completions of one receipt are serialised for its page limit.
        jdbc.sql("select receipt_id from receipt_document where receipt_id = ? and workspace_id = ? for update")
                .params(receiptId, workspaceId).query(UUID.class).optional()
                .orElseThrow(() -> ApiException.notFound("UNKNOWN_ASSET", "Asset not found."));
        Asset asset = jdbc.sql("select * from receipt_asset where asset_id = ? and receipt_id = ? "
                        + "and workspace_id = ? for update")
                .params(assetId, receiptId, workspaceId).query(ReceiptService::mapAsset).optional()
                .orElseThrow(() -> ApiException.notFound("UNKNOWN_ASSET", "Asset not found."));
        if (!"pending_upload".equals(asset.status())) {
            return asset.status();
        }
        String staging = uploadKey(workspaceId, assetId);
        Optional<ObjectStorage.ObjectInfo> uploaded = storage.head(staging);
        if (uploaded.isEmpty()) {
            failureCounter("OBJECT_MISSING").increment();
            throw ApiException.conflict("OBJECT_MISSING", "Upload the document before completing it.");
        }
        Path copy = null;
        int pages;
        try {
            copy = Files.createTempFile("receipt-", ".bin");
            byte[] header;
            String digest;
            try (InputStream in = storage.read(staging); OutputStream file = Files.newOutputStream(copy);
                    DigestOutputStream out = new DigestOutputStream(file, MessageDigest.getInstance("SHA-256"))) {
                header = in.readNBytes(ContentSniffer.SNIFF_BYTES);
                out.write(header);
                long total = header.length + in.transferTo(out);
                if (total != asset.sizeBytes()) {
                    reject(staging, "CHECKSUM_MISMATCH");
                }
                digest = HexFormat.of().formatHex(out.getMessageDigest().digest());
            }
            if (!digest.equals(asset.sha256())) {
                reject(staging, "CHECKSUM_MISMATCH");
            }
            if (!ContentSniffer.sniffMimeType(header).filter(asset.contentType()::equals).isPresent()) {
                reject(staging, "CONTENT_TYPE_MISMATCH");
            }
            pages = pageCount(asset, copy);
            if ("source".equals(asset.kind())
                    && sourcePages(receiptId, assetId) + pages > properties.maxPagesPerReceipt()) {
                reject(staging, "TOO_MANY_PAGES");
            }
            storage.put(asset.objectKey(), copy, asset.contentType());
            storage.delete(staging);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        } finally {
            deleteQuietly(copy);
        }
        Timestamp now = Timestamp.from(clock.instant());
        jdbc.sql("update receipt_asset set status = 'quarantined', page_count = ?, completed_at = ?, "
                + "updated_at = ? where asset_id = ?").params(pages, now, now, assetId).update();
        jobs.enqueue(SCAN_JOB, workspaceId, JsonNodeFactory.instance.objectNode().put("assetId", assetId.toString()));
        return "quarantined";
    }

    /**
     * Pages in a verified document: a PDF's conservative count as the
     * shared {@code pdf.inspect} reads it, at least one when its page tree
     * is hidden in object streams; an image is one page.
     */
    private static int pageCount(Asset asset, Path file) throws IOException {
        if (!ContentTypes.PDF.equals(asset.contentType())) {
            return 1;
        }
        Integer pages = PdfInspector.inspect(Files.readAllBytes(file)).pageCount();
        return pages == null ? 1 : pages;
    }

    /** Pages of the receipt's other completed, unrejected source documents. */
    private long sourcePages(UUID receiptId, UUID excluding) {
        return jdbc.sql("select coalesce(sum(coalesce(page_count, 1)), 0) from receipt_asset where receipt_id = ? "
                        + "and asset_id <> ? and kind = 'source' and status in ('quarantined', 'available')")
                .params(receiptId, excluding).query(Long.class).single();
    }

    /**
     * Returns whether a member may see a receipt: a receipt linked to a
     * journal of another member's private account is hidden (households).
     *
     * @param workspaceId workspace
     * @param userId      member
     * @param receiptId   receipt
     * @return true when the receipt entity is live and visible to the member
     */
    public boolean isVisible(UUID workspaceId, UUID userId, UUID receiptId) {
        return entities.find(workspaceId, receiptId).filter(e -> e.isLive("receipt"))
                .filter(e -> !visibility.forMember(workspaceId, userId).hides("receipt", receiptId.toString(),
                        e.data()))
                .isPresent();
    }

    /** Signs a short-lived download of an available asset of the workspace. */
    PresignedRequest download(UUID workspaceId, UUID userId, UUID receiptId, UUID assetId) {
        if (entities.find(workspaceId, receiptId).filter(e -> e.isLive("receipt")).isPresent()
                && !isVisible(workspaceId, userId, receiptId)) {
            throw ApiException.notFound("NOT_FOUND", "Not found.");
        }
        Asset asset = jdbc.sql("select * from receipt_asset where asset_id = ? and receipt_id = ? "
                        + "and workspace_id = ?")
                .params(assetId, receiptId, workspaceId).query(ReceiptService::mapAsset).optional()
                .orElseThrow(() -> ApiException.notFound("NOT_FOUND", "Not found."));
        if (!"available".equals(asset.status())) {
            throw ApiException.conflict("ASSET_NOT_AVAILABLE", "The document is not available yet.");
        }
        return storage.presignGet(asset.objectKey());
    }

    /**
     * Scans a quarantined asset and releases or rejects it. Each scan is
     * timed as {@code finance.extraction.latency} with its outcome
     * ({@code available}, {@code rejected} or {@code error}).
     */
    String scan(UUID assetId, DocumentScanner scanner) {
        Optional<Asset> found = findAsset(assetId);
        if (found.isEmpty() || !"quarantined".equals(found.get().status())) {
            return found.map(Asset::status).orElse("missing");
        }
        Asset asset = found.get();
        Path copy = null;
        Timer.Sample sample = Timer.start(meters);
        String outcome = "error";
        try {
            copy = Files.createTempFile("scan-", ".bin");
            try (InputStream in = storage.read(asset.objectKey())) {
                Files.copy(in, copy, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            }
            DocumentScanner.Verdict verdict = scanner.scan(asset.contentType(), copy);
            Timestamp now = Timestamp.from(clock.instant());
            String status = verdict.clean() ? "available" : "rejected";
            if (!verdict.clean()) {
                failureCounter("SCAN_REJECTED").increment();
            }
            int updated = jdbc.sql("update receipt_asset set status = ?, rejection_reason = ?, scanned_at = ?, "
                            + "updated_at = ? where asset_id = ? and status = 'quarantined'")
                    .params(status, verdict.reason(), now, now, assetId).update();
            outcome = status;
            if (updated > 0 && verdict.clean()) {
                events.publishEvent(new ReceiptAssetAvailable(asset.workspaceId(), asset.receiptId(), assetId,
                        asset.kind(), asset.contentType()));
            }
            return status;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        } finally {
            sample.stop(Timer.builder("finance.extraction.latency")
                    .description("Time to extract and check a document in a server-side job, by job and outcome")
                    .tag("job", SCAN_JOB).tag("outcome", outcome).register(meters));
            deleteQuietly(copy);
        }
    }

    /**
     * Lists available assets of a workspace, for exports.
     *
     * @param workspaceId workspace
     * @return assets whose bytes may be released
     */
    public List<AvailableAsset> availableAssets(UUID workspaceId) {
        return jdbc.sql("select * from receipt_asset where workspace_id = ? and status = 'available' "
                        + "order by receipt_id, asset_id")
                .param(workspaceId).query(ReceiptService::mapAsset).list().stream()
                .map(a -> new AvailableAsset(a.receiptId(), a.assetId(), a.kind(), a.contentType(), a.sizeBytes(),
                        a.sha256()))
                .toList();
    }

    /**
     * Opens an available asset of a workspace, for exports.
     *
     * @param workspaceId workspace
     * @param assetId     asset
     * @return the content; the caller closes it
     */
    public InputStream openAvailable(UUID workspaceId, UUID assetId) {
        Asset asset = findAsset(assetId).filter(a -> a.workspaceId().equals(workspaceId))
                .filter(a -> "available".equals(a.status()))
                .orElseThrow(() -> new IllegalArgumentException("Asset not available"));
        return storage.read(asset.objectKey());
    }

    /**
     * An available receipt document.
     *
     * @param receiptId   receipt
     * @param assetId     asset
     * @param kind        {@code source} or {@code derivative}
     * @param contentType content type
     * @param sizeBytes   size
     * @param sha256      checksum
     */
    public record AvailableAsset(UUID receiptId, UUID assetId, String kind, String contentType, long sizeBytes,
            String sha256) {
    }

    /**
     * Removes a workspace's document records (deletion job); the deletion
     * job removes the stored objects with the workspace's key prefix.
     *
     * @param workspaceId workspace being deleted
     * @return records removed
     */
    public int purgeWorkspace(UUID workspaceId) {
        int assets = jdbc.sql("delete from receipt_asset where workspace_id = ?").param(workspaceId).update();
        return assets + jdbc.sql("delete from receipt_document where workspace_id = ?").param(workspaceId).update();
    }

    private void reject(String staging, String code) {
        failureCounter(code).increment();
        storage.delete(staging);
        throw new ApiException(HttpStatus.UNPROCESSABLE_CONTENT, code,
                "The uploaded document does not match its declared checksum, size or type.");
    }

    private Optional<Asset> findAsset(UUID assetId) {
        return jdbc.sql("select * from receipt_asset where asset_id = ?").param(assetId)
                .query(ReceiptService::mapAsset).optional();
    }

    private Counter failureCounter(String reason) {
        return Counter.builder("finance.receipts.upload.failures")
                .description("Receipt uploads rejected at completion or by the scan, by reason")
                .tag("reason", reason).register(meters);
    }

    static String uploadKey(UUID workspaceId, UUID assetId) {
        return "workspaces/" + workspaceId + "/uploads/" + assetId;
    }

    static String assetKey(UUID workspaceId, UUID receiptId, UUID assetId) {
        return "workspaces/" + workspaceId + "/receipts/" + receiptId + "/" + assetId;
    }

    private static ApiException receiptNotFound() {
        return ApiException.notFound("RECEIPT_NOT_FOUND", "Receipt not found.");
    }

    private static void deleteQuietly(Path path) {
        if (path != null) {
            try {
                Files.deleteIfExists(path);
            } catch (IOException ignored) {
                // Temporary file; the operating system cleans up eventually.
            }
        }
    }

    private static Asset mapAsset(java.sql.ResultSet rs, int row) throws java.sql.SQLException {
        return new Asset(rs.getObject("asset_id", UUID.class), rs.getObject("receipt_id", UUID.class),
                rs.getObject("workspace_id", UUID.class), rs.getString("kind"), rs.getString("content_type"),
                rs.getLong("size_bytes"), rs.getString("sha256").trim(), rs.getString("object_key"),
                rs.getString("status"));
    }
}
