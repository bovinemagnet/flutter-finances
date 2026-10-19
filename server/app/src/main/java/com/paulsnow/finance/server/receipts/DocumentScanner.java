package com.paulsnow.finance.server.receipts;

import java.nio.file.Path;

/**
 * Decides whether a quarantined document may be released. Deployments can
 * replace the default structural validation with a malware scanning
 * adapter by declaring their own bean of this type; it should run in an
 * isolated worker (SEC 04).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public interface DocumentScanner {

    /**
     * The verdict on one document.
     *
     * @param clean  whether the document may be made available
     * @param reason stable code when rejected, for example {@code ACTIVE_CONTENT}
     */
    record Verdict(boolean clean, String reason) {

        public static Verdict accept() {
            return new Verdict(true, null);
        }

        public static Verdict reject(String reason) {
            return new Verdict(false, reason);
        }
    }

    /**
     * Scans a document whose type has already been confirmed by magic bytes.
     *
     * @param contentType confirmed content type
     * @param file        local copy of the document
     * @return the verdict
     */
    Verdict scan(String contentType, Path file);
}
