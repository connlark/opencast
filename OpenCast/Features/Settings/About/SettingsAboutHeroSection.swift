import SwiftUI

struct SettingsAboutHeroSection: View {
    private static let heroSide = 256.0

    let model: SettingsAboutHeroModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    var body: some View {
        Section {
            VStack(spacing: 16) {
                hero
                    .frame(width: Self.heroSide, height: Self.heroSide)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("opencast glass icon")
                    .accessibilityValue(isShowingModel && model.showsBack ? "Engraved back: with thanks to gonzalo flirt and Derek Passen" : "Icon front")
                    .accessibilityAddTraits(.isImage)
                    // Dragging is the only visible way to turn the icon.
                    .accessibilityActions {
                        if isShowingModel {
                            Button("Turn Over", action: turnOver)
                        }
                    }
                    .accessibilityIdentifier("About Glass Hero")

                VStack(spacing: 4) {
                    Text("opencast")
                        .font(.title2.bold())
                    Text("skip ads. open source.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .task(id: wantsModel, loadModelIfWanted)
        .task(observeLowPowerMode)
        .task(observeThermalState)
    }

    @ViewBuilder
    private var hero: some View {
        if case .model(let animated) = presentation, model.loadState == .loaded {
            SettingsAboutGlassHeroView(model: model, animated: animated)
        } else {
            SettingsAboutHeroImage()
        }
    }

    private var presentation: SettingsAboutHeroPresentation {
        SettingsAboutHeroPolicy(
            reduceMotion: reduceMotion,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            thermalState: thermalState,
            scenePhase: scenePhase
        ).presentation
    }

    private var wantsModel: Bool {
        presentation != .staticImage
    }

    private var isShowingModel: Bool {
        wantsModel && model.loadState == .loaded
    }

    private func turnOver() {
        model.toggleFace(animated: !reduceMotion)
    }

    private func loadModelIfWanted() async {
        guard wantsModel else {
            return
        }
        await model.load()
    }

    private func observeLowPowerMode() async {
        for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func observeThermalState() async {
        for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }
}
