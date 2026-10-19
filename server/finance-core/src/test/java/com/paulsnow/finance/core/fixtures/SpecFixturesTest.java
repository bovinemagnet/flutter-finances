package com.paulsnow.finance.core.fixtures;

import static org.junit.jupiter.api.Assertions.fail;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import org.junit.jupiter.api.DynamicContainer;
import org.junit.jupiter.api.DynamicNode;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;

/**
 * Runs every case in the shared {@code spec/fixtures} directory. The Dart
 * client runs the same files, so both implementations agree on financial
 * rules. An operation without a Java handler fails rather than being skipped.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class SpecFixturesTest {

    private static final ObjectMapper JSON = JsonMapper.builder().build();

    private static final Map<String, FixtureOp> OPS = FixtureOps.all();

    @TestFactory
    Stream<DynamicNode> sharedFixtures() throws IOException {
        Path dir = fixturesDirectory();
        List<Path> files;
        try (Stream<Path> listing = Files.list(dir)) {
            files = listing.filter(p -> p.getFileName().toString().endsWith(".json")).sorted().toList();
        }
        if (files.isEmpty()) {
            fail("No fixture files found in " + dir);
        }
        List<DynamicNode> areas = new ArrayList<>();
        for (Path file : files) {
            JsonNode document = JSON.readTree(file.toFile());
            if (document.path("schemaVersion").asInt() != 1) {
                fail("Unsupported fixture schema in " + file);
            }
            List<DynamicTest> cases = new ArrayList<>();
            for (JsonNode fixture : document.path("cases")) {
                String id = fixture.path("id").asString();
                String op = fixture.path("op").asString();
                cases.add(DynamicTest.dynamicTest(id, () -> {
                    FixtureOp handler = OPS.get(op);
                    if (handler == null) {
                        fail("No Java handler for fixture op \"" + op + "\"");
                    }
                    handler.check(fixture.path("input"), fixture.path("expect"));
                }));
            }
            areas.add(DynamicContainer.dynamicContainer(
                    document.path("area").asString() + " (" + file.getFileName() + ")", cases));
        }
        return areas.stream();
    }

    /** Walks up from the working directory until {@code spec/fixtures} is found. */
    static Path fixturesDirectory() {
        Path dir = Path.of("").toAbsolutePath();
        while (dir != null) {
            Path candidate = dir.resolve("spec").resolve("fixtures");
            if (Files.isDirectory(candidate)) {
                return candidate;
            }
            dir = dir.getParent();
        }
        throw new IllegalStateException("spec/fixtures not found above " + Path.of("").toAbsolutePath());
    }
}
