import Foundation

/// Inline formatting: bold, italic and the rest, applied to a range *within* a
/// block rather than to the whole block.
///
/// ## Offsets are UTF-16 code units
///
/// Not characters, and not bytes. Both platforms' text machinery already counts
/// in UTF-16 — `NSRange` and `UITextView` on iOS, `String` and `AnnotatedString`
/// on Android — so anything else would mean converting on every keystroke and
/// getting it wrong around emoji. Swift's `String.count` is grapheme clusters
/// and is **not** the right measure here; use `text.utf16.count` and
/// `String.Index(utf16Offset:in:)`.
///
/// Get this wrong and a note written on one platform renders its bold in the
/// wrong place on the other, for any text containing an emoji or an accented
/// character built from combining marks.
public enum Mark: String, Codable, Sendable, CaseIterable {
    case bold
    case italic
    case underline
    case strikethrough

    /// Stable order, so the encoded form of a given set of marks is the same on
    /// both platforms and in the shared test vectors.
    var sortOrder: Int {
        switch self {
        case .bold: 0
        case .italic: 1
        case .underline: 2
        case .strikethrough: 3
        }
    }
}

/// A run of text carrying the same formatting.
///
/// Spans are always normalised: sorted by `start`, non-overlapping, none empty,
/// and never two adjacent runs with identical formatting. That is what makes
/// two clients agree on the encoded form.
public struct Span: Codable, Equatable, Sendable {
    /// UTF-16 offset of the first unit in the run.
    public var start: Int
    /// Length of the run, in UTF-16 units.
    public var length: Int
    /// Sorted and de-duplicated.
    public var marks: [Mark]
    /// A link target, if this run is a link.
    public var link: String?

    public init(start: Int, length: Int, marks: [Mark] = [], link: String? = nil) {
        self.start = start
        self.length = length
        self.marks = marks.uniqueSorted()
        self.link = link
    }

    enum CodingKeys: String, CodingKey {
        case start, length, marks, link
    }

    /// Written by hand because the synthesized one makes `marks` **required**,
    /// while Kotlin's `Span` defaults it to empty — and a link-only run has no
    /// marks to write. A throw here is not a lost style: `BlockContent.decode`
    /// answers a failure with empty content, so it is the block's words gone.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int.self, forKey: .start)
        length = try container.decode(Int.self, forKey: .length)
        marks = (try container.decodeIfPresent([Mark].self, forKey: .marks) ?? []).uniqueSorted()
        link = try container.decodeIfPresent(String.self, forKey: .link)
    }

    public var end: Int { start + length }
}

extension Array where Element == Mark {
    func uniqueSorted() -> [Mark] {
        Array(Set(self)).sorted { $0.sortOrder < $1.sortOrder }
    }
}

/// The formatting of a single UTF-16 unit.
///
/// Every operation below works by expanding spans into one of these per unit,
/// editing that, and rebuilding. It is O(n) in the length of a block, which is
/// nothing next to laying the text out — and it makes overlap, adjacency and
/// merging fall out for free instead of being four more cases to get wrong.
private struct UnitFormat: Equatable {
    var marks: Set<Mark> = []
    var link: String?
}

public enum InlineSpans {

    // MARK: - Conversion

    private static func expand(_ spans: [Span], length: Int) -> [UnitFormat] {
        var units = [UnitFormat](repeating: UnitFormat(), count: max(0, length))
        for span in spans {
            let lower = Swift.max(0, span.start)
            let upper = Swift.min(length, span.end)
            guard lower < upper else { continue }
            for index in lower..<upper {
                units[index].marks.formUnion(span.marks)
                if let link = span.link { units[index].link = link }
            }
        }
        return units
    }

    private static func collapse(_ units: [UnitFormat]) -> [Span] {
        var spans: [Span] = []
        var index = 0
        while index < units.count {
            let format = units[index]
            var end = index + 1
            while end < units.count, units[end] == format { end += 1 }
            if !format.marks.isEmpty || format.link != nil {
                spans.append(Span(start: index, length: end - index,
                                  marks: Array(format.marks), link: format.link))
            }
            index = end
        }
        return spans
    }

    /// Clamps to the text, drops empties, sorts and merges neighbours.
    public static func normalized(_ spans: [Span], textLength: Int) -> [Span] {
        collapse(expand(spans, length: textLength))
    }

    // MARK: - Reading

