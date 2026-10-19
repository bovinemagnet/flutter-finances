package com.paulsnow.finance.server.storage;

import java.io.InputStream;
import java.nio.file.Path;
import java.util.Optional;

/**
 * Private object storage. Keys are always derived by the caller from
 * records it has already authorised (for example
 * {@code workspaces/{workspaceId}/receipts/...}); clients never supply keys.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public interface ObjectStorage {

    /** Size and type of a stored object. */
    record ObjectInfo(long sizeBytes, String contentType) {
    }

    /**
     * Signs a PUT of exactly one object with the given content type.
     *
     * @param key         object key
     * @param contentType content type the client must send
     * @return the signed request
     */
    default PresignedRequest presignPut(String key, String contentType) {
        return presignPut(key, contentType, null);
    }

    /**
     * Signs a PUT of exactly one object with the given content type that
     * tags it with a retention class; the tag header is among the headers
     * the client must send.
     *
     * @param key         object key
     * @param contentType content type the client must send
     * @param retention   retention class, or null for none
     * @return the signed request
     */
    PresignedRequest presignPut(String key, String contentType, Retention retention);

    /**
     * Signs a GET of one object.
     *
     * @param key object key
     * @return the signed request
     */
    PresignedRequest presignGet(String key);

    /**
     * Returns metadata of an object.
     *
     * @param key object key
     * @return the metadata, or empty when absent
     */
    Optional<ObjectInfo> head(String key);

    /**
     * Opens an object for reading; the caller closes the stream.
     *
     * @param key object key
     * @return the content
     */
    InputStream read(String key);

    /**
     * Stores a file as an object.
     *
     * @param key         object key
     * @param file        content
     * @param contentType content type
     */
    default void put(String key, Path file, String contentType) {
        put(key, file, contentType, null);
    }

    /**
     * Stores a file as an object tagged with a retention class.
     *
     * @param key         object key
     * @param file        content
     * @param contentType content type
     * @param retention   retention class, or null for none
     */
    void put(String key, Path file, String contentType, Retention retention);

    /**
     * Deletes one object; absent objects are ignored.
     *
     * @param key object key
     */
    void delete(String key);

    /**
     * Deletes every object under a prefix.
     *
     * @param prefix key prefix ending with {@code /}
     * @return number of objects deleted
     */
    int deletePrefix(String prefix);
}
