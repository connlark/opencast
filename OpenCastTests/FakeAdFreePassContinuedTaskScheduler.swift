import Foundation
@testable import OpenCast

@MainActor
final class FakeAdFreePassContinuedTaskScheduler: AdFreePassContinuedTaskScheduling {
    private let submitError: Error?
    var supportsGPUResources = false
    /// Consumed one per submit call (nil = succeed); `submitError` applies
    /// once the queue is empty.
    var submitErrorsByCall: [Error?] = []
    private(set) var registerCallCount = 0
    private(set) var submitCallCount = 0
    private(set) var submittedGPUFlags: [Bool] = []
    private(set) var cancelledIdentifiers: [String] = []
    private var onLaunch: (@MainActor @Sendable (any AdFreePassContinuedTaskHandle) -> Void)?

    init(submitError: Error? = nil) {
        self.submitError = submitError
    }

    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AdFreePassContinuedTaskHandle) -> Void
    ) -> Bool {
        registerCallCount += 1
        self.onLaunch = onLaunch
        return true
    }

    func submit(identifier: String, title: String, subtitle: String, requiresGPU: Bool) throws {
        submitCallCount += 1
        submittedGPUFlags.append(requiresGPU)
        if !submitErrorsByCall.isEmpty {
            if let error = submitErrorsByCall.removeFirst() {
                throw error
            }
            return
        }
        if let submitError {
            throw submitError
        }
    }

    func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
    }

    func launch(_ handle: FakeAdFreePassContinuedTaskHandle) {
        onLaunch?(handle)
    }
}

@MainActor
final class FakeAdFreePassContinuedTaskHandle: AdFreePassContinuedTaskHandle {
    let progress = Progress(totalUnitCount: 0)
    private(set) var titleUpdates: [(title: String, subtitle: String)] = []
    private(set) var completions: [Bool] = []
    private var expirationHandler: (@Sendable () -> Void)?

    func updateTitle(_ title: String, subtitle: String) {
        titleUpdates.append((title, subtitle))
    }

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        expirationHandler = handler
    }

    func expire() {
        expirationHandler?()
    }
}
