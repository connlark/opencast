import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftUI

/// The key field's footer: "Testing…", the last test's outcome, or the
/// warning that the field does not hold a whole key. The icon carries the
/// outcome's color and shape; the text keeps the footer style.
struct AnalysisKeyTestStatusLabel: View {
    let provider: AnalysisProvider
    let isTesting: Bool
    let result: AnalysisKeyTestResult?
    /// Google accepted the key and then named it free tier.
    var isFreeTier = false
    let showsImplausibleWarning: Bool

    var body: some View {
        if isTesting {
            Label {
                Text(AIServicesCopy.testing)
            } icon: {
                ProgressView()
            }
        } else if let result {
            Label {
                Text(Self.text(for: result, isFreeTier: isFreeTier, provider: provider))
            } icon: {
                Image(systemName: systemImage(for: result))
                    .foregroundStyle(color(for: result))
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("AI Services Test Result")
        } else if showsImplausibleWarning {
            Label {
                Text(AIServicesCopy.implausibleKey)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    static func text(for result: AnalysisKeyTestResult, isFreeTier: Bool, provider: AnalysisProvider) -> String {
        isFreeTier ? AIServicesCopy.testResultFreeTier : AIServicesCopy.testResult(result, provider: provider)
    }

    private func systemImage(for result: AnalysisKeyTestResult) -> String {
        switch result {
        case .accepted: isFreeTier ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        case .failed(.invalidKey): "xmark.octagon.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(for result: AnalysisKeyTestResult) -> Color {
        switch result {
        case .accepted: isFreeTier ? .orange : .green
        case .failed(.invalidKey): .red
        case .failed: .orange
        }
    }
}

#Preview("Results") {
    Form {
        ForEach([AnalysisKeyTestResult.accepted, .failed(.invalidKey), .failed(.billingOrQuota)], id: \.self) { result in
            Section {
                Text("Field")
            } footer: {
                AnalysisKeyTestStatusLabel(
                    provider: .google,
                    isTesting: false,
                    result: result,
                    showsImplausibleWarning: false
                )
            }
        }
        Section {
            Text("Field")
        } footer: {
            AnalysisKeyTestStatusLabel(provider: .openai, isTesting: true, result: nil, showsImplausibleWarning: false)
        }
    }
    .preferredColorScheme(.dark)
}
