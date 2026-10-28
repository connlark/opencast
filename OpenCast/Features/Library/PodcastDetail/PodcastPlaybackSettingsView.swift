import OpenCastPlayback
import SwiftData
import SwiftUI

struct PodcastPlaybackSettingsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let feedURL: String

    @State private var isCustomSpeedOn = false
    @State private var customSpeed: Float = 1
    @State private var isAutoAddOn = false
    /// Bottom until the show has a position of its own, so a show turned
    /// on here starts at Bottom.
    @State private var autoAddPosition: UpNextAutoAddPosition = .bottom
    @State private var introText = "0:00"
    @State private var outroText = "0:00"
    @State private var errorMessage: String?

    private static let errorRowID = "podcast-playback-settings-error"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        Toggle("Custom Speed", isOn: $isCustomSpeedOn)
                            .accessibilityIdentifier("podcast-playback-settings-custom-speed-toggle")

                        if isCustomSpeedOn {
                            Picker("Speed", selection: $customSpeed) {
                                ForEach(PlaybackRateSteps.steps, id: \.self) { speed in
                                    Text(speed.formattedSpeed)
                                        .tag(speed)
                                }
                            }
                            .accessibilityIdentifier("podcast-playback-settings-speed-picker")
                        }
                    } header: {
                        Text("Speed")
                    } footer: {
                        Text(
                            isCustomSpeedOn
                                ? "Episodes of this show play at this speed. Changing the speed in Now Playing while this show is playing updates this show only."
                                : "Episodes of this show play at your global speed."
                        )
                    }

                    Section {
                        Toggle("Add to Up Next", isOn: $isAutoAddOn)
                            .accessibilityIdentifier("podcast-playback-settings-add-to-up-next-toggle")

                        if isAutoAddOn {
                            Picker("Position in Queue", selection: $autoAddPosition) {
                                ForEach(UpNextAutoAddPosition.allCases) { position in
                                    Text(position.title)
                                        .tag(position)
                                }
                            }
                            .accessibilityIdentifier("podcast-playback-settings-up-next-position-picker")
                        }
                    } header: {
                        Text("Up Next")
                    } footer: {
                        Text("\(autoAddRuleSentence) Change the limit in Settings › Playback › Auto Add to Up Next.")
                    }

                    Section {
                        PodcastPlaybackSkipRow(
                            title: "Skip Intro",
                            fieldAccessibilityIdentifier: "Skip Intro Duration",
                            text: $introText,
                            onDecrease: decreaseIntro,
                            onIncrease: increaseIntro
                        )

                        PodcastPlaybackSkipRow(
                            title: "Skip Outro",
                            fieldAccessibilityIdentifier: "Skip Outro Duration",
                            text: $outroText,
                            onDecrease: decreaseOutro,
                            onIncrease: increaseOutro
                        )

                        // Beside the fields it is about; in a section of its own
                        // it would sit below the medium detent's edge.
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("Podcast Playback Settings Error")
                                .id(Self.errorRowID)
                        }

                        Button("Reset Both", systemImage: "arrow.counterclockwise", role: .destructive, action: resetBoth)
                    } footer: {
                        Text("Enter m:ss or h:mm:ss. Changes apply the next time an episode loads or replays.")
                    }
                }
                .onChange(of: introText) { _, _ in
                    errorMessage = nil
                }
                .onChange(of: outroText) { _, _ in
                    errorMessage = nil
                }
                .onChange(of: isCustomSpeedOn) { _, isOn in
                    seedCustomSpeedFromGlobal(isOn: isOn)
                }
                .onChange(of: errorMessage) { _, message in
                    revealError(message, with: proxy)
                }
                .navigationTitle("Playback Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: dismiss.callAsFunction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                    }
                }
                .onAppear(perform: loadSettings)
            }
        }
    }

    private var autoAddRuleSentence: String {
        UpNextAutoAddCopy.ruleSentence(
            limit: appModel.upNextAutoAddSettings.limit,
            limitReachedAction: appModel.upNextAutoAddSettings.limitReachedAction
        )
    }

    private func loadSettings() {
        let rateOverride = appModel.library.podcastPlaybackRateOverride(forPodcastID: feedURL)
        isCustomSpeedOn = rateOverride != nil
        customSpeed = PodcastPlaybackRateOverride.nearestStep(
            to: rateOverride ?? appModel.playbackSettings.globalPlaybackRate
        )
        let settings = appModel.library.podcastPlaybackSkipSettings(forPodcastID: feedURL)
        introText = PodcastPlaybackDurationText.format(settings.skipIntroSeconds)
        outroText = PodcastPlaybackDurationText.format(settings.skipOutroSeconds)
        let savedAutoAddPosition = appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL)
        isAutoAddOn = savedAutoAddPosition != nil
        autoAddPosition = savedAutoAddPosition ?? .bottom
    }

    /// A show with no saved speed starts from the global speed as it is
    /// now, which may have changed since the sheet opened.
    private func seedCustomSpeedFromGlobal(isOn: Bool) {
        guard isOn, appModel.library.podcastPlaybackRateOverride(forPodcastID: feedURL) == nil else {
            return
        }
        customSpeed = PodcastPlaybackRateOverride.nearestStep(to: appModel.playbackSettings.globalPlaybackRate)
    }

    /// The Up Next section leaves the skip rows, and the error beside them,
    /// below the medium detent's edge, so a new error scrolls into view.
    private func revealError(_ message: String?, with proxy: ScrollViewProxy) {
        guard message != nil else {
            return
        }
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(Self.errorRowID, anchor: .center)
        }
    }

    private func decreaseIntro() {
        adjust(&introText, by: -5)
    }

    private func increaseIntro() {
        adjust(&introText, by: 5)
    }

    private func decreaseOutro() {
        adjust(&outroText, by: -5)
    }

    private func increaseOutro() {
        adjust(&outroText, by: 5)
    }

    private func adjust(_ text: inout String, by adjustment: TimeInterval) {
        guard let seconds = PodcastPlaybackDurationText.parse(text) else {
            errorMessage = "Enter each duration as m:ss or h:mm:ss."
            return
        }
        text = PodcastPlaybackDurationText.format(max(0, seconds + adjustment))
        errorMessage = nil
    }

    private func resetBoth() {
        introText = PodcastPlaybackDurationText.format(0)
        outroText = PodcastPlaybackDurationText.format(0)
        errorMessage = nil
    }

    private func save() {
        guard let skipIntroSeconds = PodcastPlaybackDurationText.parse(introText),
              let skipOutroSeconds = PodcastPlaybackDurationText.parse(outroText)
        else {
            errorMessage = "Enter each duration as m:ss or h:mm:ss."
            return
        }

        let failure = appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(
                skipIntroSeconds: skipIntroSeconds,
                skipOutroSeconds: skipOutroSeconds
            ),
            rateOverride: isCustomSpeedOn ? customSpeed : nil,
            upNextAutoAdd: isAutoAddOn ? autoAddPosition : nil,
            feedURL: feedURL,
            modelContext: modelContext
        )
        guard failure == nil else {
            errorMessage = failure
            return
        }
        dismiss()
    }
}
