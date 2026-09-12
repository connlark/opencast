#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import SwiftUI

struct NotificationRegistrationDiagnosticsSection: View {
    @State private var result: NotificationRegistrationDiagnosticResult?
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var registrationTask: Task<Void, Never>?

    private let service = NotificationRegistrationDiagnosticService()

    var body: some View {
        Section("Notification Registration") {
            Button("Register and Send Test Push", systemImage: "bell.badge", action: runRegistration)
                .disabled(isRunning)

            if isRunning {
                ProgressView("Running")
            }

            if let result {
                LabeledContent("Permission", value: result.permissionStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Permission, \(result.permissionStatus)")
                LabeledContent("APNs Registration", value: result.apnsRegistrationStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("APNs Registration, \(result.apnsRegistrationStatus)")
                LabeledContent("Worker Registration", value: result.workerRegistrationStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Worker Registration, \(result.workerRegistrationStatus)")
                LabeledContent("Test Push", value: result.testPushStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Test Push, \(result.testPushStatus)")
                LabeledContent("APNs Status", value: result.apnsStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("APNs Status, \(result.apnsStatus)")
                LabeledContent("Device Delivery", value: result.deviceDeliveryStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Device Delivery, \(result.deviceDeliveryStatus)")

                if let apnsError = result.apnsError {
                    Label(apnsError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                Text(result.detail)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: cancelRegistration)
    }

    private func runRegistration() {
        registrationTask?.cancel()

        isRunning = true
        errorMessage = nil
        result = nil

        registrationTask = Task {
            defer {
                isRunning = false
                registrationTask = nil
            }

            do {
                result = try await service.run()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelRegistration() {
        registrationTask?.cancel()
        registrationTask = nil
        isRunning = false
    }
}
#endif
