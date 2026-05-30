import Foundation
import Testing
@testable import OpenCastPlayback

@Suite("Streaming audio task registry")
struct StreamingAudioTaskRegistryTests {
    @Test("Completed task before install does not stay tracked")
    func completedTaskBeforeInstallDoesNotStayTracked() async {
        let registry = StreamingAudioTaskRegistry()
        let request = NSObject()
        let id = ObjectIdentifier(request)
        let task = Task<Void, Never> {}

        registry.reserve(id)
        registry.remove(id)
        await task.value

        #expect(!registry.install(task, for: id))
        #expect(registry.taskCount == 0)
    }

    @Test("Cancellation before install drains reservation")
    func cancellationBeforeInstallDrainsReservation() async {
        let registry = StreamingAudioTaskRegistry()
        let request = NSObject()
        let id = ObjectIdentifier(request)
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }

        registry.reserve(id)
        registry.cancel(id)

        #expect(!registry.install(task, for: id))
        await task.value
        #expect(registry.taskCount == 0)
    }

    @Test("Cancel all drains installed tasks")
    func cancelAllDrainsInstalledTasks() async {
        let registry = StreamingAudioTaskRegistry()
        let firstRequest = NSObject()
        let secondRequest = NSObject()
        let firstID = ObjectIdentifier(firstRequest)
        let secondID = ObjectIdentifier(secondRequest)
        let firstTask = cancellableTask()
        let secondTask = cancellableTask()

        registry.reserve(firstID)
        registry.reserve(secondID)
        #expect(registry.install(firstTask, for: firstID))
        #expect(registry.install(secondTask, for: secondID))

        registry.cancelAll()
        await firstTask.value
        await secondTask.value

        #expect(registry.taskCount == 0)
    }

    private func cancellableTask() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
    }
}
