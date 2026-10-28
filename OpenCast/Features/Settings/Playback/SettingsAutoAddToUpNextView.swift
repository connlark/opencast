import SwiftData
import SwiftUI

/// Settings › Playback › Auto Add to Up Next: this device's limit and the
/// rule at the limit, then each show's position. Every control applies on
/// change.
struct SettingsAutoAddToUpNextView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let settings = appModel.upNextAutoAddSettings
        Form {
            Section {
                LabeledContent("Auto Add Limit") {
                    Picker("Auto Add Limit", selection: limitBinding) {
                        ForEach(UpNextAutoAddLimit.allCases) { limit in
                            Text(limit.title)
                                .tag(limit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("up-next-auto-add-limit-picker")
                }

                LabeledContent("If Limit Reached") {
                    Picker("If Limit Reached", selection: limitReachedActionBinding) {
                        ForEach(UpNextAutoAddLimitReachedAction.allCases) { action in
                            Text(action.shortTitle)
                                .tag(action)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("up-next-auto-add-limit-reached-picker")
                }

                if let message = settings.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(
                    UpNextAutoAddCopy.ruleSentence(
                        limit: settings.limit,
                        limitReachedAction: settings.limitReachedAction
                    )
                )
            }

            Section("Shows") {
                if appModel.library.subscriptions.isEmpty {
                    ContentUnavailableView(
                        "No Shows",
                        systemImage: "books.vertical",
                        description: Text("Subscribe to a show to add its new episodes to Up Next.")
                    )
                } else {
                    ForEach(appModel.library.subscriptions) { subscription in
                        UpNextAutoAddShowRow(subscription: subscription)
                    }
                }
            }
        }
        .settingsSubscreen(title: "Auto Add to Up Next")
    }

    private var limitBinding: Binding<UpNextAutoAddLimit> {
        Binding {
            appModel.upNextAutoAddSettings.limit
        } set: { limit in
            appModel.setUpNextAutoAddLimit(limit, modelContext: modelContext)
        }
    }

    private var limitReachedActionBinding: Binding<UpNextAutoAddLimitReachedAction> {
        Binding {
            appModel.upNextAutoAddSettings.limitReachedAction
        } set: { action in
            appModel.setUpNextAutoAddLimitReachedAction(action, modelContext: modelContext)
        }
    }
}
