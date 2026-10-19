package com.paulsnow.finance.server;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.modulith.core.ApplicationModule;
import org.springframework.modulith.core.ApplicationModules;

/**
 * Verifies the module boundaries of the modular monolith: no cycles and no
 * access to another module's internal packages.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class ModularityTest {

    private final ApplicationModules modules = ApplicationModules.of(FinanceApplication.class);

    @Test
    void verifiesModuleStructure() {
        modules.verify();
    }

    @Test
    void declaresTheExpectedModules() {
        assertThat(modules.stream().map(ApplicationModule::getIdentifier).map(Object::toString))
                .contains("common", "workspace", "sync", "ledger", "receipts", "imports", "exports", "jobs",
                        "deletion", "storage", "extraction", "bankfeeds");
    }
}
