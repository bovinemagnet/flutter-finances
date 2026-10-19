package com.paulsnow.finance.server.receipts;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Pattern;

/**
 * The default {@link DocumentScanner}: structural validation without
 * decoding pixels or rendering pages. It rejects truncated files, images
 * beyond the configured dimensions, malformed structures and PDFs with
 * active content (scripts, launch actions, embedded files, XFA forms or rich
 * media). It is not a malware scanner; deployments that need one provide
 * their own {@code DocumentScanner} bean.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class StructuralDocumentScanner implements DocumentScanner {

    private static final Pattern ACTIVE_PDF_CONTENT = Pattern
            .compile("/(JavaScript|JS|Launch|EmbeddedFiles?|XFA|RichMedia)(?![A-Za-z0-9])");

    private final int maxDimension;

    StructuralDocumentScanner(int maxDimension) {
        this.maxDimension = maxDimension;
    }

    @Override
    public Verdict scan(String contentType, Path file) {
        byte[] bytes;
        try {
            bytes = Files.readAllBytes(file);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        return switch (contentType) {
            case ContentTypes.PDF -> pdf(bytes);
            case ContentTypes.PNG -> png(bytes);
            case ContentTypes.JPEG -> jpeg(bytes);
            case ContentTypes.HEIC, ContentTypes.HEIF -> heif(bytes);
            default -> Verdict.reject("UNSUPPORTED_TYPE");
        };
    }

    private static Verdict pdf(byte[] bytes) {
        String text = new String(bytes, StandardCharsets.ISO_8859_1);
        int tail = Math.max(0, text.length() - 2048);
        if (!text.substring(tail).contains("%%EOF")) {
            return Verdict.reject("TRUNCATED");
        }
        if (ACTIVE_PDF_CONTENT.matcher(text).find()) {
            return Verdict.reject("ACTIVE_CONTENT");
        }
        return Verdict.accept();
    }

    private Verdict png(byte[] bytes) {
        if (bytes.length < 33 || !"IHDR".equals(ascii(bytes, 12, 4))) {
            return Verdict.reject("MALFORMED");
        }
        return dimensions(readInt(bytes, 16), readInt(bytes, 20),
                ascii(bytes, bytes.length - 8, 4).equals("IEND"));
    }

    private Verdict jpeg(byte[] bytes) {
        int end = bytes.length;
        while (end > 2 && bytes[end - 1] == 0) {
            end--;
        }
        boolean complete = end >= 4 && (bytes[end - 2] & 0xFF) == 0xFF && (bytes[end - 1] & 0xFF) == 0xD9;
        int offset = 2;
        while (offset + 9 < bytes.length) {
            if ((bytes[offset] & 0xFF) != 0xFF) {
                return Verdict.reject("MALFORMED");
            }
            int marker = bytes[offset + 1] & 0xFF;
            if (marker == 0xFF) {
                offset++;
                continue;
            }
            int length = ((bytes[offset + 2] & 0xFF) << 8) | (bytes[offset + 3] & 0xFF);
            boolean startOfFrame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8
                    && marker != 0xCC;
            if (startOfFrame) {
                int height = ((bytes[offset + 5] & 0xFF) << 8) | (bytes[offset + 6] & 0xFF);
                int width = ((bytes[offset + 7] & 0xFF) << 8) | (bytes[offset + 8] & 0xFF);
                return dimensions(width, height, complete);
            }
            if (marker == 0xDA || length < 2) {
                break;
            }
            offset += 2 + length;
        }
        return Verdict.reject("MALFORMED");
    }

    private static Verdict heif(byte[] bytes) {
        long boxSize = bytes.length >= 4 ? Integer.toUnsignedLong(readInt(bytes, 0)) : 0;
        return boxSize >= 16 && boxSize <= bytes.length ? Verdict.accept() : Verdict.reject("MALFORMED");
    }

    private Verdict dimensions(long width, long height, boolean complete) {
        if (width <= 0 || height <= 0) {
            return Verdict.reject("MALFORMED");
        }
        if (width > maxDimension || height > maxDimension) {
            return Verdict.reject("IMAGE_TOO_LARGE");
        }
        return complete ? Verdict.accept() : Verdict.reject("TRUNCATED");
    }

    private static int readInt(byte[] bytes, int offset) {
        return ((bytes[offset] & 0xFF) << 24) | ((bytes[offset + 1] & 0xFF) << 16) | ((bytes[offset + 2] & 0xFF) << 8)
                | (bytes[offset + 3] & 0xFF);
    }

    private static String ascii(byte[] bytes, int offset, int length) {
        if (offset < 0 || offset + length > bytes.length) {
            return "";
        }
        return new String(bytes, offset, length, StandardCharsets.US_ASCII);
    }
}
