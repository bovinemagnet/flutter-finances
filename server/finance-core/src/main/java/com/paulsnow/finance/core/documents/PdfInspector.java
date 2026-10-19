package com.paulsnow.finance.core.documents;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Learns what it can about a PDF from its raw syntax, without rendering it
 * or decompressing streams (REC 05; fixture {@code pdf.inspect}). The page
 * count is conservative: the larger of the visible {@code /Type /Page}
 * objects and the largest {@code /Count} of a page tree node, and unknown
 * when the page tree is hidden in compressed object streams.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class PdfInspector {

    // Whitespace as the client's regular expressions define it in Latin-1.
    private static final String WS = "[\\t\\n\\x0B\\f\\r \\u00A0]";
    private static final Pattern PAGE_OBJECT = Pattern.compile("/Type" + WS + "*/Page(?![A-Za-z])");
    private static final Pattern COUNT = Pattern.compile("/Count" + WS + "+(\\d+)");
    private static final Pattern ENCRYPT = Pattern.compile("/Encrypt(?![A-Za-z])");
    private static final Pattern XREF_STREAM = Pattern.compile("/Type" + WS + "*/XRef(?![A-Za-z])");

    /**
     * What a PDF reveals without rendering.
     *
     * @param readable  false when truncated or without recognisable structure
     * @param encrypted whether a trailer or cross-reference stream names {@code /Encrypt}
     * @param pageCount conservative page count, or null when hidden in object streams
     */
    public record PdfInfo(boolean readable, boolean encrypted, Integer pageCount) {
    }

    private PdfInspector() {
    }

    /**
     * Inspects PDF bytes.
     *
     * @param bytes the whole file
     * @return what could be learnt
     */
    public static PdfInfo inspect(byte[] bytes) {
        String text = new String(bytes, StandardCharsets.ISO_8859_1);
        int tailStart = Math.max(0, text.length() - 1024);
        boolean hasEof = text.indexOf("%%EOF", tailStart) >= 0;
        boolean hasStartXref = text.contains("startxref");
        boolean encrypted = trailerDictionaries(text).stream().anyMatch(d -> ENCRYPT.matcher(d).find());

        int pageObjects = 0;
        Matcher pages = PAGE_OBJECT.matcher(text);
        while (pages.find()) {
            pageObjects++;
        }
        long maxCount = 0;
        Matcher counts = COUNT.matcher(text);
        while (counts.find()) {
            maxCount = Math.max(maxCount, parse(counts.group(1)));
        }
        int visiblePages = (int) Math.min(Integer.MAX_VALUE, Math.max(pageObjects, maxCount));
        boolean hiddenPageTree = visiblePages == 0 && text.contains("/ObjStm");
        boolean readable = hasEof && hasStartXref && (visiblePages > 0 || hiddenPageTree);
        return new PdfInfo(readable, encrypted, visiblePages > 0 ? visiblePages : null);
    }

    private static long parse(String digits) {
        try {
            return Long.parseLong(digits);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /** Every classic trailer dictionary and every cross-reference stream dictionary. */
    private static List<String> trailerDictionaries(String text) {
        List<String> dictionaries = new ArrayList<>();
        int at = text.indexOf("trailer");
        while (at >= 0) {
            int end = text.indexOf("startxref", at);
            dictionaries.add(text.substring(at, end < 0 ? text.length() : end));
            at = text.indexOf("trailer", at + 7);
        }
        Matcher xref = XREF_STREAM.matcher(text);
        while (xref.find()) {
            int objStart = text.lastIndexOf("obj", xref.start());
            int streamStart = text.indexOf("stream", xref.end());
            dictionaries.add(text.substring(objStart < 0 ? xref.start() : objStart,
                    streamStart < 0 ? text.length() : streamStart));
        }
        return dictionaries;
    }
}
