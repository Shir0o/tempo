package com.tempos.tracker.wear

import java.util.Locale

/**
 * What one spoken phrase resolved to.
 *
 * [unique] is the Activity worth labeling without a second tap: a strong,
 * clearly leading match. [candidates] are the ranked matches to show when the
 * phrase was ambiguous or only partially matched.
 */
internal data class SpokenActivityMatch(
    val unique: WearActivity?,
    val candidates: List<WearActivity>
)

private const val STRONG_MATCH = 60
private const val UNIQUE_MARGIN = 20
private const val MAX_CANDIDATES = 5

/**
 * Matches a recognizer transcript to the Activity list.
 *
 * Speech arrives as whole sentences ("I was at the gym"), so a name matches
 * when it appears as a phrase or when every word of it is spoken. A name's
 * words also match longer words ("work" against "working"), covering the
 * inflections recognizers produce. Scores rank the results; a tie stays a
 * candidate list instead of guessing.
 */
internal fun matchSpokenActivity(
    transcript: String,
    activities: List<WearActivity>
): SpokenActivityMatch {
    val spoken = normalize(transcript)
    if (spoken.isEmpty()) return SpokenActivityMatch(null, emptyList())
    val padded = " $spoken "
    val spokenTokens = spoken.split(' ')

    val scored = activities
        .mapNotNull { activity ->
            val name = normalize(activity.name)
            if (name.isEmpty()) return@mapNotNull null
            val score = score(name, spoken, padded, spokenTokens) ?: return@mapNotNull null
            score to activity
        }
        .sortedWith(
            compareByDescending<Pair<Int, WearActivity>> { it.first }
                .thenBy { it.second.name.lowercase(Locale.US) }
        )

    val candidates = scored.take(MAX_CANDIDATES).map { it.second }
    val top = scored.firstOrNull()
    val unique = when {
        top == null || top.first < STRONG_MATCH -> null
        scored.size == 1 -> top.second
        top.first - scored[1].first >= UNIQUE_MARGIN -> top.second
        else -> null
    }
    return SpokenActivityMatch(unique, candidates)
}

private fun score(
    name: String,
    spoken: String,
    paddedSpoken: String,
    spokenTokens: List<String>
): Int? {
    if (spoken == name) return 100
    if (paddedSpoken.contains(" $name ")) return 80

    val nameTokens = name.split(' ')
    val matched = nameTokens.count { token -> spokenTokens.any { tokenMatches(token, it) } }
    if (matched == 0) return null
    return if (matched == nameTokens.size) {
        (STRONG_MATCH + nameTokens.size).coerceAtMost(79)
    } else {
        10 + matched * 5
    }
}

private fun tokenMatches(nameToken: String, spokenToken: String): Boolean {
    if (nameToken == spokenToken) return true
    if (minOf(nameToken.length, spokenToken.length) < 4) return false
    return spokenToken.startsWith(nameToken) || nameToken.startsWith(spokenToken)
}

/** Lowercase words separated by single spaces; punctuation and emoji split words. */
private fun normalize(text: String): String {
    val out = StringBuilder(text.length)
    var pendingSpace = false
    for (ch in text.lowercase(Locale.US)) {
        if (ch.isLetterOrDigit()) {
            if (pendingSpace && out.isNotEmpty()) out.append(' ')
            out.append(ch)
            pendingSpace = false
        } else {
            pendingSpace = true
        }
    }
    return out.toString()
}
