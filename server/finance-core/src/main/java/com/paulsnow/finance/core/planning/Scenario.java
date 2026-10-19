package com.paulsnow.finance.core.planning;

import java.util.List;
import java.util.Objects;

/**
 * A what-if applied to a forecast (PLAN 03). Scenarios only change the
 * projection; they never create journals or edit schedules.
 *
 * @param id      identifier
 * @param name    display name
 * @param changes the hypothetical changes
 * @author Paul Snow
 * @since 0.0.0
 */
public record Scenario(String id, String name, List<ScenarioChange> changes) {

    public Scenario {
        Objects.requireNonNull(id, "id");
        changes = List.copyOf(changes);
    }
}