    /// The marks common to every unit of a range — what a toolbar should show as
    /// active. An empty range reports the marks that typing there would inherit.
    public static func marks(in range: Range<Int>, spans: [Span], textLength: Int) -> Set<Mark> {
        let units = expand(spans, length: textLength)
        guard !units.isEmpty else { return [] }

        if range.isEmpty {
            // Typing inherits from the character to the left, which is why
            // typing at the very start of a bold word is not bold.
            let previous = range.lowerBound - 1
            guard previous >= 0, previous < units.count else { return [] }
            return units[previous].marks
        }

        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(units.count, range.upperBound)
        guard lower < upper else { return [] }

        return units[lower..<upper].dropFirst().reduce(units[lower].marks) {
            $0.intersection($1.marks)
        }
    }

    /// The link covering a range, if one covers all of it.
    public static func link(in range: Range<Int>, spans: [Span], textLength: Int) -> String? {
        let units = expand(spans, length: textLength)
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(units.count, Swift.max(range.upperBound, range.lowerBound + 1))
        guard lower < upper, upper <= units.count else { return nil }

        let first = units[lower].link
        guard first != nil else { return nil }
        return units[lower..<upper].allSatisfy { $0.link == first } ? first : nil
    }

    // MARK: - Writing

    /// Turns a mark on across a range, or off if every unit already has it —
    /// which is what a toolbar button does.
    public static func toggle(
        _ mark: Mark, in range: Range<Int>, spans: [Span], textLength: Int
    ) -> [Span] {
        var units = expand(spans, length: textLength)
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(units.count, range.upperBound)
        guard lower < upper else { return normalized(spans, textLength: textLength) }

        let allSet = units[lower..<upper].allSatisfy { $0.marks.contains(mark) }
        for index in lower..<upper {
            if allSet { units[index].marks.remove(mark) } else { units[index].marks.insert(mark) }
        }
        return collapse(units)
    }

    /// Sets or clears a link across a range.
    public static func setLink(
        _ link: String?, in range: Range<Int>, spans: [Span], textLength: Int
    ) -> [Span] {
        var units = expand(spans, length: textLength)
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(units.count, range.upperBound)
        guard lower < upper else { return normalized(spans, textLength: textLength) }

        for index in lower..<upper { units[index].link = link }
        return collapse(units)
    }

    // MARK: - Following an edit

    /// Moves spans to keep up with a text edit.
    ///
    /// Inserted text inherits the formatting of the character before it, the way
    /// every word processor behaves: continue a bold word and the new letters
    /// are bold, but start typing in front of it and they are not.
    public static func adjusted(
        _ spans: [Span], textLength: Int, replacing range: Range<Int>, withLength newLength: Int
    ) -> [Span] {
        let units = expand(spans, length: textLength)
        let lower = Swift.max(0, Swift.min(range.lowerBound, units.count))
        let upper = Swift.max(lower, Swift.min(range.upperBound, units.count))

        let inherited: UnitFormat = lower > 0 ? units[lower - 1] : UnitFormat()

        var rebuilt = Array(units[0..<lower])
        rebuilt.append(contentsOf: [UnitFormat](repeating: inherited, count: Swift.max(0, newLength)))
        rebuilt.append(contentsOf: Array(units[upper...]))
        return collapse(rebuilt)
    }

    /// The spans covering a slice of the text, rebased so the slice starts at 0.
    ///
    /// Splitting a block, merging two, and pasting all move text from one block
    /// to another; its formatting has to travel with it.
    public static func slice(
        _ spans: [Span], textLength: Int, range: Range<Int>
    ) -> [Span] {
        let units = expand(spans, length: textLength)
        let lower = Swift.max(0, Swift.min(range.lowerBound, units.count))
        let upper = Swift.max(lower, Swift.min(range.upperBound, units.count))
        return collapse(Array(units[lower..<upper]))
    }

    /// Concatenates two runs of formatted text, shifting the second along.
    ///
    /// Both lengths are passed rather than inferred from the spans: unformatted
    /// trailing text carries no span, so the spans do not tell you how long the
    /// text actually is.
    public static func concatenated(
        _ first: [Span], firstLength: Int, _ second: [Span], secondLength: Int
    ) -> [Span] {
        let shifted = second.map {
            Span(start: $0.start + firstLength, length: $0.length, marks: $0.marks, link: $0.link)
        }
        return normalized(first + shifted, textLength: firstLength + secondLength)
    }
}
