package io.mynote.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Inline formatting: bold, italic and the rest, applied to a range *within* a
 * block rather than to the whole block.
 *
 * ## Offsets are UTF-16 code units
 *
 * Kotlin's `String.length` and `AnnotatedString` already count in UTF-16, so
 * offsets here map straight onto them with no conversion. The Swift side has to
 * work to match this — `String.count` there is grapheme clusters, which would
 * put the bold on the wrong letter for any text containing an emoji.
 *
 * Mirrors `InlineSpans.swift`. Changing one means changing both, plus the shared
 * vectors in each suite.
 */
@Serializable
enum class Mark {
    @SerialName("bold") BOLD,
    @SerialName("italic") ITALIC,
    @SerialName("underline") UNDERLINE,
    @SerialName("strikethrough") STRIKETHROUGH,
}

/**
 * A run of text carrying the same formatting.
 *
 * Always normalised: sorted by [start], non-overlapping, none empty, and never
 * two adjacent runs with identical formatting. That is what makes two clients
 * agree on the encoded form.
 */
@Serializable
data class Span(
    /** UTF-16 offset of the first unit in the run. */
    val start: Int,
    /** Length of the run, in UTF-16 units. */
    val length: Int,
    /** Sorted and de-duplicated. */
    val marks: List<Mark> = emptyList(),
    /** A link target, if this run is a link. */
    val link: String? = null,
) {
    val end: Int get() = start + length

    companion object {
        /** The declaration order is the encoded order, on both platforms. */
        fun of(start: Int, length: Int, marks: Collection<Mark> = emptyList(), link: String? = null) =
            Span(start, length, marks.distinct().sortedBy { it.ordinal }, link)
    }
}

/**
 * The formatting of a single UTF-16 unit.
 *
 * Every operation below expands spans into one of these per unit, edits that,
 * and rebuilds. It is O(n) in the length of a block, which is nothing next to
 * laying the text out — and it makes overlap, adjacency and merging fall out
 * for free instead of being four more cases to get wrong.
 */
private data class UnitFormat(
    val marks: Set<Mark> = emptySet(),
    val link: String? = null,
)

object InlineSpans {

    // region Conversion

    private fun expand(spans: List<Span>, length: Int): MutableList<UnitFormat> {
        val units = MutableList(maxOf(0, length)) { UnitFormat() }
        for (span in spans) {
            val lower = maxOf(0, span.start)
            val upper = minOf(length, span.end)
            if (lower >= upper) continue
            for (index in lower until upper) {
                val current = units[index]
                units[index] = current.copy(
                    marks = current.marks + span.marks,
                    link = span.link ?: current.link,
                )
            }
        }
        return units
    }

    private fun collapse(units: List<UnitFormat>): List<Span> {
        val spans = mutableListOf<Span>()
        var index = 0
        while (index < units.size) {
            val format = units[index]
            var end = index + 1
            while (end < units.size && units[end] == format) end++
            if (format.marks.isNotEmpty() || format.link != null) {
                spans += Span.of(index, end - index, format.marks, format.link)
            }
            index = end
        }
        return spans
    }

    /** Clamps to the text, drops empties, sorts and merges neighbours. */
    fun normalized(spans: List<Span>, textLength: Int): List<Span> =
        collapse(expand(spans, textLength))

    // endregion

    // region Reading

    /**
     * The marks common to every unit of a range — what a toolbar should show as
     * active. An empty range reports the marks that typing there would inherit.
     */
    fun marks(from: Int, to: Int, spans: List<Span>, textLength: Int): Set<Mark> {
        val units = expand(spans, textLength)
        if (units.isEmpty()) return emptySet()

        // Half-open, like every other range here: `from` up to but not
        // including `to`. Deliberately not an IntRange, which is inclusive in
        // Kotlin and half-open in Swift — the two would silently disagree by
        // one character.
        val lower = maxOf(0, from)
        val upper = minOf(units.size, to)

        if (upper <= lower) {
            // Typing inherits from the character to the left, which is why
            // typing at the very start of a bold word is not bold.
            val previous = lower - 1
            if (previous < 0 || previous >= units.size) return emptySet()
            return units[previous].marks
        }

        return (lower until upper)
            .map { units[it].marks }
            .reduce { acc, marks -> acc intersect marks }
    }

    /** The link covering a range, if one covers all of it. */
    fun link(from: Int, to: Int, spans: List<Span>, textLength: Int): String? {
        val units = expand(spans, textLength)
        val lower = maxOf(0, from)
        val upper = minOf(units.size, maxOf(to, from + 1))
        if (lower >= upper) return null

        val first = units[lower].link ?: return null
        return if ((lower until upper).all { units[it].link == first }) first else null
    }

    // endregion

