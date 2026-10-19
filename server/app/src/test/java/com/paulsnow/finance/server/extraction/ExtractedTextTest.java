package com.paulsnow.finance.server.extraction;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Collections;
import java.util.List;

import org.junit.jupiter.api.Test;

/**
 * Provider output is untrusted: control characters are removed and sizes
 * are bounded before anything is stored.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class ExtractedTextTest {

    @Test
    void removesControlCharactersButKeepsLineBreaksInTheText() {
        ExtractedText clean = new ExtractedText("A\u0000B\nC\tD\u001b[31m", List.of("x\u0007y", "‮z")).sanitised();
        assertThat(clean.text()).isEqualTo("AB\nC\tD[31m");
        assertThat(clean.lines()).containsExactly("xy", "‮z");
    }

    @Test
    void boundsTextLinesAndLineLength() {
        ExtractedText clean = new ExtractedText("t".repeat(30_000),
                Collections.nCopies(600, "l".repeat(700))).sanitised();
        assertThat(clean.text()).hasSize(ExtractedText.MAX_TEXT);
        assertThat(clean.lines()).hasSize(ExtractedText.MAX_LINES);
        assertThat(clean.lines().get(0)).hasSize(ExtractedText.MAX_LINE);
    }

    @Test
    void treatsMissingValuesAsEmpty() {
        ExtractedText clean = new ExtractedText(null, null).sanitised();
        assertThat(clean.text()).isEmpty();
        assertThat(clean.lines()).isEmpty();
    }
}
