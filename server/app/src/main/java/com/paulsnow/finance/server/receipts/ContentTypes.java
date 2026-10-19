package com.paulsnow.finance.server.receipts;

import java.util.Set;

/**
 * Accepted document types: exactly those the shared {@code content.sniff}
 * rules recognise ({@link com.paulsnow.finance.core.documents.ContentSniffer}),
 * so a file's declared type is never trusted on its own.
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

    private ContentTypes() {
    }
}
