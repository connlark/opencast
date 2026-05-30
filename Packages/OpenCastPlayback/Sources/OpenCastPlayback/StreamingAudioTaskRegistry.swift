import Foundation

nonisolated final class StreamingAudioTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var reservedTaskIDs: Set<ObjectIdentifier> = []
    private var cancelledTaskIDs: Set<ObjectIdentifier> = []
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    var taskCount: Int {
        lock.withLock {
            tasks.count
        }
    }

    func reserve(_ id: ObjectIdentifier) {
        lock.withLock {
            reservedTaskIDs.insert(id)
            cancelledTaskIDs.remove(id)
        }
    }

    @discardableResult
    func install(_ task: Task<Void, Never>, for id: ObjectIdentifier) -> Bool {
        let didInstall = lock.withLock {
            guard reservedTaskIDs.remove(id) != nil else {
                cancelledTaskIDs.remove(id)
                return false
            }

            guard cancelledTaskIDs.remove(id) == nil else {
                return false
            }

            tasks[id] = task
            return true
        }

        if !didInstall {
            task.cancel()
        }
        return didInstall
    }

    func cancel(_ id: ObjectIdentifier) {
        let task: Task<Void, Never>? = lock.withLock {
            if let task = tasks.removeValue(forKey: id) {
                return task
            }

            if reservedTaskIDs.remove(id) != nil {
                cancelledTaskIDs.insert(id)
            } else {
                cancelledTaskIDs.remove(id)
            }
            return nil
        }
        task?.cancel()
    }

    func remove(_ id: ObjectIdentifier) {
        lock.withLock {
            tasks[id] = nil
            reservedTaskIDs.remove(id)
            cancelledTaskIDs.remove(id)
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock {
            let tasksToCancel = Array(tasks.values)
            tasks.removeAll()
            reservedTaskIDs.removeAll()
            cancelledTaskIDs.removeAll()
            return tasksToCancel
        }

        for task in tasksToCancel {
            task.cancel()
        }
    }
}
