import SwiftUI

struct SettingsAppIconView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var chosenFamily: AppIconFamily?

    /// Opens on the family that holds the current icon and stays on whatever
    /// the user taps, so a rolled-back change cannot flip the tab under them.
    private var family: AppIconFamily {
        chosenFamily ?? appModel.appIcon.selection.family
    }

    private var familySelection: Binding<AppIconFamily> {
        Binding {
            family
        } set: { family in
            chosenFamily = family
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Icon Style", selection: familySelection) {
                    ForEach(AppIconFamily.allCases) { family in
                        Text(family.title)
                            .tag(family)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("App Icon Style")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(AppIconOption.options(in: family)) { option in
                    AppIconOptionRow(option: option)
                }

                if let message = appModel.appIcon.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                if !appModel.appIcon.isSupported {
                    Text("This device doesn't support changing the app icon.")
                }
            }
        }
        .animation(.default, value: family)
        .settingsSubscreen(title: "App Icon")
        .task(appModel.appIcon.load)
    }
}
