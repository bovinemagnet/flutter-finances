package com.paulsnow.finance.server.extraction;

/**
 * An external text extraction service (AUTO 02). Implementations are
 * isolated adapters: they receive one released document and return its
 * recognised text and lines, nothing else. They are never given access to
 * commands, the ledger, matching or any other workspace data, and what they
 * return is treated as untrusted text. No implementation is configured by
 * default; a deployment that offers cloud extraction declares exactly one
 * bean of this type.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public interface ExtractionProvider {

    /** Returns the provider name shown to the owner and recorded with consent. */
    String name();

    /** Returns how long the provider keeps documents, as disclosed to the owner before consent. */
    String disclosedRetention();

    /**
     * Recognises the text of one document.
     *
     * @param contentType confirmed content type of the document
     * @param document    document bytes
     * @return the recognised text and lines
     */
    ExtractedText extract(String contentType, byte[] document);
}
