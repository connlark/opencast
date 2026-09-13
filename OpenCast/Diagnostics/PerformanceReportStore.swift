import Foundation

actor PerformanceReportStore {
    static let shared = PerformanceReportStore()
    let directory: URL
    private let maximumCount: Int
    private let maximumBytes: Int
    private var lastError: PerformanceReportError?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Diagnostics/Performance", directoryHint: .isDirectory), maximumCount: Int = 20, maximumBytes: Int = 20 * 1024 * 1024) {
        self.directory = directory
        self.maximumCount = max(1, maximumCount)
        self.maximumBytes = max(1, maximumBytes)
    }

    func receive(_ report: PerformanceReport) {
        do {
            try save(report)
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            lastError = error as? PerformanceReportError ?? .unavailable
        }
        observers.values.forEach { $0.yield() }
    }

    func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    deinit { observers.values.forEach { $0.finish() } }

    func failure() -> PerformanceReportError? { lastError }

    func save(_ report: PerformanceReport) throws {
        try Task.checkCancellation()
        try report.validate()
        let data = try JSONEncoder().encode(report)
        guard data.count <= maximumBytes else { throw PerformanceReportError.oversized }
        try prepareDirectory()
        try data.write(to: directory.appending(path: "\(report.id.uuidString).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try prune()
    }

    func reports() throws -> [PerformanceReport] {
        try prepareDirectory()
        try prune()
        return try files().map { entry in
            try Task.checkCancellation()
            let report = try JSONDecoder().decode(PerformanceReport.self, from: Data(contentsOf: entry.url))
            try report.validate()
            return report
        }.sorted { $0.receivedAt > $1.receivedAt }
    }

    func export(to destination: URL) throws -> URL {
        do {
            let reports = try reports()
            guard !reports.isEmpty else { throw PerformanceReportError.empty }
            let data = try JSONEncoder().encode(reports)
            try Task.checkCancellation()
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return destination
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PerformanceReportError {
            throw error
        } catch {
            throw PerformanceReportError.unavailable
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func files() throws -> [(url: URL, bytes: Int, date: Date)] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { ($0.date, $0.url.lastPathComponent) < ($1.date, $1.url.lastPathComponent) }
    }

    private func prune() throws {
        let entries = try files()
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        var count = entries.count
        for entry in entries where count > maximumCount || bytes > maximumBytes {
            try FileManager.default.removeItem(at: entry.url)
            bytes -= entry.bytes
            count -= 1
        }
    }
}
