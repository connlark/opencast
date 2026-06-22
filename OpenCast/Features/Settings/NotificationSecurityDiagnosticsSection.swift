#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import SwiftUI

struct NotificationSecurityDiagnosticsSection: View {
    @State private var result: NotificationSecurityDiagnosticResult?
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var checkTask: Task<Void, Never>?

    private let service = NotificationSecurityDiagnosticService()

    var body: some View {
        Section("Notification Security") {
            Button("Run Check", systemImage: "checkmark.shield", action: runCheck)
                .disabled(isRunning)

            if isRunning {
                ProgressView("Running")
            }

            if let result {
                LabeledContent("App Attest", value: result.appAttestStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("App Attest, \(result.appAttestStatus)")
                LabeledContent("Rejected Proof", value: result.rejectedProofMessage)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Rejected Proof, \(result.rejectedProofMessage)")
                LabeledContent("Valid Proof", value: result.validProofMessage)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Valid Proof, \(result.validProofMessage)")
                Text(result.detail)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: cancelCheck)
    }

    private func runCheck() {
        checkTask?.cancel()

        isRunning = true
        errorMessage = nil
        result = nil

        checkTask = Task {
            defer {
                isRunning = false
                checkTask = nil
            }

            do {
                result = try await service.run()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelCheck() {
        checkTask?.cancel()
        checkTask = nil
        isRunning = false
    }
}
#endif
