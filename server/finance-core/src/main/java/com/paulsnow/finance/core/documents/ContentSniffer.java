package com.paulsnow.finance.core.documents;

import java.nio.charset.StandardCharsets;
import java.util.Optional;
import java.util.Set;

/**
 * Identifies a document's real format from its magic bytes, ignoring any
 * file name or claimed type (SEC 04; fixture {@code content.sniff}):
 * <ul>
 * <li>JPEG: {@code FF D8 FF} at offset 0.</li>
 * <li>PNG: the 8-byte PNG signature at offset 0.</li>
 * <li>HEIC/HEIF: {@code ftyp} at offset 4 followed by a brand; HEVC brands
 * are HEIC, {@code mif1} and {@code msf1} are HEIF, any other brand is
 * unsupported.</li>
 * <li>PDF: {@code %PDF-} starting at any offset from 0 to 1024.</li>
 * </ul>
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class ContentSniffer {

    /** How far into a file a PDF header may start. */
    public static final int PDF_HEADER_SEARCH_WINDOW = 1024;

    /** Bytes {@link #sniff(byte[])} needs to see at most. */
    public static final int SNIFF_BYTES = PDF_HEADER_SEARCH_WINDOW + 5;

    private static final Set<String> HEIC_BRANDS = Set.of("heic", "heix", "hevc", "hevx", "heim", "heis", "hevm",
            "hevs");

    private static final Set<String> HEIF_BRANDS = Set.of("mif1", "msf1");

    private static final byte[] JPEG = { (byte) 0xFF, (byte) 0xD8, (byte) 0xFF };

    private static final byte[] PNG = { (byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    private static final byte[] PDF = { 0x25, 0x50, 0x44, 0x46, 0x2D };

    private ContentSniffer() {
    }

    /**
     * Identifies the format of a document from its first bytes (at least
     * {@link #SNIFF_BYTES} when available).
     *
     * @param bytes the start of the file
     * @return the format, or empty when empty or unsupported
     */
    public static Optional<DocumentContentType> sniff(byte[] bytes) {
        if (startsWith(bytes, JPEG)) {
            return Optional.of(DocumentContentType.JPEG);
        }
        if (startsWith(bytes, PNG)) {
            return Optional.of(DocumentContentType.PNG);
        }
        if (bytes.length >= 12 && ascii(bytes, 4).equals("ftyp")) {
            String brand = ascii(bytes, 8);
            if (HEIC_BRANDS.contains(brand)) {
                return Optional.of(DocumentContentType.HEIC);
            }
            if (HEIF_BRANDS.contains(brand)) {
                return Optional.of(DocumentContentType.HEIF);
            }
            return Optional.empty();
        }
        int limit = Math.min(bytes.length, SNIFF_BYTES);
        outer:
        for (int i = 0; i + PDF.length <= limit; i++) {
            for (int j = 0; j < PDF.length; j++) {
                if (bytes[i + j] != PDF[j]) {
                    continue outer;
                }
            }
            return Optional.of(DocumentContentType.PDF);
        }
        return Optional.empty();
    }

    /**
     * Returns the sniffed media type, for example {@code image/png}.
     *
     * @param bytes the start of the file
     * @return the media type, or empty when empty or unsupported
     */
    public static Optional<String> sniffMimeType(byte[] bytes) {
        return sniff(bytes).map(DocumentContentType::mimeType);
    }

    private static boolean startsWith(byte[] bytes, byte[] prefix) {
        if (bytes.length < prefix.length) {
            return false;
        }
        for (int i = 0; i < prefix.length; i++) {
            if (bytes[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }

    private static String ascii(byte[] bytes, int offset) {
        return new String(bytes, offset, 4, StandardCharsets.ISO_8859_1);
    }
}
