import Foundation

actor AudioSessionDeactivationProbe {
    private var callCount = 0
    private var isReleased = false

    func deactivate() async {
        callCount += 1
        while !isReleased {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
    }

    func recordedCallCount() -> Int {
        callCount
    }
}
