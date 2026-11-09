// An unstable sort in place: no buffer, and the comparison inlined into the caller's specialization. The standard
// library's `sort` is a stable merge sort that allocates scratch space and calls its comparison through a closure,
// which is the right default and costs a server sorting small batches on every request.

extension MutableSpan {
    /// Sorts in place by `less`, a strict weak order; equal elements may end up in any order.
    ///
    /// Introsort (Musser, 1997): quicksort with Hoare's partition around the median of three, runs of up to 16 finished
    /// by insertion sort, and heapsort for a range that keeps splitting badly, so the worst case is O(n log n).
    @inlinable @inline(__always) public mutating func sortUnstable(by less: (Element, Element) -> Bool) {
        withUnsafeMutableBufferPointer { Sorting.introsort($0, by: less) }
    }
}

extension MutableSpan where Element: Comparable {
    /// Sorts in place, ascending; equal elements may end up in any order.
    @inlinable @inline(__always) public mutating func sortUnstable() {
        sortUnstable(by: <)
    }
}

extension Array {
    /// Sorts in place by `less`, a strict weak order; equal elements may end up in any order. See
    /// `MutableSpan.sortUnstable(by:)`.
    @inlinable @inline(__always) public mutating func sortUnstable(by less: (Element, Element) -> Bool) {
        withUnsafeMutableBufferPointer { Sorting.introsort($0, by: less) }
    }
}

extension Array where Element: Comparable {
    /// Sorts in place, ascending; equal elements may end up in any order.
    @inlinable @inline(__always) public mutating func sortUnstable() {
        sortUnstable(by: <)
    }
}

@usableFromInline enum Sorting {
    @inlinable @inline(__always)
    static func introsort<Element>(_ a: UnsafeMutableBufferPointer<Element>, by less: (Element, Element) -> Bool) {
        guard a.count > 1, let p = a.baseAddress else { return }
        if a.count <= 16 { return insertionSort(p, 0, a.count, by: less) }
        // Ranges still to sort, the larger part of each split, so at most log2(count) of them wait.
        var pending = InlineArray<64, (lo: Int, hi: Int, depth: Int)>(repeating: (0, 0, 0))
        var waiting = 0
        var lo = 0
        var hi = a.count
        var depth = 2 * (Int.bitWidth - a.count.leadingZeroBitCount)
        while true {
            let n = hi - lo
            if n <= 16 {
                insertionSort(p, lo, hi, by: less)
            } else if depth == 0 {
                heapsort(p + lo, n, by: less)
            } else {
                depth -= 1
                // Around the median of the first, middle and last: [lo, split) <= pivot <= [split, hi).
                let mid = lo + (n - 1) / 2
                if less(p[mid], p[lo]) { swap(p, mid, lo) }
                if less(p[hi - 1], p[mid]) {
                    swap(p, hi - 1, mid)
                    if less(p[mid], p[lo]) { swap(p, mid, lo) }
                }
                let pivot = p[mid]
                var i = lo - 1
                var j = hi
                while true {
                    repeat { i += 1 } while less(p[i], pivot)
                    repeat { j -= 1 } while less(pivot, p[j])
                    if i >= j { break }
                    swap(p, i, j)
                }
                let split = j + 1
                if split - lo < hi - split {
                    pending[waiting] = (split, hi, depth)
                    hi = split
                } else {
                    pending[waiting] = (lo, split, depth)
                    lo = split
                }
                waiting += 1
                continue
            }
            if waiting == 0 { return }
            waiting -= 1
            (lo, hi, depth) = pending[waiting]
        }
    }

    @inlinable @inline(__always)
    static func insertionSort<Element>(_ p: UnsafeMutablePointer<Element>, _ lo: Int, _ hi: Int,
                                       by less: (Element, Element) -> Bool) {
        for i in (lo + 1)..<hi {
            let x = p[i]
            var j = i
            while j > lo && less(x, p[j - 1]) {
                p[j] = p[j - 1]
                j -= 1
            }
            p[j] = x
        }
    }

    @inlinable @inline(__always)
    static func heapsort<Element>(_ p: UnsafeMutablePointer<Element>, _ n: Int, by less: (Element, Element) -> Bool) {
        func siftDown(_ start: Int, _ end: Int) {
            var root = start
            while true {
                var child = 2 * root + 1
                if child >= end { return }
                if child + 1 < end && less(p[child], p[child + 1]) { child += 1 }
                if !less(p[root], p[child]) { return }
                swap(p, root, child)
                root = child
            }
        }
        guard n > 1 else { return }
        for start in stride(from: n / 2 - 1, through: 0, by: -1) { siftDown(start, n) }
        for end in stride(from: n - 1, to: 0, by: -1) {
            swap(p, 0, end)
            siftDown(0, end)
        }
    }

    @inlinable @inline(__always) static func swap<Element>(_ p: UnsafeMutablePointer<Element>, _ i: Int, _ j: Int) {
        let t = p[i]
        p[i] = p[j]
        p[j] = t
    }
}
