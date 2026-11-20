import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization

/// `reserve` must print `{"reservation": ID}`, and a nonzero exit refuses the exchange. `settle`,
/// `release` or `ambiguous` then closes the reservation.
struct SpendHook: Sendable {
    let executable: URL

    static let terminationGraceSeconds = 1.0
    static let maximumOutputBytes = 64 * 1024

    enum Ending: Sendable, Equatable {
        case exited(Int32)
        case timedOut
        case cancelled
        case failedToStart
    }

    struct Reply: Sendable {
        var ending: Ending
        var output: JSONValue?
        var signal: Int32?

        var status: Int32 {
            if case .exited(let status) = ending { status } else { -1 }
        }
    }

    func run(_ arguments: [String], timeoutSeconds: Double) async -> Reply {
        guard let child = HookProcess(executable: executable, arguments: arguments) else {
            return Reply(ending: .failedToStart, output: nil)
        }
        let limit = AnalysisProviderLimits.waitSeconds(timeoutSeconds)
        var ending: Ending = await withTaskCancellationHandler {
            await withTaskGroup(of: Ending.self) { group in
                group.addTask { .exited(await child.finished()) }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(limit))
                        return .timedOut
                    } catch {
                        return .cancelled
                    }
                }
                let first = await group.next() ?? .cancelled
                if case .exited = first {
                    group.cancelAll()
                } else {
                    // Stop the group before leaving the task group, which
                    // waits for the hook to exit and its output to close.
                    child.stop()
                }
                return first
            }
        } onCancel: {
            child.stop()
        }
        // A hook that ends because it was stopped did not finish its work.
        if case .exited = ending, child.wasStopped {
            ending = Task.isCancelled ? .cancelled : .timedOut
        }
        child.killLeftovers()
        guard case .exited = ending else { return Reply(ending: ending, output: nil, signal: child.signal) }
        return Reply(ending: ending, output: child.output(), signal: child.signal)
    }
}

private final class HookProcess: Sendable {
    private struct State {
        var status: Int32?
        var signal: Int32?
        var outputClosed = false
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var stopped = false
        var output = Data()
        var overflowed = false
    }

    let pid: pid_t
    private let state = Mutex(State())
    private let reader: any DispatchSourceRead

    init?(executable: URL, arguments: [String]) {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return nil }
        let (readFD, writeFD) = (pipeFDs[0], pipeFDs[1])
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)
        // Default signal actions and an empty mask: a host that ignores or blocks SIGTERM would
        // pass that on, and every stop would wait for SIGKILL.
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        let path = executable.path(percentEncoded: false)
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var spawned: pid_t = 0
        let result = posix_spawn(&spawned, path, &actions, &attributes, argv, envp)
        close(writeFD)
        guard result == 0 else {
            close(readFD)
            return nil
        }
        pid = spawned
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        reader = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: DispatchQueue(label: "spend-hook.stdout"))
        reader.setEventHandler { [self] in drain(readFD) }
        reader.setCancelHandler { [self] in
            close(readFD)
            closeOutput()
        }
        reader.resume()
        // Reap the hook on a thread of its own; waitpid blocks until it exits.
        let pid = spawned
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            // Exited: the exit code; killed: the signal number, as Process reports it.
            let signal = status & 0x7F
            recordExit(signal == 0 ? (status >> 8) & 0xFF : signal, signal: signal == 0 ? nil : signal)
        }
    }

    /// The exit status, once the hook has exited and its output is closed.
    func finished() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let status = state.withLock { state -> Int32? in
                if let status = state.status, state.outputClosed { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    var wasStopped: Bool { state.withLock { $0.stopped } }

    var signal: Int32? { state.withLock { $0.signal } }

    /// The last step gives up the output, in case a process outside the group holds the pipe.
    func stop() {
        let first = state.withLock { state -> Bool in
            defer { state.stopped = true }
            return !state.stopped && !(state.status != nil && state.outputClosed)
        }
        guard first else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + SpendHook.terminationGraceSeconds) { [self] in
            if state.withLock({ $0.status == nil || !$0.outputClosed }) {
                kill(-pid, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + SpendHook.terminationGraceSeconds) { [self] in
                if state.withLock({ !$0.outputClosed }) { reader.cancel() }
            }
        }
    }

    func killLeftovers() {
        kill(-pid, SIGKILL)
    }

    func output() -> JSONValue? {
        let (data, overflowed) = state.withLock { ($0.output, $0.overflowed) }
        guard !overflowed else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONParser.parse(text)
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                state.withLock { state in
                    let room = SpendHook.maximumOutputBytes - state.output.count
                    if count > room { state.overflowed = true }
                    if room > 0 { state.output.append(contentsOf: buffer[0..<min(count, room)]) }
                }
                continue
            }
            if count == 0 || (errno != EAGAIN && errno != EINTR) { reader.cancel() }
            return
        }
    }

    private func recordExit(_ status: Int32, signal: Int32?) {
        resumeIfFinished {
            $0.status = status
            $0.signal = signal
        }
    }

    private func closeOutput() {
        resumeIfFinished { $0.outputClosed = true }
    }

    private func resumeIfFinished(_ change: (inout State) -> Void) {
        let (status, waiters) = state.withLock { state -> (Int32?, [CheckedContinuation<Int32, Never>]) in
            change(&state)
            guard let status = state.status, state.outputClosed else { return (nil, []) }
            defer { state.waiters = [] }
            return (status, state.waiters)
        }
        if let status { waiters.forEach { $0.resume(returning: status) } }
    }
}
