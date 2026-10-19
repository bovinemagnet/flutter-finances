/**
 * Audit and security events (SEC 06): every
 * {@link com.paulsnow.finance.server.common.AuditEvent} published by another
 * module is stored in the publisher's transaction with minimised content
 * (identifiers and short codes only) and purged after the configured
 * retention, 12 months by default. Owners can read their workspace's
 * events.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Audit")
package com.paulsnow.finance.server.audit;