    // region Writing

    /**
     * Turns a mark on across a range, or off if every unit already has it —
     * which is what a toolbar button does.
     */
    fun toggle(mark: Mark, from: Int, to: Int, spans: List<Span>, textLength: Int): List<Span> {
        val units = expand(spans, textLength)
        val lower = maxOf(0, from)
        val upper = minOf(units.size, to)
        if (lower >= upper) return normalized(spans, textLength)

        val allSet = (lower until upper).all { units[it].marks.contains(mark) }
        for (index in lower until upper) {
            val current = units[index]
            units[index] = current.copy(
                marks = if (allSet) current.marks - mark else current.marks + mark
            )
        }
        return collapse(units)
    }

    /** Sets or clears a link across a range. */
    fun setLink(link: String?, from: Int, to: Int, spans: List<Span>, textLength: Int): List<Span> {
        val units = expand(spans, textLength)
        val lower = maxOf(0, from)
        val upper = minOf(units.size, to)
        if (lower >= upper) return normalized(spans, textLength)

        for (index in lower until upper) {
            units[index] = units[index].copy(link = link)
        }
        return collapse(units)
    }

    // endregion

    // region Following an edit

    /**
     * Moves spans to keep up with a text edit.
     *
     * Inserted text inherits the formatting of the character before it, the way
     * every word processor behaves: continue a bold word and the new letters
     * are bold, but start typing in front of it and they are not.
     */
    fun adjusted(
        spans: List<Span>,
        textLength: Int,
        replaceFrom: Int,
        replaceTo: Int,
        newLength: Int,
    ): List<Span> {
        val units = expand(spans, textLength)
        val lower = maxOf(0, minOf(replaceFrom, units.size))
        val upper = maxOf(lower, minOf(replaceTo, units.size))

        val inherited = if (lower > 0) units[lower - 1] else UnitFormat()

        val rebuilt = mutableListOf<UnitFormat>()
        rebuilt += units.subList(0, lower)
        repeat(maxOf(0, newLength)) { rebuilt += inherited }
        rebuilt += units.subList(upper, units.size)
        return collapse(rebuilt)
    }

    /**
     * The spans covering a slice of the text, rebased so the slice starts at 0.
     *
     * Splitting a block, merging two, and pasting all move text from one block
     * to another; its formatting has to travel with it.
     */
    fun slice(spans: List<Span>, textLength: Int, from: Int, to: Int): List<Span> {
        val units = expand(spans, textLength)
        val lower = maxOf(0, minOf(from, units.size))
        val upper = maxOf(lower, minOf(to, units.size))
        return collapse(units.subList(lower, upper))
    }

    /**
     * Concatenates two runs of formatted text, shifting the second along.
     *
     * Both lengths are passed rather than inferred from the spans: unformatted
     * trailing text carries no span, so the spans do not tell you how long the
     * text actually is.
     */
    fun concatenated(
        first: List<Span>,
        firstLength: Int,
        second: List<Span>,
        secondLength: Int,
    ): List<Span> {
        val shifted = second.map { it.copy(start = it.start + firstLength) }
        return normalized(first + shifted, firstLength + secondLength)
    }

    /**
     * The edit between two versions of a string: what was replaced, and with
     * how much.
     *
     * Android-only, and deliberately has no Swift twin. UIKit hands iOS the
     * replaced range before the edit happens; Compose hands Android the
     * finished string and nothing else, so the edit has to be recovered by
     * comparing. Matching the common prefix and suffix recovers it exactly for
     * every edit a keyboard makes — typing, deleting, replacing a selection,
     * autocorrect swapping a word.
     *
     * @return the replaced range as `[from, to)` in the old string, and the
     *   length of what replaced it.
     */
    fun editBetween(old: String, new: String): Edit {
        if (old == new) return Edit(old.length, old.length, 0)

        var prefix = 0
        val maxPrefix = minOf(old.length, new.length)
        while (prefix < maxPrefix && old[prefix] == new[prefix]) prefix++

        var suffix = 0
        val maxSuffix = minOf(old.length - prefix, new.length - prefix)
        while (
            suffix < maxSuffix &&
            old[old.length - 1 - suffix] == new[new.length - 1 - suffix]
        ) suffix++

        return Edit(
            from = prefix,
            to = old.length - suffix,
            newLength = new.length - prefix - suffix,
        )
    }

    data class Edit(val from: Int, val to: Int, val newLength: Int)

    /** [adjusted], for a Compose field that only reports the finished text. */
    fun adjustedForEdit(spans: List<Span>, old: String, new: String): List<Span> {
        val edit = editBetween(old, new)
        return adjusted(spans, old.length, edit.from, edit.to, edit.newLength)
    }

    // endregion
}
