package com.paulsnow.finance.server.receipts;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.charset.StandardCharsets;
import java.util.Optional;

import org.junit.jupiter.api.Test;

/**
 * Identifying a document from its bytes (SEC 04).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class DocumentScannerTest {

    private static byte[] bytes(int... values) {
        byte[] result = new byte[values.length];
        for (int i = 0; i < values.length; i++) {
            result[i] = (byte) values[i];
        }
        return result;
    }

    private static byte[] ftyp(String brand) {
        byte[] result = new byte[12];
        System.arraycopy("ftyp".getBytes(StandardCharsets.US_ASCII), 0, result, 4, 4);
        System.arraycopy(brand.getBytes(StandardCharsets.US_ASCII), 0, result, 8, 4);
        return result;
    }

    @Test
    void detectsTypesFromBytes() {
        assertThat(DocumentScanner.detectContentType(bytes(0xFF, 0xD8, 0xFF, 0xE0))).contains("image/jpeg");
        assertThat(DocumentScanner.detectContentType(bytes(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)))
                .contains("image/png");
        assertThat(DocumentScanner.detectContentType("%PDF-1.7".getBytes(StandardCharsets.US_ASCII)))
                .contains("application/pdf");
        for (String brand : new String[] { "heic", "heix", "hevc", "heim", "heis", "mif1" }) {
            assertThat(DocumentScanner.detectContentType(ftyp(brand))).as(brand).contains("image/heic");
        }
    }

    @Test
    void refusesWhatItCannotIdentify() {
        assertThat(DocumentScanner.detectContentType(new byte[0])).isEqualTo(Optional.empty());
        assertThat(DocumentScanner.detectContentType(bytes(0x4D, 0x5A, 0x90, 0x00))).isEqualTo(Optional.empty());
        assertThat(DocumentScanner.detectContentType(ftyp("mp42"))).isEqualTo(Optional.empty());
        assertThat(DocumentScanner.detectContentType(bytes(0x89, 0x50))).isEqualTo(Optional.empty());
    }

    @Test
    void allowsOnlyWhitespaceOrAByteOrderMarkBeforeAPdfHeader() {
        assertThat(DocumentScanner.detectContentType("\n\r\t %PDF-1.7".getBytes(StandardCharsets.US_ASCII)))
                .contains("application/pdf");
        byte[] marked = new byte[8];
        marked[0] = (byte) 0xEF;
        marked[1] = (byte) 0xBB;
        marked[2] = (byte) 0xBF;
        System.arraycopy("%PDF-".getBytes(StandardCharsets.US_ASCII), 0, marked, 3, 5);
        assertThat(DocumentScanner.detectContentType(marked)).contains("application/pdf");
    }

    @Test
    void refusesAnExecutableCarryingAPdfHeader() {
        byte[] polyglot = new byte[1024];
        polyglot[0] = 0x4D;
        polyglot[1] = 0x5A;
        System.arraycopy("%PDF-".getBytes(StandardCharsets.US_ASCII), 0, polyglot, 512, 5);
        assertThat(DocumentScanner.detectContentType(polyglot)).isEqualTo(Optional.empty());
    }
}
