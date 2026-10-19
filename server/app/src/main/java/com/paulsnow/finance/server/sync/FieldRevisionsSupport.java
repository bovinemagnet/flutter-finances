package com.paulsnow.finance.server.sync;

import java.util.LinkedHashSet;
import java.util.Set;

import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Tracks the revision at which each top-level field of an entity last
 * changed, which is what makes field-level merge possible (SYNC 03).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class FieldRevisionsSupport {

    private FieldRevisionsSupport() {
    }

    static ObjectNode initial(ObjectNode data, long revision) {
        ObjectNode revisions = JsonNodeFactory.instance.objectNode();
        data.propertyNames().forEach(name -> revisions.put(name, revision));
        return revisions;
    }

    static ObjectNode next(ObjectNode before, ObjectNode after, ObjectNode previous, long revision) {
        ObjectNode revisions = previous.deepCopy();
        Set<String> names = new LinkedHashSet<>();
        if (before != null) {
            before.propertyNames().forEach(names::add);
        }
        after.propertyNames().forEach(names::add);
        for (String name : names) {
            if (before == null || !JsonValues.same(before.get(name), after.get(name))) {
                revisions.put(name, revision);
            }
        }
        return revisions;
    }
}
