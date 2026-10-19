/**
 * User exports (EXP 01, DATA 01): a background job writes a versioned JSON
 * archive of every live entity and available receipt document, with a
 * manifest of SHA-256 hashes, counts and relationships, to private object
 * storage; members download it through a short-lived signed URL.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Exports")
package com.paulsnow.finance.server.exports;
