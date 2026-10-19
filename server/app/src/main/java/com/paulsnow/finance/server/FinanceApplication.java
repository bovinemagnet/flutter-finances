package com.paulsnow.finance.server;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * Optional cloud synchronisation service for the personal finance client.
 * The same codebase runs the API and, with {@code finance.worker.enabled},
 * the background worker.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class FinanceApplication {

    public static void main(String[] args) {
        SpringApplication.run(FinanceApplication.class, args);
    }
}
