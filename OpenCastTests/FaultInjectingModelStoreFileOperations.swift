import Foundation
import Synchronization
@testable import OpenCast

/// The real file operations, recorded call by call, with failures injected
/// where a test asks: a throw on the n-th call of a method at a path, a tree
/// removal or copy that stops after half its files, and chosen `status`
/// answers.
final class FaultInjectingModelStoreFileOperations: ModelStoreFileOperations {
    enum Method: Hashable, Sendable {
        case status, entryNames, createDirectory, removeItem, copyItem, rename
    }

    struct Call: Hashable, Sendable {
        let method: Method
        /// The URL acted on; for a copy or a rename, the source.
        let url: URL
        let destination: URL?

        var isMutation: Bool {
            method != .status && method != .entryNames
        }
    }

    enum StatusAnswer: Sendable {
        case exists(ModelStoreFileStatus)
        case deviceNumber(Int)
        case failure(POSIXErrorCode)
    }

    private struct Fault: Sendable {
        enum Effect: Sendable {
            case fail(POSIXErrorCode)
            case stopPartway
        }

        let method: Method
        let path: String
        let callNumber: Int
        let effect: Effect
    }

    private struct State: Sendable {
        var calls: [Call] = []
        var faults: [Fault] = []
        var statusAnswers: [String: StatusAnswer] = [:]
    }

    private let base = DefaultModelStoreFileOperations()
    private let state = Mutex(State())

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    var mutations: [Call] {
        calls.filter(\.isMutation)
    }

    /// Fails the `callNumber`-th call of `method` at `url` before it acts.
    func fail(_ method: Method, at url: URL, onCall callNumber: Int = 1, with code: POSIXErrorCode = .EIO) {
        state.withLock {
            $0.faults.append(Fault(method: method, path: Self.key(url), callNumber: callNumber, effect: .fail(code)))
        }
    }

    /// Makes the first `removeItem` or `copyItem` of the tree at `url` act on
    /// half of its files, then throw.
    func stopPartway(_ method: Method, at url: URL) {
        precondition(method == .removeItem || method == .copyItem)
        state.withLock {
            $0.faults.append(Fault(method: method, path: Self.key(url), callNumber: 1, effect: .stopPartway))
        }
    }

    func answerStatus(_ answer: StatusAnswer, for url: URL) {
        state.withLock {
            $0.statusAnswers[Self.key(url)] = answer
        }
    }

    func status(at url: URL) throws -> ModelStoreFileStatus? {
        let fault = record(.status, url)
        if case .fail(let code) = fault {
            throw POSIXError(code)
        }
        switch state.withLock({ $0.statusAnswers[Self.key(url)] }) {
        case .exists(let status):
            return status
        case .deviceNumber(let deviceNumber):
            return try base.status(at: url).map {
                ModelStoreFileStatus(isDirectory: $0.isDirectory, size: $0.size, deviceNumber: deviceNumber)
            }
        case .failure(let code):
            throw POSIXError(code)
        case nil:
            return try base.status(at: url)
        }
    }

    func entryNames(in directory: URL) throws -> [String] {
        if case .fail(let code) = record(.entryNames, directory) {
            throw POSIXError(code)
        }
        return try base.entryNames(in: directory)
    }

    func createDirectory(at url: URL) throws {
        if case .fail(let code) = record(.createDirectory, url) {
            throw POSIXError(code)
        }
        try base.createDirectory(at: url)
    }

    func removeItem(at url: URL) throws {
        switch record(.removeItem, url) {
        case .fail(let code):
            throw POSIXError(code)
        case .stopPartway:
            for file in try Self.halfOfTheFiles(under: url) {
                try FileManager.default.removeItem(at: url.appending(path: file))
            }
            throw POSIXError(.EIO)
        case nil:
            try base.removeItem(at: url)
        }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        switch record(.copyItem, source, destination) {
        case .fail(let code):
            throw POSIXError(code)
        case .stopPartway:
            for file in try Self.halfOfTheFiles(under: source) {
                let target = destination.appending(path: file)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source.appending(path: file), to: target)
            }
            throw POSIXError(.EIO)
        case nil:
            try base.copyItem(at: source, to: destination)
        }
    }

    func rename(_ source: URL, to destination: URL) throws {
        if case .fail(let code) = record(.rename, source, destination) {
            throw POSIXError(code)
        }
        try base.rename(source, to: destination)
    }

    /// Records the call and answers the fault armed for it, if any.
    private func record(_ method: Method, _ url: URL, _ destination: URL? = nil) -> Fault.Effect? {
        state.withLock { state in
            state.calls.append(Call(method: method, url: url, destination: destination))
            let path = Self.key(url)
            let callNumber = state.calls.count(where: { $0.method == method && Self.key($0.url) == path })
            return state.faults.first { $0.method == method && $0.path == path && $0.callNumber == callNumber }?.effect
        }
    }

    /// The tree's regular files in sorted order, the first half of them (at
    /// least one), so the stop lands inside a nested directory.
    private static func halfOfTheFiles(under url: URL) throws -> [String] {
        let root = url.path(percentEncoded: false)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root)
            .filter { subpath in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.appending(path: subpath).path(percentEncoded: false), isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }
            .sorted()
        precondition(files.count >= 2, "a partway stop needs a tree with at least two files")
        return Array(files.prefix(files.count / 2))
    }

    static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
