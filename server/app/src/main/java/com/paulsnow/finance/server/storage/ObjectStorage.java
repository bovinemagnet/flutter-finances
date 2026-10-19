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
    PresignedRequest presignPut(String key, String contentType);

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
    void put(String key, Path file, String contentType);

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
