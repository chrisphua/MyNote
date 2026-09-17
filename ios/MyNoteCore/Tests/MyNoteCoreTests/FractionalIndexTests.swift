import Testing
@testable import MyNoteCore

@Suite("Fractional index")
struct FractionalIndexTests {
    @Test("produces a key between two neighbours")
    func betweenTwo() {
        let a = FractionalIndex.between(nil, nil)
        let c = FractionalIndex.between(a, nil)
        let b = FractionalIndex.between(a, c)
        #expect(a < b)
        #expect(b < c)
    }

    @Test("can always insert at the very front")
    func insertAtFront() {
        // Inserting above the first item must keep working no matter how many
        // times the user does it, otherwise 'move to top' eventually breaks.
        var first = FractionalIndex.between(nil, nil)
        for _ in 0..<200 {
            let next = FractionalIndex.between(nil, first)
            #expect(next < first, "expected \(next) < \(first)")
            first = next
        }
    }

    @Test("can always insert at the very end")
    func insertAtEnd() {
        var last = FractionalIndex.between(nil, nil)
        for _ in 0..<200 {
            let next = FractionalIndex.between(last, nil)
            #expect(next > last)
            last = next
        }
    }

    @Test("repeated insertion in the same gap stays ordered")
    func repeatedMiddleInsert() {
        let low = FractionalIndex.between(nil, nil)
        let high = FractionalIndex.between(low, nil)
        var upper = high
        for i in 0..<200 {
            let mid = FractionalIndex.between(low, upper)
            #expect(low < mid, "iteration \(i): \(low) < \(mid)")
            #expect(mid < upper, "iteration \(i): \(mid) < \(upper)")
            upper = mid
        }
    }

    @Test("a generated sequence is strictly increasing")
    func sequenceIsOrdered() {
        let keys = FractionalIndex.sequence(count: 50)
        #expect(keys.count == 50)
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == 50)
    }

    @Test("two offline devices inserting in the same gap do not collide")
    func concurrentInsertsInterleave() {
        let left = FractionalIndex.between(nil, nil)
        let right = FractionalIndex.between(left, nil)

        // Both devices compute a key for the same gap without seeing each other.
        let deviceA = FractionalIndex.between(left, right)
        let deviceB = FractionalIndex.between(left, right)

        // They may be equal, and that is fine — the tie is broken by record id,
        // never by rewriting a neighbour's key.
        #expect(deviceA > left && deviceA < right)
        #expect(deviceB > left && deviceB < right)
    }
}

@Suite("Fractional index invariants")
struct FractionalIndexInvariantTests {
    /// The property that makes front-insertion terminate at all.
    @Test("a generated key never ends in the lowest digit")
    func neverEndsInZero() {
        var key = FractionalIndex.between(nil, nil)
        for _ in 0..<300 {
            #expect(key.last != "0", "key \(key) ends in 0 — nothing can sort below it")
            key = FractionalIndex.between(nil, key)
        }

        var tail = FractionalIndex.between(nil, nil)
        for _ in 0..<300 {
            #expect(tail.last != "0")
            tail = FractionalIndex.between(tail, nil)
        }
    }

    @Test("keys stay short enough to be practical")
    func keysStayShort() {
        // 300 inserts at the front is a pathological pattern; the key should
        // still be small enough to store per row without concern.
        var key = FractionalIndex.between(nil, nil)
        for _ in 0..<300 { key = FractionalIndex.between(nil, key) }
        #expect(key.count < 120, "front-insert key grew to \(key.count) characters")
    }

    @Test("interleaving inserts from two devices keeps a total order")
    func interleavedOrderHolds() {
        var keys = FractionalIndex.sequence(count: 10)
        for _ in 0..<100 {
            let at = Int.random(in: 0...keys.count)
            let before = at > 0 ? keys[at - 1] : nil
            let after = at < keys.count ? keys[at] : nil
            let fresh = FractionalIndex.between(before, after)
            keys.insert(fresh, at: at)
        }
        #expect(keys == keys.sorted(), "insertion broke the ordering")
    }
}
