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
                Text(AIServicesCopy.testResult(result, provider: provider))
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

    private func systemImage(for result: AnalysisKeyTestResult) -> String {
        switch result {
        case .accepted: "checkmark.circle.fill"
        case .failed(.invalidKey): "xmark.octagon.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(for result: AnalysisKeyTestResult) -> Color {
        switch result {
        case .accepted: .green
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
