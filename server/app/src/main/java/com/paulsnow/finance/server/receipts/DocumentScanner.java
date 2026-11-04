package com.paulsnow.finance.server.receipts;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.Optional;
import java.util.Set;

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

    /**
     * Identifies a document from its leading bytes, whatever it claims to be.
     *
     * @param bytes the document
     * @return its content type, or empty when it is not an accepted type
     */
    static Optional<String> detectContentType(byte[] bytes) {
        if (startsWith(bytes, 0, 0xFF, 0xD8, 0xFF)) {
            return Optional.of(ContentTypes.JPEG);
        }
        if (startsWith(bytes, 0, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)) {
            return Optional.of(ContentTypes.PNG);
        }
        if (startsWith(bytes, pdfHeaderOffset(bytes), '%', 'P', 'D', 'F', '-')) {
            return Optional.of(ContentTypes.PDF);
        }
        if (bytes.length >= 12 && startsWith(bytes, 4, 'f', 't', 'y', 'p')) {
            String brand = new String(bytes, 8, 4, StandardCharsets.US_ASCII);
            if (Set.of("heic", "heix", "hevc", "heim", "heis", "mif1").contains(brand)) {
                return Optional.of(ContentTypes.HEIC);
            }
        }
        return Optional.empty();
    }

    /**
     * Skips a byte order mark and whitespace, the only things accepted before a
     * PDF header. Anything else could be another file carrying a PDF header
     * further in, such as an executable.
     */
    private static int pdfHeaderOffset(byte[] bytes) {
        int offset = startsWith(bytes, 0, 0xEF, 0xBB, 0xBF) ? 3 : 0;
        while (offset < bytes.length && (bytes[offset] == ' ' || bytes[offset] == '\t' || bytes[offset] == '\r'
                || bytes[offset] == '\n')) {
            offset++;
        }
        return offset;
    }

    private static boolean startsWith(byte[] bytes, int offset, int... expected) {
        if (bytes.length < offset + expected.length) {
            return false;
        }
        for (int i = 0; i < expected.length; i++) {
            if ((bytes[offset + i] & 0xFF) != expected[i]) {
                return false;
            }
        }
        return true;
    }
}
