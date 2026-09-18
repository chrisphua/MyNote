import Foundation

/// Tells an editor's own echo apart from a genuine edit made elsewhere.
///
/// Every keystroke is written to the local store, and the store notifies the
/// editor that the value changed. Naively adopting that notification means the
/// editor fights itself: writes are asynchronous, so a *stale* one can land
/// after the user has typed further and overwrite what is on screen — including
/// with the block's original empty value, which empties the field and brings
/// the placeholder back.
///
/// The rule this encodes: **adopt an incoming value only if it is not the echo
/// of what this editor last sent.** Anything else came from another device and
/// should be shown.
///
/// Implemented identically in Kotlin (`EditorEcho.kt`).
public struct EditorEcho: Sendable, Equatable {
    /// A short history, not just the last value.
    ///
    /// Writes are asynchronous and can land out of order, so the echo of an
    /// *earlier* keystroke may arrive after a later one. Remembering only the
    /// most recent value would let that earlier echo through and clobber the
    /// field — which is the bug this type exists to prevent.
    private var recent: [String] = []

    /// Deep enough to cover a burst of typing, shallow enough that a genuine
    /// remote edit which happens to match something typed a while ago is still
    /// adopted.
    private static let capacity = 16

    public init() {}

    /// Record what the editor is about to write.
    public mutating func sending(_ value: String) {
        recent.removeAll { $0 == value }
        recent.append(value)
        if recent.count > Self.capacity {
            recent.removeFirst(recent.count - Self.capacity)
        }
    }

    /// Whether `incoming` is one of this editor's own recent writes coming back.
    public func isEcho(_ incoming: String) -> Bool {
        recent.contains(incoming)
    }

    /// Forget the history — used when the editor moves to a different record.
    public mutating func reset() {
        recent.removeAll()
    }

    /// Whether the editor should replace what it is showing with `incoming`.
    ///
    /// Before anything has been sent there is nothing to echo, so the first
    /// value always loads — that is the initial read from the store.
    public func shouldAdopt(_ incoming: String) -> Bool {
        !isEcho(incoming)
    }
}
