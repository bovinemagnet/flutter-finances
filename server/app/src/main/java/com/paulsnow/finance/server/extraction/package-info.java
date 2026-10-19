/**
 * Optional cloud extraction of receipt text (P1, AUTO 02, SEC 05). An owner
 * records the workspace's consent naming the provider and its disclosed
 * retention; only while that consent stands does a released receipt
 * document go to the isolated
 * {@link com.paulsnow.finance.server.extraction.ExtractionProvider}, which
 * returns OCR text and lines and nothing else. Results are untrusted data:
 * they are stored and served as text, never parsed into commands, amounts
 * or matches. Withdrawing consent, deleting the receipt or deleting the
 * workspace deletes them. No provider is configured by default.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Extraction")
package com.paulsnow.finance.server.extraction;
