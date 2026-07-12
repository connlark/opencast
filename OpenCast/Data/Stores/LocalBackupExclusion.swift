import Foundation

enum LocalBackupExclusion {
    nonisolated static func apply(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directory
        try mutableURL.setResourceValues(values)
    }
}
