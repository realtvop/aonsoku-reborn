package github.realtvop.aonsoku.ui.overlays

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RadioFormRulesTest {
    @Test
    fun nameNeedsThreeCharacters() {
        assertEquals("radios.form.validations.name", RadioFormRules.nameError(" ab "))
        assertNull(RadioFormRules.nameError("abc"))
    }

    @Test
    fun homePageIsOptional() {
        assertNull(RadioFormRules.homePageError(""))
        assertNull(RadioFormRules.homePageError("   "))
    }

    @Test
    fun homePageMustBeLongEnoughAndUseHttp() {
        assertEquals(
            "radios.form.validations.homepageUrlLength",
            RadioFormRules.homePageError("http://a"),
        )
        assertEquals(
            "login.form.validations.protocol",
            RadioFormRules.homePageError("ftp://example.com"),
        )
        assertNull(RadioFormRules.homePageError("https://example.com"))
    }

    @Test
    fun streamIsRequiredAndMustUseHttp() {
        assertEquals("radios.form.validations.streamUrlLength", RadioFormRules.streamError(""))
        assertEquals(
            "login.form.validations.protocol",
            RadioFormRules.streamError("example.com/stream.mp3"),
        )
        assertNull(RadioFormRules.streamError("http://example.com/stream"))
    }
}
