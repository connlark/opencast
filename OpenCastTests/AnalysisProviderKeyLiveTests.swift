import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Testing
@testable import OpenCast

/// A real key checked against its provider through the real transport. Each
/// test runs only where the environment names a readable file holding a key
/// (set it as `TEST_RUNNER_<key>` on the xcodebuild environment). The key is
/// read by path, never printed, attached or saved to the Keychain.
@MainActor
@Suite("Provider key live check")
struct AnalysisProviderKeyLiveTests {
    @Test("A Google key named by the environment is accepted", .enabled(if: LiveKeyFile.path(for: .google) != nil))
    func googleKeyIsAccepted() async throws {
        let result = try await liveResult(for: .google)
        #expect(result == .accepted)
    }

    @Test("An OpenAI key named by the environment is accepted", .enabled(if: LiveKeyFile.path(for: .openai) != nil))
    func openAIKeyIsAccepted() async throws {
        let result = try await liveResult(for: .openai)
        #expect(result == .accepted)
    }

    /// Kept out of every expectation macro: a failing macro prints the
    /// values of its subexpressions.
    private func liveResult(for provider: AnalysisProvider) async throws -> AnalysisKeyTestResult? {
        guard let path = LiveKeyFile.path(for: provider) else {
            Issue.record("No readable key file for \(provider.rawValue)")
            return nil
        }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        guard let key = AnalysisProviderKey(contents) else {
            Issue.record("The \(provider.rawValue) key file holds no key")
            return nil
        }
        return await AnalysisProviderKeyTester().test(key, provider: provider, snapshot: .baked)
    }
}

private enum LiveKeyFile {
    static func path(for provider: AnalysisProvider) -> String? {
        let variable = switch provider {
        case .google: "OPENCAST_ANALYSIS_LIVE_GOOGLE_KEY_FILE"
        case .openai: "OPENCAST_ANALYSIS_LIVE_OPENAI_KEY_FILE"
        }
        guard let path = ProcessInfo.processInfo.environment[variable],
              FileManager.default.isReadableFile(atPath: path)
        else {
            return nil
        }
        return path
    }
}
