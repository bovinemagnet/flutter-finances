/**
 * CSV statement imports (IMP 01-03): preview with row errors, totals,
 * duplicate, transfer and existing-entry candidates and date gaps; commit
 * through the sync command path with idempotent re-commits (A12); rollback.
 * Raw rows and their hashes are kept separately from the journals they
 * produce, so corrections never erase evidence of origin.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Imports")
package com.paulsnow.finance.server.imports;
