package com.paulsnow.finance.server.audit;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Audit settings ({@code finance.audit.*}).
 *
 * @param retention how long audit events are kept (SEC 06 proposes 12 months)
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.audit")
public record AuditProperties(Duration retention) {

    public AuditProperties {
        retention = retention == null ? Duration.ofDays(365) : retention;
    }
}
