import Testing
@testable import MyNoteCore

@Suite("Hybrid logical clock")
struct HybridLogicalClockTests {

    /// Shared vectors.
    ///
    /// The identical pairs are asserted in `backend/test/hlc.test.ts` and
    /// `HlcTest.kt`. These three encodings must agree byte for byte — the server
    /// compares clocks with a plain SQL `>` — and these vectors are the only
    /// thing that catches a drift between them.
    @Test("encodes to the cross-platform format")
    func crossPlatformEncoding() {
        #expect(HybridLogicalClock(millis: 0x18f5a2b3c4d, counter: 7, node: "deviceA").encoded
                == "0000018f5a2b3c4d-0007-deviceA")
        #expect(HybridLogicalClock(millis: 0, counter: 0, node: "a").encoded
                == "0000000000000000-0000-a")
        #expect(HybridLogicalClock(millis: 1000, counter: 0xffff, node: "node-with-dashes").encoded
                == "00000000000003e8-ffff-node-with-dashes")
    }

    @Test("round-trips through decode")
    func roundTrip() throws {
        let clock = HybridLogicalClock(millis: 1_700_000_000_000, counter: 7, node: "deviceA")
        let decoded = try #require(HybridLogicalClock.decode(clock.encoded))
        #expect(decoded == clock)
    }

    @Test("node ids containing dashes survive decoding")
    func dashedNode() throws {
        let clock = HybridLogicalClock(millis: 123, counter: 4, node: "abc-def-ghi")
        #expect(HybridLogicalClock.decode(clock.encoded)?.node == "abc-def-ghi")
    }

    @Test("sorts lexicographically in time order")
    func lexicographicOrder() {
        let early = HybridLogicalClock(millis: 1_700_000_000_000, counter: 0, node: "a").encoded
        let later = HybridLogicalClock(millis: 1_700_000_000_001, counter: 0, node: "a").encoded
        #expect(early < later)
        #expect([later, early].sorted() == [early, later])
    }

    @Test("keeps advancing when the device clock goes backwards")
    func backwardsClock() {
        // A phone that resyncs NTP can jump backwards; our own edits must still
        // be strictly increasing or the newer one would lose.
        var clock = HybridLogicalClock(millis: 1000, counter: 0, node: "a")
        let before = clock.encoded
        #expect(clock.tick(now: 500) > before)
    }

    @Test("steps the clock rather than wrapping the counter")
    func tickOverflow() {
        var saturated = HybridLogicalClock(millis: 1000, counter: .max, node: "a")
        let before = saturated.encoded
        let next = saturated.tick(now: 1000)
        #expect(saturated.millis == 1001)
        #expect(saturated.counter == 0)
        #expect(next > before)
    }

    @Test("carries the counter into millis on merge rather than wrapping")
    func observeOverflow() {
        // A peer can legitimately send counter = ffff. Wrapping it to zero would
        // move our clock backwards and silently lose the next edit.
        var local = HybridLogicalClock(millis: 1000, counter: .max, node: "a")
        let before = local.encoded
        let remote = HybridLogicalClock(millis: 1000, counter: .max, node: "b")
        local.observe(remote, now: 1000)

        #expect(local.encoded > before)
        #expect(local.encoded.split(separator: "-")[1].count == 4)
    }

    @Test("never lags behind a clock it has seen")
    func observeAdvances() {
        var local = HybridLogicalClock(millis: 1000, counter: 0, node: "a")
        let remote = HybridLogicalClock(millis: 5000, counter: 3, node: "b")
        local.observe(remote, now: 1001)
        #expect(local.millis == 5000)
        #expect(local.encoded > remote.encoded)
    }

    @Test("500 successive stamps are strictly increasing under a frozen clock")
    func monotonicUnderFrozenClock() {
        var clock = HybridLogicalClock(millis: 1000, counter: 0, node: "a")
        var previous = ""
        for _ in 0..<500 {
            let next = clock.tick(now: 1000)
            #expect(next > previous)
            previous = next
        }
    }
}
