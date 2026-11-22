package com.tempos.tracker.wear

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpokenActivityMatcherTest {

    private val activities = listOf(
        WearActivity(id = "1", name = "Coffee"),
        WearActivity(id = "2", name = "Coffee with Sam"),
        WearActivity(id = "3", name = "Gym"),
        WearActivity(id = "4", name = "Work"),
        WearActivity(id = "5", name = "Meals"),
        WearActivity(id = "6", name = "Call Mom")
    )

    @Test
    fun exactNameLabelsWithoutASecondTap() {
        assertEquals("Coffee", matchSpokenActivity("Coffee", activities).unique?.name)
    }

    @Test
    fun sentenceStillFindsTheName() {
        assertEquals("Gym", matchSpokenActivity("I was at the gym", activities).unique?.name)
    }

    @Test
    fun inflectionMatches() {
        assertEquals("Work", matchSpokenActivity("working", activities).unique?.name)
    }

    @Test
    fun casePunctuationAndSpacingAreIgnored() {
        assertEquals("Meals", matchSpokenActivity("  MEALS! ", activities).unique?.name)
    }

    @Test
    fun longerNameBeatsItsPrefix() {
        assertEquals(
            "Coffee with Sam",
            matchSpokenActivity("coffee with sam", activities).unique?.name
        )
    }

    @Test
    fun exactShortNameBeatsALongerNameThatContainsIt() {
        assertEquals("Coffee", matchSpokenActivity("coffee", activities).unique?.name)
    }

    @Test
    fun conversationalSentenceStillLabelsTheName() {
        assertEquals("Coffee", matchSpokenActivity("I'm having coffee", activities).unique?.name)
    }

    @Test
    fun oneWordOfALongerNameIsOnlyACandidate() {
        // "call" is one word of a two-word name, so it is worth showing but
        // not strong enough to label on its own.
        val match = matchSpokenActivity("call", listOf(WearActivity("a", "Call Mom")))
        assertNull(match.unique)
        assertEquals(listOf("Call Mom"), match.candidates.map { it.name })
    }

    @Test
    fun ambiguousPhraseStaysACandidateList() {
        val ties = listOf(
            WearActivity(id = "a", name = "Call Mom"),
            WearActivity(id = "b", name = "Call Dad")
        )
        val match = matchSpokenActivity("call", ties)
        assertNull(match.unique)
        assertEquals(listOf("Call Dad", "Call Mom"), match.candidates.map { it.name })
    }

    @Test
    fun unrelatedPhraseMatchesNothing() {
        val match = matchSpokenActivity("dentist", activities)
        assertNull(match.unique)
        assertTrue(match.candidates.isEmpty())
    }

    @Test
    fun blankTranscriptMatchesNothing() {
        val match = matchSpokenActivity("   ", activities)
        assertNull(match.unique)
        assertTrue(match.candidates.isEmpty())
    }
}
