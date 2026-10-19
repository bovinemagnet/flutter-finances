package com.paulsnow.finance.server.sync;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.TreeMap;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * JSON comparison and canonical hashing for commands and field merges.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class JsonValues {

    private static final JsonMapper MAPPER = JsonMapper.builder().build();

    private JsonValues() {
    }

    /** Treats missing and null alike and compares numbers by value. */
    static boolean same(JsonNode a, JsonNode b) {
        boolean aEmpty = a == null || a.isMissingNode() || a.isNull();
        boolean bEmpty = b == null || b.isMissingNode() || b.isNull();
        if (aEmpty || bEmpty) {
            return aEmpty && bEmpty;
        }
        if (a.isNumber() && b.isNumber()) {
            return a.decimalValue().compareTo(b.decimalValue()) == 0;
        }
        return canonical(a).equals(canonical(b));
    }

    /** SHA-256 of the canonical (key-sorted) serialisation. */
    static String sha256(JsonNode node) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(MAPPER.writeValueAsString(canonical(node)).getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** A copy with object properties sorted recursively. */
    static JsonNode canonical(JsonNode node) {
        if (node == null) {
            return JsonNodeFactory.instance.nullNode();
        }
        if (node.isObject()) {
            Map<String, JsonNode> sorted = new TreeMap<>();
            node.properties().forEach(e -> sorted.put(e.getKey(), canonical(e.getValue())));
            ObjectNode copy = JsonNodeFactory.instance.objectNode();
            sorted.forEach(copy::set);
            return copy;
        }
        if (node.isArray()) {
            ArrayNode copy = JsonNodeFactory.instance.arrayNode();
            node.forEach(item -> copy.add(canonical(item)));
            return copy;
        }
        return node;
    }

    static ObjectNode parseObject(String text) {
        return text == null ? null : (ObjectNode) MAPPER.readTree(text);
    }

    static String write(JsonNode node) {
        return node == null ? null : MAPPER.writeValueAsString(node);
    }
}
