package com.paulsnow.finance.core.imports;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/**
 * Text encodings offered for CSV import (IMP 01), with decoding that
 * matches the Dart client.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum TextEncoding {
    UTF8("utf8"),
    WINDOWS1252("windows1252"),
    LATIN1("latin1");

    /** Windows-1252 code points for bytes 0x80 to 0x9F; undefined bytes keep their C1 value. */
    private static final int[] CP1252_HIGH = {
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    };

    private final String wire;

    TextEncoding(String wire) {
        this.wire = wire;
    }

    /** Returns the wire name. */
    public String wire() {
        return wire;
    }

    /**
     * Resolves a wire name.
     *
     * @param wire {@code utf8}, {@code windows1252} or {@code latin1}
     * @return the encoding
     */
    public static TextEncoding fromWire(String wire) {
        for (TextEncoding encoding : values()) {
            if (encoding.wire.equals(wire)) {
                return encoding;
            }
        }
        throw new IllegalArgumentException("Unknown encoding");
    }

    /**
     * Decodes bytes. A UTF-8 byte order mark is removed; malformed UTF-8 is
     * rejected rather than guessed.
     *
     * @param bytes file content
     * @return the text
     * @throws IllegalArgumentException when the bytes are not valid in this encoding
     */
    public String decode(byte[] bytes) {
        return switch (this) {
            case UTF8 -> {
                int start = bytes.length >= 3 && (bytes[0] & 0xff) == 0xEF && (bytes[1] & 0xff) == 0xBB
                        && (bytes[2] & 0xff) == 0xBF ? 3 : 0;
                try {
                    yield StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                            .onUnmappableCharacter(CodingErrorAction.REPORT)
                            .decode(ByteBuffer.wrap(bytes, start, bytes.length - start)).toString();
                } catch (CharacterCodingException e) {
                    throw new IllegalArgumentException("The file is not valid UTF-8 text", e);
                }
            }
            case LATIN1 -> new String(bytes, StandardCharsets.ISO_8859_1);
            case WINDOWS1252 -> {
                StringBuilder text = new StringBuilder(bytes.length);
                for (byte b : bytes) {
                    int value = b & 0xff;
                    text.append((char) (value >= 0x80 && value <= 0x9F ? CP1252_HIGH[value - 0x80] : value));
                }
                yield text.toString();
            }
        };
    }
}
