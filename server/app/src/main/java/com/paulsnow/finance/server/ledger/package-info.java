/**
 * Canonical journals and postings. Validates journals with the shared
 * finance-core rules plus the workspace-level checks of the sync protocol,
 * and stores them in tables whose balance and immutability the database
 * enforces as well.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Ledger")
package com.paulsnow.finance.server.ledger;
