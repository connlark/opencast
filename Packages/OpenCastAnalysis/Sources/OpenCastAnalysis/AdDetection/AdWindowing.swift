/// Overlapping local-attention windows over a transcript.
public enum AdWindowing {
    /// `1 + ceil((n - window) / (window - overlap))` for n above one window.
    public static func windowCount(segmentCount: Int, policy: AdDetectionPolicy) -> Int {
        windowCount(segmentCount: segmentCount, windowSegments: policy.window.segments, overlapSegments: policy.window.overlap)
    }

    static func windowCount(segmentCount: Int, windowSegments: Int, overlapSegments: Int) -> Int {
        let stride = windowSegments - overlapSegments
        let excess = max(0, segmentCount - windowSegments)
        return 1 + (excess + stride - 1) / stride
    }

    /// Each window's segment range, in order.
    public static func windowRanges(segmentCount: Int, policy: AdDetectionPolicy) -> [Range<Int>] {
        let stride = policy.window.segments - policy.window.overlap
        return (0..<windowCount(segmentCount: segmentCount, policy: policy)).map { index in
            let start = index * stride
            return start..<min(start + policy.window.segments, segmentCount)
        }
    }

    public static func windows(of request: AdAnalysisRequest, policy: AdDetectionPolicy) -> [AdAnalysisRequest] {
        windowRanges(segmentCount: request.segments.count, policy: policy).map(request.window)
    }
}
