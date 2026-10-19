/**
 * Receipt documents (SYNC 05, SEC 04): short-lived upload intents, direct
 * upload to private object storage, completion that verifies ownership,
 * size, checksum and content by magic bytes, quarantine until a
 * {@link com.paulsnow.finance.server.receipts.DocumentScanner} clears the
 * file, and workspace-scoped download links.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Receipts")
package com.paulsnow.finance.server.receipts;
