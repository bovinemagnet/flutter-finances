package com.paulsnow.finance.server.sync;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;
import java.util.UUID;

import com.paulsnow.finance.server.common.ApiException;

/**
 * Opaque change feed cursors. A cursor records the workspace, the last
 * change sequence the client holds and when it was issued; clients must
 * treat it as an opaque string.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class CursorCodec {

    private static final String VERSION = "1";

    /**
     * A decoded cursor.
     *
     * @param workspaceId workspace
     * @param sequence    last change sequence held, 0 for none
     * @param issuedAt    when the server issued it, to the microsecond
     */
    record Cursor(UUID workspaceId, long sequence, Instant issuedAt) {
    }

    private CursorCodec() {
    }

    static String encode(UUID workspaceId, long sequence, Instant issuedAt) {
        long micros = java.time.temporal.ChronoUnit.MICROS.between(Instant.EPOCH, issuedAt);
        String raw = VERSION + ":" + workspaceId + ":" + sequence + ":" + micros;
        return Base64.getUrlEncoder().withoutPadding().encodeToString(raw.getBytes(StandardCharsets.US_ASCII));
    }

    /**
     * Decodes a cursor for {@code workspaceId}.
     *
     * @param text        cursor text
     * @param workspaceId expected workspace
     * @return the cursor
     * @throws ApiException 400 {@code INVALID_CURSOR}
     */
    static Cursor decode(String text, UUID workspaceId) {
        try {
            String raw = new String(Base64.getUrlDecoder().decode(text), StandardCharsets.US_ASCII);
            String[] parts = raw.split(":");
            if (parts.length != 4 || !VERSION.equals(parts[0])) {
                throw invalid();
            }
            Cursor cursor = new Cursor(UUID.fromString(parts[1]), Long.parseLong(parts[2]),
                    Instant.EPOCH.plus(Long.parseLong(parts[3]), java.time.temporal.ChronoUnit.MICROS));
            if (!cursor.workspaceId().equals(workspaceId) || cursor.sequence() < 0) {
                throw invalid();
            }
            return cursor;
        } catch (IllegalArgumentException e) {
            throw invalid();
        }
    }

    private static ApiException invalid() {
        return ApiException.badRequest("INVALID_CURSOR", "The cursor is not valid for this workspace.");
    }
}
