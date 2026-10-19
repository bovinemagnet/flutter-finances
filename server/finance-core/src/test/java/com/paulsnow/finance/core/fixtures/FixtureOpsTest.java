package com.paulsnow.finance.core.fixtures;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.file.Files;

import org.junit.jupiter.api.Test;

/**
 * Guards the fixture runner itself.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class FixtureOpsTest {

    @Test
    void locatesSharedFixturesFromAnyWorkingDirectory() {
        assertThat(Files.isRegularFile(SpecFixturesTest.fixturesDirectory().resolve("money.json"))).isTrue();
    }

    @Test
    void unknownOperationsHaveNoHandler() {
        // The runner fails any case whose op is absent from this map, so new
        // fixture operations cannot be silently skipped.
        assertThat(FixtureOps.all()).doesNotContainKey("planning.unknown")
                .containsKeys("money.parse", "money.allocate", "journal.validate", "ledger.scenario");
    }
}
