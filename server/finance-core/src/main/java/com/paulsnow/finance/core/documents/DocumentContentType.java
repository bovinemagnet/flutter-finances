package com.paulsnow.finance.core.documents;

/**
 * Document formats accepted for receipts in P0 (REC 05).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum DocumentContentType {
    JPEG("image/jpeg"),
    PNG("image/png"),
    HEIC("image/heic"),
    HEIF("image/heif"),
    PDF("application/pdf");

    private final String mimeType;

    DocumentContentType(String mimeType) {
        this.mimeType = mimeType;
    }

    /** Returns the media type, for example {@code image/jpeg}. */
    public String mimeType() {
        return mimeType;
    }

    /** Returns whether this is an image format. */
    public boolean isImage() {
        return this != PDF;
    }

    /**
     * Resolves a media type.
     *
     * @param mimeType media type
     * @return the format
     * @throws IllegalArgumentException when unsupported
     */
    public static DocumentContentType fromMimeType(String mimeType) {
        for (DocumentContentType type : values()) {
            if (type.mimeType.equals(mimeType)) {
                return type;
            }
        }
        throw new IllegalArgumentException("Unsupported content type");
    }
}
