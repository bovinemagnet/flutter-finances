/**
 * Cross-cutting concerns shared by every module: the error model,
 * correlation identifiers, redacting log output, security and the clock.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Common")
package com.paulsnow.finance.server.common;
