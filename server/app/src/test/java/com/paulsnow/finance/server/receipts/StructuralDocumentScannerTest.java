package com.paulsnow.finance.server.receipts;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Image bounds of the structural scan (REC 05, SEC 04): 16,384 pixels per
 * side and 50 megapixels, as the client's {@code ContentLimits}.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class StructuralDocumentScannerTest {

    private final StructuralDocumentScanner scanner = new StructuralDocumentScanner(16_384, 50_000_000L);

    @TempDir
    Path dir;

    @Test
    void acceptsImagesWithinBothBounds() throws IOException {
        assertThat(scan(ContentTypes.JPEG, jpeg(16_384, 3_000)).clean()).isTrue();
        assertThat(scan(ContentTypes.PNG, png(3_000, 16_384)).clean()).isTrue();
    }

    @Test
    void rejectsAnImageWiderOrTallerThanTheSideLimit() throws IOException {
        DocumentScanner.Verdict wide = scan(ContentTypes.JPEG, jpeg(16_385, 10));
        assertThat(wide.clean()).isFalse();
        assertThat(wide.reason()).isEqualTo("IMAGE_TOO_LARGE");
        assertThat(scan(ContentTypes.PNG, png(10, 16_385)).reason()).isEqualTo("IMAGE_TOO_LARGE");
    }

    @Test
    void rejectsAnImageOverFiftyMegapixelsWithinTheSideLimit() throws IOException {
        DocumentScanner.Verdict area = scan(ContentTypes.PNG, png(8_000, 7_000));
        assertThat(area.clean()).isFalse();
        assertThat(area.reason()).isEqualTo("IMAGE_TOO_LARGE");
        assertThat(scan(ContentTypes.JPEG, jpeg(10_000, 5_000)).clean()).isTrue();
    }

    private DocumentScanner.Verdict scan(String contentType, byte[] bytes) throws IOException {
        Path file = Files.write(dir.resolve("doc"), bytes);
        return scanner.scan(contentType, file);
    }

    /** SOI, a baseline frame header with the given size, and EOI. */
    private static byte[] jpeg(int width, int height) {
        return new byte[] { (byte) 0xFF, (byte) 0xD8, (byte) 0xFF, (byte) 0xC0, 0x00, 0x11, 0x08,
                (byte) (height >> 8), (byte) height, (byte) (width >> 8), (byte) width, 0x03, 0x01, 0x22, 0x00,
                0x02, 0x11, 0x01, 0x03, 0x11, 0x01, (byte) 0xFF, (byte) 0xD9 };
    }

    /** Signature, an IHDR chunk with the given size and an IEND chunk. */
    private static byte[] png(int width, int height) {
        byte[] bytes = new byte[8 + 25 + 12];
        byte[] signature = { (byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        System.arraycopy(signature, 0, bytes, 0, 8);
        bytes[11] = 13;
        System.arraycopy("IHDR".getBytes(java.nio.charset.StandardCharsets.US_ASCII), 0, bytes, 12, 4);
        putInt(bytes, 16, width);
        putInt(bytes, 20, height);
        bytes[24] = 8;
        bytes[25] = 2;
        System.arraycopy("IEND".getBytes(java.nio.charset.StandardCharsets.US_ASCII), 0, bytes, 37, 4);
        return bytes;
    }

    private static void putInt(byte[] bytes, int offset, int value) {
        bytes[offset] = (byte) (value >> 24);
        bytes[offset + 1] = (byte) (value >> 16);
        bytes[offset + 2] = (byte) (value >> 8);
        bytes[offset + 3] = (byte) value;
    }
}
