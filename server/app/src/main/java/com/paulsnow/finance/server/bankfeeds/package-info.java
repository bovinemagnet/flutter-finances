/**
 * The bank feed adapter boundary (P1, BANK 01-03). Providers sit behind
 * {@link com.paulsnow.finance.server.bankfeeds.BankFeedProvider}; their
 * tokens stay on the server, AES-GCM encrypted with a configured key.
 * Connections record institution, shared accounts, data scope, purpose,
 * consent status and expiry, last successful refresh and error state.
 * Webhooks are verified by HMAC-SHA256 signature, timestamp tolerance and
 * delivery id. Provider transactions become provider records, separate from
 * canonical journals, surfaced as import proposals the user accepts; they
 * are never posted automatically. Only the deterministic {@code sandbox}
 * provider exists, and only when configured: choosing a real Australian
 * Consumer Data Right provider and the participation model is a pending
 * business decision (BANK 01). The application never asks for bank
 * passwords.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Bank feeds")
package com.paulsnow.finance.server.bankfeeds;
