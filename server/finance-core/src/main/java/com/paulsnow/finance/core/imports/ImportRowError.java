package com.paulsnow.finance.core.imports;

/**
 * An error tied to a 1-based record number in the file (the header, when
 * present, is record 1).
 *
 * @param row  record number
 * @param code error code
 * @author Paul Snow
 * @since 0.0.0
 */
public record ImportRowError(int row, ImportErrorCode code) {
}
