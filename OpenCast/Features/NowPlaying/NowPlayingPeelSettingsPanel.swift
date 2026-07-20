import SwiftUI

struct NowPlayingPeelSettingsPanel: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let revealProgress: CGFloat
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool
    let adFreePassRow: NowPlayingPeelAdFreePassRowModel
    let onAdFreePassAction: () -> Void
    let onTranscribeRemotely: () -> Void
    let onAdFreePassBackgroundProbe: () -> Void

    private static let iconOnlyRowAreaWidth: CGFloat = 150

    /// Rows drop their title text when the row area is tight (small-width
    /// phones) or Dynamic Type is at accessibility sizes; icon plus trailing
    /// glyph carry state and the title stays the accessibility label.
    static func collapsesToIconOnly(rowAreaWidth: CGFloat, isAccessibilitySize: Bool) -> Bool {
        isAccessibilitySize || rowAreaWidth < iconOnlyRowAreaWidth
    }

    var body: some View {
        GeometryReader { proxy in
            let contentInset = max(10, proxy.size.width * 0.04)
            let protectedLeadingSpace = max(108, proxy.size.width * 0.38)
            let rowSpacing = proxy.size.height > 290 ? 7.0 : 5.0
            let isIconOnly = Self.collapsesToIconOnly(
                rowAreaWidth: proxy.size.width - protectedLeadingSpace - contentInset,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(panelGradient)

                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.22), lineWidth: 1)

                VStack(spacing: 8) {
                    ForEach(0..<12, id: \.self) { _ in
                        Capsule()
                            .fill(.primary.opacity(0.13))
                            .frame(width: 3, height: 11)
                    }
                }
                .padding(.leading, contentInset + 8)
                .opacity(0.46 + 0.30 * Double(revealProgress))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: rowSpacing) {
                    Label("Sound Lab", systemImage: "sparkles")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.primary)
                        .padding(.bottom, 2)

                    NowPlayingPeelSettingsToggle(
                        title: "Voice Boost",
                        systemImage: "waveform",
                        tint: .cyan,
                        isEnabled: voiceBoostControlEnabled,
                        isIconOnly: isIconOnly,
                        isOn: $voiceBoostEnabled
                    )

                    NowPlayingPeelActionRow(
                        title: adFreePassRow.title,
                        systemImage: "megaphone",
                        tint: adFreePassTint,
                        trailingSystemImage: adFreePassRow.trailingSystemImage,
                        isEnabled: adFreePassRow.isEnabled,
                        isIconOnly: isIconOnly,
                        accessibilityValueText: adFreePassRow.statusText,
                        accessibilityID: "Skip Promos & Ads",
                        action: onAdFreePassAction
                    )

                    if appModel.remoteTranscriptionPurchases.isSurfaceVisible {
                        NowPlayingPeelActionRow(
                            title: "Transcribe Remotely",
                            systemImage: "cloud",
                            tint: .blue,
                            trailingSystemImage: "chevron.right",
                            isEnabled: !appModel.remoteTranscription.store.hasActiveRequest,
                            isIconOnly: isIconOnly,
                            accessibilityValueText: remoteTranscriptionAccessibilityValue,
                            accessibilityID: "Transcribe Remotely",
                            action: onTranscribeRemotely
                        )
                    }

                    #if DEBUG
                    if AdFreePassBackgroundProbe.isUserInterfaceEnabled {
                        NowPlayingPeelAdFreePassBackgroundProbeControl(
                            onRun: onAdFreePassBackgroundProbe
                        )
                    }
                    #endif
                }
                .padding(.leading, protectedLeadingSpace)
                .padding(.trailing, contentInset)
                .padding(.vertical, contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing Sound Lab")
        .accessibilityIdentifier("Now Playing Sound Lab")
    }

    private var adFreePassTint: Color {
        switch adFreePassRow.emphasis {
        case .failed:
            .orange
        case .completed:
            .green
        case .unavailable:
            .gray
        case .normal:
            .red
        }
    }

    private var remoteTranscriptionAccessibilityValue: String {
        appModel.remoteTranscription.store.hasActiveRequest
            ? String(localized: "Remote transcription in progress")
            : ""
    }

    private var panelGradient: LinearGradient {
        LinearGradient(
            colors: [
                .mint.opacity(0.20),
                .yellow.opacity(0.16),
                .pink.opacity(0.14),
                .cyan.opacity(0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
