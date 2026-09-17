import Foundation

/// Hybrid Logical Clock — the Swift counterpart of `backend/src/hlc.ts`.
///
/// Both ends must encode this identically: the server compares clocks with a
/// plain SQL `>` on the encoded string, so any difference in padding or
/// ordering here would silently corrupt conflict resolution.
public struct HybridLogicalClock: Sendable, Equatable {
    public var millis: Int64
    public var counter: UInt16
    public let node: String

    public init(millis: Int64, counter: UInt16 = 0, node: String) {
        self.millis = millis
        self.counter = counter
        self.node = node
    }

    /// `0000018f5a2b3c4d-0000-node` — fixed width so lexicographic order is time order.
    public var encoded: String {
        let m = String(format: "%016llx", millis)
        let c = String(format: "%04x", counter)
        return "\(m)-\(c)-\(node)"
    }

    public static func decode(_ s: String) -> HybridLogicalClock? {
        let parts = s.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let millis = Int64(parts[0], radix: 16),
              let counter = UInt16(parts[1], radix: 16)
        else { return nil }
        return HybridLogicalClock(millis: millis, counter: counter, node: String(parts[2]))
    }

    /// Advance for a locally-originated edit.
    public mutating func tick(now: Int64) -> String {
        if now > millis {
            millis = now
            counter = 0
        } else if counter == UInt16.max {
            // >65k edits in one millisecond; step the clock rather than wrap.
            millis += 1
            counter = 0
        } else {
            counter += 1
        }
        return encoded
    }

    /// Merge a clock we received, so we never issue an edit that sorts older.
    public mutating func observe(_ remote: HybridLogicalClock, now: Int64) {
        let maxMillis = max(millis, remote.millis, now)
        if maxMillis == millis && maxMillis == remote.millis {
            counter = max(counter, remote.counter) &+ 1
        } else if maxMillis == millis {
            counter &+= 1
        } else if maxMillis == remote.millis {
            counter = remote.counter &+ 1
        } else {
            counter = 0
        }
        millis = maxMillis
    }

    public static func now(node: String) -> HybridLogicalClock {
        HybridLogicalClock(millis: Int64(Date().timeIntervalSince1970 * 1000), node: node)
    }
}
