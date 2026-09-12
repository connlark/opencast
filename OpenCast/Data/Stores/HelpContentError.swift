import Foundation

nonisolated enum HelpContentError: LocalizedError, Equatable {
    case missingBundledDocument
    case unsupportedSchema(Int)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingBundledDocument:
            "The bundled help content is missing."
        case .unsupportedSchema(let version):
            "Help content schema \(version) is not supported by this version of opencast."
        case .httpStatus(let statusCode):
            "Help content request failed with HTTP \(statusCode)."
        }
    }
}
