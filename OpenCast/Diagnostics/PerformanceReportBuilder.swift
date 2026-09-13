import Foundation
import MetricKit

nonisolated struct PerformanceReportBuilder: Sendable {
    let appVersion: String
    let toolchainVersion: String

    func metrics(_ source: MetricReport) -> PerformanceReport {
        var report = base(.metrics, timeRange: source.timeRange)
        report.sourceAppVersion = source.environment?.latestApplicationVersion
        report.includesMultipleAppVersions = source.environment?.includesMultipleApplicationVersions ?? false
        if !source.intervalEntries.isEmpty {
            report.measurements = measurements(source.intervalEntries.fullDayEntry.values)
        }
        report.contexts = source.stateEntries.prefix(100).compactMap { entry in
            guard let state = state(entry.state) else { return nil }
            return PerformanceReportContext(state: state, durationSeconds: entry.state.duration.converted(to: .seconds).value, measurements: measurements(entry.values))
        }
        return report
    }

    func diagnostic(_ source: DiagnosticReport) -> PerformanceReport {
        var report: PerformanceReport
        let stack: CallStackTree
        switch source.result {
        case .crash(let value):
            report = base(.crash, timeRange: source.timeRange)
            stack = value.callStackTree
        case .hang(let value):
            report = base(.hang, timeRange: source.timeRange)
            report.measurements = [PerformanceMeasurement(name: .hangSeconds, value: value.hangDuration.converted(to: .seconds).value)]
            stack = value.callStackTree
        case .cpuException(let value):
            report = base(.cpuException, timeRange: source.timeRange)
            report.measurements = [PerformanceMeasurement(name: .cpuSeconds, value: value.totalCPUTime.converted(to: .seconds).value)]
            stack = value.callStackTree
        case .diskWriteException(let value):
            report = base(.diskWriteException, timeRange: source.timeRange)
            report.measurements = [PerformanceMeasurement(name: .diskWriteBytes, value: value.totalBytesWritten.converted(to: .bytes).value)]
            stack = value.callStackTree
        case .appLaunch(let value):
            report = base(.launch, timeRange: source.timeRange)
            report.measurements = [PerformanceMeasurement(name: .launchSeconds, value: value.launchDuration.converted(to: .seconds).value)]
            stack = value.callStackTree
        case .memoryException(let value):
            report = base(.memoryException, timeRange: source.timeRange)
            stack = value.callStackTree
        @unknown default:
            return base(.metrics, timeRange: source.timeRange)
        }
        report.states = source.environment.states.prefix(100).compactMap(state)
        report.sourceAppVersion = source.environment.applicationVersion
        // Retain symbolication coordinates, never exception strings, signpost
        // arguments, binary paths, or arbitrary framework metadata.
        for (thread, value) in stack.callStackThreads.enumerated() {
            var pending = value.rootFrames.map { (frame: $0, depth: 0) }
            while let next = pending.popLast(), report.frames.count < 4096 {
                let frame = next.frame
                report.frames.append(PerformanceStackFrame(binaryUUID: frame.binaryUUID, address: frame.address, offset: frame.offsetIntoBinaryTextSegment, samples: frame.sampleCount, depth: next.depth, thread: thread))
                pending.append(contentsOf: frame.subFrames.prefix(4096 - report.frames.count).map { ($0, next.depth + 1) })
            }
            if report.frames.count == 4096 { break }
        }
        return report
    }

    private func base(_ kind: PerformanceReport.Kind, timeRange: DateInterval) -> PerformanceReport {
        PerformanceReport(id: UUID(), receivedAt: .now, appVersion: appVersion, toolchainVersion: toolchainVersion, kind: kind, timeRange: timeRange)
    }

    private func state(_ source: MetricManager.ReportedState) -> PerformanceState? {
        guard let domain = PerformanceState.Domain.allCases.first(where: { $0.identifier == source.domain }) else { return nil }
        return PerformanceState(domain: domain, label: source.label)
    }

    private func measurements(_ results: [MetricResult]) -> [PerformanceMeasurement] {
        var values: [PerformanceMeasurement] = []
        for result in results {
            switch result {
            case .timeToFirstDraw(let metric): values += histogram(metric.histogram, name: .launchSeconds)
            case .applicationResumeTime(let metric): values += histogram(metric.histogram, name: .resumeSeconds)
            case .hangTime(let metric): values += histogram(metric.histogram, name: .hangSeconds)
            case .hitchTime(let metric):
                values.append(PerformanceMeasurement(name: .animationHitchSeconds, value: metric.totalHitchTime.converted(to: .seconds).value))
                values.append(PerformanceMeasurement(name: .animationSeconds, value: metric.totalAnimationTime.converted(to: .seconds).value))
            case .cpuTime(let metric): values.append(PerformanceMeasurement(name: .cpuSeconds, value: metric.value.converted(to: .seconds).value))
            case .gpuTime(let metric): values.append(PerformanceMeasurement(name: .gpuSeconds, value: metric.value.converted(to: .seconds).value))
            case .peakMemory(let metric): values.append(PerformanceMeasurement(name: .peakMemoryBytes, value: metric.value.converted(to: .bytes).value))
            case .logicalDiskWrites(let metric): values.append(PerformanceMeasurement(name: .diskWriteBytes, value: metric.value.converted(to: .bytes).value))
            case .totalForegroundTime(let metric): values.append(PerformanceMeasurement(name: .foregroundSeconds, value: metric.value.converted(to: .seconds).value))
            case .totalBackgroundAudioTime(let metric): values.append(PerformanceMeasurement(name: .backgroundAudioSeconds, value: metric.value.converted(to: .seconds).value))
            default: break
            }
        }
        return Array(values.prefix(10_000))
    }

    private func histogram(_ histogram: Histogram<UnitDuration>, name: PerformanceMeasurement.Name) -> [PerformanceMeasurement] {
        histogram.buckets.prefix(500).map {
            PerformanceMeasurement(name: name, value: $0.lowerBound.converted(to: .seconds).value, upperBound: $0.upperBound.converted(to: .seconds).value, count: $0.count)
        }
    }
}
