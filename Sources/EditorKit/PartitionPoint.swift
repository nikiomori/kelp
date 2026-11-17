extension RandomAccessCollection {
    /// Returns the first index whose element isn't `isBefore`, by binary search: every element that is comes first.
    public func partitionPoint(_ isBefore: (Element) -> Bool) -> Index {
        var low = startIndex, count = count
        while count > 0 {
            let half = count / 2, middle = index(low, offsetBy: half)
            if isBefore(self[middle]) {
                low = index(after: middle)
                count -= half + 1
            } else {
                count = half
            }
        }
        return low
    }
}
