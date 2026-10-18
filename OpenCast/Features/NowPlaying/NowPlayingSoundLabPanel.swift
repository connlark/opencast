import SwiftUI

struct NowPlayingSoundLabPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let revealProgress: CGFloat
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool
    let adFreePassRow: NowPlayingSoundLabAdFreePassRowModel
    let transcriptionRow: NowPlayingSoundLabTranscriptionRowModel?
    let onAdFreePassAction: () -> Void
    let onTranscribeRemotely: () -> Void
    let onTranscriptAction: () -> Void
    let onAdFreePassBackgroundProbe: () -> Void

    static func collapsesToIconOnly(rowAreaWidth: CGFloat, isAccessibilitySize: Bool) -> Bool {
        NowPlayingSoundLabLayout.collapsesToIconOnly(
            rowAreaWidth: rowAreaWidth,
            isAccessibilitySize: isAccessibilitySize
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = NowPlayingSoundLabLayout(panelWidth: proxy.size.width)
            let protectedLeadingSpace = layout.artworkRailWidth + layout.artworkGutter
            let usesConstrainedHeight = dynamicTypeSize.isAccessibilitySize || proxy.size.height < 250
            let rowHeight = usesConstrainedHeight ? 44.0 : NowPlayingSoundLabLayout.controlRowHeight
            let rowSpacing = usesConstrainedHeight ? 14.0 : (proxy.size.height > 290 ? 7.0 : 5.0)
            let isIconOnly = Self.collapsesToIconOnly(
                rowAreaWidth: layout.rowAreaWidth,
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
                .frame(width: max(0, layout.artworkRailWidth - layout.contentInset))
                .padding(.leading, layout.contentInset)
                .opacity(0.46 + 0.30 * Double(revealProgress))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: rowSpacing) {
                    if !usesConstrainedHeight {
                        Label {
                            Text("Sound Lab")
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.yellow)
                                .shadow(color: .yellow.opacity(0.32), radius: 4)
                        }
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .padding(.bottom, 3)
                    }

                    GlassEffectContainer(spacing: rowSpacing) {
                        VStack(spacing: rowSpacing) {
                            NowPlayingSoundLabToggle(
                                title: "Voice Boost",
                                systemImage: "waveform",
                                tint: .cyan,
                                isEnabled: voiceBoostControlEnabled,
                                isIconOnly: isIconOnly,
                                rowHeight: rowHeight,
                                isOn: $voiceBoostEnabled
                            )

                            NowPlayingSoundLabActionRow(
                                title: adFreePassRow.title,
                                systemImage: "megaphone",
                                tint: adFreePassTint,
                                phase: adFreePassRow.phase,
                                isEnabled: adFreePassRow.isEnabled,
                                isIconOnly: isIconOnly,
                                rowHeight: rowHeight,
                                accessibilityValueText: adFreePassRow.statusText,
                                accessibilityID: "Skip Promos & Ads",
                                action: onAdFreePassAction
                            )

                            if let transcriptionRow {
                                NowPlayingSoundLabActionRow(
                                    title: transcriptionRow.title,
                                    systemImage: transcriptionRow.systemImage,
                                    tint: .blue,
                                    phase: transcriptionRow.phase,
                                    isEnabled: transcriptionRow.isEnabled,
                                    isIconOnly: isIconOnly,
                                    rowHeight: rowHeight,
                                    accessibilityValueText: transcriptionRow.accessibilityValue,
                                    accessibilityID: transcriptionRow.accessibilityIdentifier,
                                    action: performTranscriptionAction
                                )
                            }
                        }
                    }

                    #if DEBUG
                    if AdFreePassBackgroundProbe.isUserInterfaceEnabled {
                        NowPlayingSoundLabAdFreePassBackgroundProbeControl(
                            onRun: onAdFreePassBackgroundProbe
                        )
                    }
                    #endif
                }
                .padding(.leading, protectedLeadingSpace)
                .padding(.trailing, layout.contentInset)
                .padding(.vertical, layout.contentInset)
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

    private func performTranscriptionAction() {
        switch transcriptionRow?.action {
        case .transcribe:
            onTranscribeRemotely()
        case .transcribeLocally, .showTranscript:
            onTranscriptAction()
        case nil:
            break
        }
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
