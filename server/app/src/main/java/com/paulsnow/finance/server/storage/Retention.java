package com.paulsnow.finance.server.storage;

/**
 * Retention classes of objects that the bucket lifecycle rules expire
 * ({@link StorageLifecycle}). S3 lifecycle filters match key prefixes but
 * not wildcards such as {@code workspaces/}{@code *}{@code /uploads/}, so
 * such objects carry the tag {@value #TAG_KEY} instead.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum Retention {

    /** Client uploads waiting for verification; expire after one day. */
    STAGING("staging"),

    /** Export archives; expire after {@code finance.storage.export-retention}. */
    EXPORT("export");

    /** Object tag key naming the retention class. */
    public static final String TAG_KEY = "finance-retention";

    private final String tagValue;

    Retention(String tagValue) {
        this.tagValue = tagValue;
    }

    /** Returns the tag value, for example {@code staging}. */
    public String tagValue() {
        return tagValue;
    }

    /** Returns the URL-encoded tag set for an {@code x-amz-tagging} header. */
    String tagging() {
        return TAG_KEY + "=" + tagValue;
    }
}
