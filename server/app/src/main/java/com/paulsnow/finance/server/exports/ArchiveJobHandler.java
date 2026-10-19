package com.paulsnow.finance.server.exports;

import java.io.FilterOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.DigestOutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.Timestamp;
import java.time.Clock;
import java.util.HexFormat;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.jobs.Job;
import com.paulsnow.finance.server.jobs.JobHandler;
import com.paulsnow.finance.server.jobs.PermanentJobFailure;
import com.paulsnow.finance.server.receipts.ReceiptService;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.storage.Retention;
import com.paulsnow.finance.server.sync.EntityReader;
import com.paulsnow.finance.server.sync.Visibility;
import com.paulsnow.finance.server.sync.VisibilityService;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;
import com.paulsnow.finance.server.workspace.WorkspaceInfo;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Writes the export archive (ZIP):
 * <ul>
 * <li>{@code entities/<entityType>.json}: every live entity as
 * {@code {entityType, entityId, revision, data}}, in protocol JSON;</li>
 * <li>{@code receipts/<receiptId>/<assetId>}: original bytes of every
 * available receipt document;</li>
 * <li>{@code manifest.json}: schema version, workspace currency and
 * timezone, effective date semantics, the accepted change sequence
 * (DATA 03), counts, relationships, and the path, size and SHA-256 of every
 * other file.</li>
 * </ul>
 * Re-running the job rebuilds the same archive, so it is safe to retry.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ArchiveJobHandler implements JobHandler {

    private final JdbcClient jdbc;
    private final EntityReader entities;
    private final ReceiptService receipts;
    private final WorkspaceDirectory workspaces;
    private final ObjectStorage storage;
    private final JsonMapper json;
    private final Clock clock;
    private final VisibilityService visibility;

    ArchiveJobHandler(JdbcClient jdbc, EntityReader entities, ReceiptService receipts, WorkspaceDirectory workspaces,
            ObjectStorage storage, JsonMapper json, Clock clock, VisibilityService visibility) {
        this.visibility = visibility;
        this.jdbc = jdbc;
        this.entities = entities;
        this.receipts = receipts;
        this.workspaces = workspaces;
        this.storage = storage;
        this.json = json;
        this.clock = clock;
    }

    @Override
    public String type() {
        return ExportService.ARCHIVE_JOB;
    }

    @Override
    public JsonNode handle(Job job) {
        UUID workspaceId = job.workspaceId();
        UUID exportId = UUID.fromString(job.payload().path("exportId").asString());
        WorkspaceInfo workspace = workspaces.findActive(workspaceId)
                .orElseThrow(() -> new PermanentJobFailure("WORKSPACE_NOT_FOUND"));
        Path archive = null;
        try {
            archive = Files.createTempFile("export-", ".zip");
            long accepted = entities.headSequence(workspaceId);
            String requestedBy = job.payload().path("requestedBy").asString(null);
            Visibility sees = visibility.forMember(workspaceId,
                    requestedBy == null ? null : UUID.fromString(requestedBy));
            write(archive, workspace, exportId, accepted, sees);
            String sha256 = sha256(archive);
            long size = Files.size(archive);
            storage.put(ExportService.objectKey(workspaceId, exportId), archive, "application/zip",
                    Retention.EXPORT);
            jdbc.sql("update export_archive set status = 'ready', object_key = ?, sha256 = ?, size_bytes = ?, "
                            + "accepted_through = ?, completed_at = ? where id = ? and workspace_id = ?")
                    .params(ExportService.objectKey(workspaceId, exportId), sha256, size, accepted,
                            Timestamp.from(clock.instant()), exportId, workspaceId)
                    .update();
            return JsonNodeFactory.instance.objectNode().put("exportId", exportId.toString()).put("status", "ready")
                    .put("sizeBytes", size).put("sha256", sha256);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        } finally {
            if (archive != null) {
                try {
                    Files.deleteIfExists(archive);
                } catch (IOException ignored) {
                    // Temporary file.
                }
            }
        }
    }

    private void write(Path archive, WorkspaceInfo workspace, UUID exportId, long accepted, Visibility sees)
            throws IOException {
        java.util.Set<UUID> hiddenReceipts = new java.util.HashSet<>();
        ArrayNode files = JsonNodeFactory.instance.arrayNode();
        ArrayNode relationships = JsonNodeFactory.instance.arrayNode();
        Map<String, Integer> counts = new TreeMap<>();
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(archive))) {
            EntityFileWriter writer = new EntityFileWriter(zip, files);
            entities.forEachLive(workspace.id(), entity -> {
                if (sees.hides(entity.entityType(), entity.entityId().toString(), entity.data())) {
                    // Only what the requesting member may see (households).
                    if ("receipt".equals(entity.entityType())) {
                        hiddenReceipts.add(entity.entityId());
                    }
                    return;
                }
                counts.merge(entity.entityType(), 1, Integer::sum);
                ObjectNode item = JsonNodeFactory.instance.objectNode();
                item.put("entityType", entity.entityType());
                item.put("entityId", entity.entityId().toString());
                item.put("revision", entity.revision());
                item.set("data", entity.data());
                writer.write(entity.entityType(), json.writeValueAsBytes(item));
                if ("journal".equals(entity.entityType())) {
                    for (String link : new String[] { "reversalOf", "replaces", "refundOf" }) {
                        JsonNode target = entity.data().path(link);
                        if (target.isString()) {
                            relationships.addObject().put("from", "journal:" + entity.entityId())
                                    .put("kind", link).put("to", "journal:" + target.asString());
                        }
                    }
                }
            });
            writer.close();
            int assets = 0;
            for (ReceiptService.AvailableAsset asset : receipts.availableAssets(workspace.id())) {
                if (hiddenReceipts.contains(asset.receiptId())) {
                    continue;
                }
                String path = "receipts/" + asset.receiptId() + "/" + asset.assetId();
                try (InputStream in = receipts.openAvailable(workspace.id(), asset.assetId())) {
                    Hashed hashed = entry(zip, path, out -> in.transferTo(out));
                    files.addObject().put("path", path).put("sizeBytes", hashed.size()).put("sha256", hashed.sha256())
                            .put("contentType", asset.contentType()).put("kind", asset.kind());
                }
                relationships.addObject().put("from", "document:" + asset.assetId()).put("kind", "assetOf")
                        .put("to", "receipt:" + asset.receiptId());
                assets++;
            }
            ObjectNode manifest = JsonNodeFactory.instance.objectNode();
            manifest.put("format", "flutter-finances-export");
            manifest.put("schemaVersion", 1);
            manifest.put("exportId", exportId.toString());
            manifest.put("createdAt", clock.instant().toString());
            ObjectNode info = manifest.putObject("workspace");
            info.put("id", workspace.id().toString());
            info.put("name", workspace.name());
            info.put("currency", workspace.currency().code());
            info.put("currencyExponent", workspace.currency().exponent());
            info.put("timezone", workspace.timezone().getId());
            manifest.put("effectiveDates", "Financial effective dates are local dates (YYYY-MM-DD) in the workspace "
                    + "timezone; technical instants are UTC ISO 8601; money is integer minor units.");
            manifest.put("acceptedSequence", accepted);
            ObjectNode countNode = manifest.putObject("counts");
            counts.forEach(countNode::put);
            countNode.put("receiptAssets", assets);
            manifest.set("files", files);
            manifest.set("relationships", relationships);
            zip.putNextEntry(new ZipEntry("manifest.json"));
            zip.write(json.writerWithDefaultPrettyPrinter().writeValueAsBytes(manifest));
            zip.closeEntry();
        }
    }

    /** Streams entities of one type at a time into {@code entities/<type>.json}. */
    private final class EntityFileWriter {
        private final ZipOutputStream zip;
        private final ArrayNode files;
        private String type;
        private DigestOutputStream out;
        private long size;
        private boolean first;

        EntityFileWriter(ZipOutputStream zip, ArrayNode files) {
            this.zip = zip;
            this.files = files;
        }

        void write(String entityType, byte[] item) {
            try {
                if (!entityType.equals(type)) {
                    close();
                    type = entityType;
                    zip.putNextEntry(new ZipEntry(path()));
                    out = new DigestOutputStream(new NonClosing(zip), MessageDigest.getInstance("SHA-256"));
                    size = 0;
                    first = true;
                    emit("[".getBytes(StandardCharsets.UTF_8));
                }
                if (!first) {
                    emit(",\n".getBytes(StandardCharsets.UTF_8));
                }
                first = false;
                emit(item);
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            } catch (NoSuchAlgorithmException e) {
                throw new IllegalStateException(e);
            }
        }

        void close() throws IOException {
            if (type == null) {
                return;
            }
            emit("]".getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();
            files.addObject().put("path", path()).put("sizeBytes", size)
                    .put("sha256", HexFormat.of().formatHex(out.getMessageDigest().digest()));
            type = null;
        }

        private void emit(byte[] bytes) throws IOException {
            out.write(bytes);
            size += bytes.length;
        }

        private String path() {
            return "entities/" + type + ".json";
        }
    }

    private record Hashed(long size, String sha256) {
    }

    @FunctionalInterface
    private interface Body {
        long writeTo(OutputStream out) throws IOException;
    }

    private static Hashed entry(ZipOutputStream zip, String path, Body body) throws IOException {
        try {
            zip.putNextEntry(new ZipEntry(path));
            DigestOutputStream out = new DigestOutputStream(new NonClosing(zip), MessageDigest.getInstance("SHA-256"));
            long size = body.writeTo(out);
            zip.closeEntry();
            return new Hashed(size, HexFormat.of().formatHex(out.getMessageDigest().digest()));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static String sha256(Path file) throws IOException {
        try (InputStream in = Files.newInputStream(file)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[64 * 1024];
            int read;
            while ((read = in.read(buffer)) > 0) {
                digest.update(buffer, 0, read);
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** Keeps entry streams from closing the archive. */
    private static final class NonClosing extends FilterOutputStream {
        NonClosing(OutputStream out) {
            super(out);
        }

        @Override
        public void write(byte[] b, int off, int len) throws IOException {
            out.write(b, off, len);
        }

        @Override
        public void close() {
            // The ZIP stream stays open for the next entry.
        }
    }
}
