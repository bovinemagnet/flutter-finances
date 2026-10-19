/**
 * Operations reporting (NFR 08): backup and restore-drill outcomes reported
 * by the operations tooling through an endpoint restricted to the
 * {@code finance.ops} scope, exposed as metrics for alerting
 * ({@code server/README.md}, "Operations").
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Operations")
package com.paulsnow.finance.server.ops;
