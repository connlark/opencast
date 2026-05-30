extension BinaryFloatingPoint {
    var clamped01: Self {
        clamped(to: 0...1)
    }

    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
