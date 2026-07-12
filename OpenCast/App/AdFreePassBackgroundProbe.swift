#if DEBUG
@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit

enum AdFreePassBackgroundProbe {
    nonisolated static let requestArgument = "--adfreepass-bg-probe"
    nonisolated static let requestEnvironmentKey = "OPENCAST_ADFREEPASS_BG_PROBE"

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "AdFreePassBackgroundProbe")
    private static let tickCount: Int64 = 360

    @MainActor private static var hasRegistered = false
    @MainActor private static var hasSubmitted = false
    @MainActor private static var hasResetLogThisProcess = false
    @MainActor private static var runSequence = 0
    @MainActor private static var activeRun: Int?
    @MainActor private static var tickTask: Task<Void, Never>?
    @MainActor private static var activeHandle: (any AdFreePassContinuedTaskHandle)?
    @MainActor private static var cancellationSource = AdFreePassCancellationSource()

    nonisolated static var isUserInterfaceEnabled: Bool {
        isRequestedByLaunchConfiguration
    }

    @MainActor
    static func runIfRequested() {
        guard isRequestedByLaunchConfiguration else {
            return
        }

        start(trigger: "launch")
    }

    @MainActor
    static func startFromUserAction() {
        start(trigger: "user-action")
    }

    @MainActor
    private static func start(trigger: String) {
        guard !hasSubmitted else {
            record("probe ignored trigger=\(trigger) reason=active-submission")
            return
        }

        if !hasResetLogThisProcess {
            resetLog()
            hasResetLogThisProcess = true
        }
        runSequence += 1
        let run = runSequence

        record("run \(run) probe requested trigger=\(trigger)")
        recordEnvironment(run: run)
        let scheduler = BGTaskSchedulerAdFreePassScheduler()
        let identifier = EpisodeAdFreePassBackgroundSession.identifier
        record("run \(run) identifier=\(identifier)")
        if !hasRegistered {
            hasRegistered = scheduler.registerLaunchHandler(identifier: identifier) { handle in
                handleLaunch(handle)
            }
            logger.log("probe registration result=\(hasRegistered)")
            record("run \(run) registration result=\(hasRegistered)")
        } else {
            record("run \(run) registration reused=true")
        }

        guard hasRegistered else {
            return
        }

        do {
            let requiresGPU = scheduler.supportsGPUResources
            record("run \(run) submission strategy=fail gpu=\(requiresGPU)")
            try scheduler.submit(
                identifier: identifier,
                title: "Skip Promos & Ads",
                subtitle: "Background probe starting",
                requiresGPU: requiresGPU
            )
            hasSubmitted = true
            activeRun = run
            logger.log("probe submitted")
            record("run \(run) submitted")
            recordPendingRequests(run: run, label: "immediate")
            recordDelayedPendingRequests(run: run)
        } catch {
            logger.error("probe submission failed: \(error.localizedDescription, privacy: .public)")
            record("run \(run) submission failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handleLaunch(_ handle: any AdFreePassContinuedTaskHandle) {
        let run = activeRun ?? runSequence
        logger.log("probe launch handler fired")
        record("run \(run) launch handler fired")
        activeHandle = handle
        handle.progress.totalUnitCount = tickCount
        handle.progress.completedUnitCount = 0
        handle.updateTitle("Skip Promos & Ads", subtitle: "Background probe 0s")
        let cancellationSource = cancellationSource
        let completionGate = AdFreePassOnceGate()
        let expirationGate = AdFreePassOnceGate()
        handle.setExpirationHandler { [cancellationSource, completionGate, expirationGate] in
            guard expirationGate.pass() else {
                return
            }

            cancellationSource.cancel()
            Task { @MainActor in
                logger.log("probe expiration handler fired")
                record("run \(run) expiration handler fired")
                tickTask?.cancel()
                tickTask = nil
                if completionGate.pass() {
                    activeHandle?.setTaskCompleted(success: false)
                    record("run \(run) completed success=false")
                }
                activeHandle = nil
                hasSubmitted = false
                activeRun = nil
                cancellationSource.clearTask()
            }
        }

        tickTask?.cancel()
        let task = Task { @MainActor [completionGate, cancellationSource] in
            for second in 1...tickCount {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }

                activeHandle?.progress.completedUnitCount = second
                activeHandle?.updateTitle("Skip Promos & Ads", subtitle: "Background probe \(second)s")
                logger.log("probe tick \(second)")
                record("run \(run) tick \(second)")
            }

            activeHandle?.updateTitle("Skip Promos & Ads", subtitle: "Background probe complete")
            if completionGate.pass() {
                activeHandle?.setTaskCompleted(success: true)
                logger.log("probe completed")
                record("run \(run) completed success=true")
            }
            activeHandle = nil
            tickTask = nil
            hasSubmitted = false
            activeRun = nil
            cancellationSource.clearTask()
        }
        tickTask = task
        cancellationSource.start(task)
    }

    @MainActor
    private static func resetLog() {
        try? FileManager.default.removeItem(at: logURL)
    }

    @MainActor
    private static func record(_ message: String) {
        let line = "\(Date.now) \(message)\n"
        let data = Data(line.utf8)
        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            handle.write(data)
            try handle.close()
        } catch {
            logger.error("probe file log failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var logURL: URL {
        URL.documentsDirectory.appending(path: "adfreepass-bg-probe.log")
    }

    private nonisolated static var isRequestedByLaunchConfiguration: Bool {
        let processInfo = ProcessInfo.processInfo
        let arguments = Set(processInfo.arguments)
        let environment = processInfo.environment
        return arguments.contains(requestArgument) || environment[requestEnvironmentKey] == "1"
    }

    @MainActor
    private static func recordEnvironment(run: Int) {
        record("run \(run) application state=\(UIApplication.shared.applicationState.probeDescription)")
        record("run \(run) background refresh status=\(UIApplication.shared.backgroundRefreshStatus.probeDescription)")
        record("run \(run) low power mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        record("run \(run) supported resources raw=\(BGTaskScheduler.supportedResources.rawValue)")
    }

    private static func recordPendingRequests(run: Int, label: String) {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let count = requests.count
            let identifiers = requests.map(\.identifier).joined(separator: ",")
            Task { @MainActor in
                record("run \(run) pending requests \(label) count=\(count) identifiers=\(identifiers)")
            }
        }
    }

    private static func recordDelayedPendingRequests(run: Int) {
        let delays: [Duration] = [.seconds(1), .seconds(5), .seconds(15)]
        for delay in delays {
            Task {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                recordPendingRequests(run: run, label: "\(delay.components.seconds)s")
            }
        }
    }
}

private extension UIApplication.State {
    var probeDescription: String {
        switch self {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown"
        }
    }
}

private extension UIBackgroundRefreshStatus {
    var probeDescription: String {
        switch self {
        case .available:
            "available"
        case .denied:
            "denied"
        case .restricted:
            "restricted"
        @unknown default:
            "unknown"
        }
    }
}
#endif
