package com.paulsnow.finance.server.receipts;

import java.nio.charset.StandardCharsets;
import java.util.Set;

/**
 * Accepted document types and recognition by magic bytes, so a file's
 * declared type is never trusted on its own. Agrees with the shared
 * {@code content.sniff} fixture operation.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class ContentTypes {

    static final String JPEG = "image/jpeg";
    static final String PNG = "image/png";
    static final String HEIC = "image/heic";
    static final String HEIF = "image/heif";
    static final String PDF = "application/pdf";

    static final Set<String> ACCEPTED = Set.of(JPEG, PNG, HEIC, HEIF, PDF);

    /** Bytes needed to recognise every accepted type ({@code %PDF-} may start at offset 1024). */
    static final int HEADER_LENGTH = 1029;

    private static final Set<String> HEIC_BRANDS = Set.of("heic", "heix", "hevc", "hevx", "heim", "heis", "hevm",
            "hevs");
    private static final Set<String> HEIF_BRANDS = Set.of("mif1", "msf1");

    private ContentTypes() {
    }

    /**
     * Recognises a document from its first bytes.
     *
     * @param header the first {@link #HEADER_LENGTH} bytes, or the whole file when shorter
     * @return the content type, or null when empty or not an accepted type
     */
    static String sniff(byte[] header) {
        if (startsWith(header, 0, 0xFF, 0xD8, 0xFF)) {
            return JPEG;
        }
        if (startsWith(header, 0, 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A)) {
            return PNG;
        }
        if (startsWith(header, 4, 'f', 't', 'y', 'p') && header.length >= 12) {
            String brand = new String(header, 8, 4, StandardCharsets.US_ASCII);
            if (HEIC_BRANDS.contains(brand)) {
                return HEIC;
            }
            if (HEIF_BRANDS.contains(brand)) {
                return HEIF;
            }
            return null;
        }
        for (int offset = 0; offset <= 1024; offset++) {
            if (startsWith(header, offset, '%', 'P', 'D', 'F', '-')) {
                return PDF;
            }
        }
        return null;
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
