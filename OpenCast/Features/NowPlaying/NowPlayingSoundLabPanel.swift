import SwiftUI

struct NowPlayingSoundLabPanel: View {
    /// Over the artwork from the panel's inline floor up; below it, the same
    /// controls in the player's utility sheet. Inline rows are the square's
    /// (`rowMetrics`) unless the panel opened beyond it with `titledRows`.
    enum Presentation: Equatable {
        case inline(revealProgress: CGFloat, titledRows: NowPlayingSoundLabOpenPanel.TitledRows? = nil)
        case sheet
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let presentation: Presentation
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool
    let adFreePassRow: NowPlayingSoundLabAdFreePassRowModel
    let transcriptionRow: NowPlayingSoundLabTranscriptionRowModel?
    let onAdFreePassAction: () -> Void
    let onTranscribeRemotely: () -> Void
    let onTranscriptAction: () -> Void
    let onAdFreePassBackgroundProbe: () -> Void

    static func constrainedRowSpacing(
        panelHeight: CGFloat,
        verticalInset: CGFloat,
        rowCount: Int,
        rowHeight: CGFloat
    ) -> CGFloat {
        NowPlayingSoundLabLayout.constrainedRowSpacing(
            panelHeight: panelHeight,
            verticalInset: verticalInset,
            rowCount: rowCount,
            rowHeight: rowHeight
        )
    }

    static func collapsesToIconOnly(rowAreaWidth: CGFloat, isAccessibilitySize: Bool) -> Bool {
        NowPlayingSoundLabLayout.collapsesToIconOnly(
            rowAreaWidth: rowAreaWidth,
            isAccessibilitySize: isAccessibilitySize
        )
    }

    var body: some View {
        switch presentation {
        case .inline(let revealProgress, let titledRows):
            inlinePanel(revealProgress: revealProgress, titledRows: titledRows)
        case .sheet:
            sheetPanel
        }
    }

    private func inlinePanel(
        revealProgress: CGFloat,
        titledRows: NowPlayingSoundLabOpenPanel.TitledRows?
    ) -> some View {
        GeometryReader { proxy in
            let layout = NowPlayingSoundLabLayout(panelWidth: proxy.size.width)
            let rows = titledRows?.rowMetrics ?? NowPlayingSoundLabLayout.rowMetrics(
                panelHeight: proxy.size.height,
                verticalInset: layout.contentInset,
                rowCount: transcriptionRow == nil ? 2 : 3,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            let isIconOnly = titledRows == nil && Self.collapsesToIconOnly(
                rowAreaWidth: layout.rowAreaWidth,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(panelGradient)

                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.22), lineWidth: 1)

                // Never taller than the panel: a taller rail would grow the
                // stack and push the rows out of the clip.
                VStack(spacing: NowPlayingSoundLabLayout.railCapsuleSpacing) {
                    ForEach(0..<NowPlayingSoundLabLayout.railCapsuleCount(panelHeight: proxy.size.height), id: \.self) { _ in
                        Capsule()
                            .fill(.primary.opacity(0.13))
                            .frame(
                                width: NowPlayingSoundLabLayout.railCapsuleWidth,
                                height: NowPlayingSoundLabLayout.railCapsuleHeight
                            )
                    }
                }
                .frame(width: max(0, layout.artworkRailWidth - layout.contentInset))
                .padding(.leading, layout.contentInset)
                .opacity(0.46 + 0.30 * Double(revealProgress))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: rows.rowSpacing) {
                    if rows.showsHeader {
                        Self.paddedHeader
                    }

                    controls(
                        isIconOnly: isIconOnly,
                        rowHeight: rows.rowHeight,
                        spacing: rows.rowSpacing,
                        capsuleFitsRow: titledRows != nil
                    )

                    backgroundProbeControl
                }
                .padding(.leading, layout.protectedLeadingSpace)
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

    private var sheetPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Self.header

                controls(isIconOnly: false, rowHeight: nil, spacing: 10, capsuleFitsRow: false)

                backgroundProbeControl
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing Sound Lab")
        .accessibilityIdentifier("Now Playing Sound Lab")
    }

    /// The heading as an inline panel lays it out, whose height the open
    /// rectangle counts once.
    static var paddedHeader: some View {
        header
            .padding(.bottom, NowPlayingSoundLabLayout.headingBottomPadding)
    }

    private static var header: some View {
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
    }

    private func controls(
        isIconOnly: Bool,
        rowHeight: CGFloat?,
        spacing: CGFloat,
        capsuleFitsRow: Bool
    ) -> some View {
        GlassEffectContainer(spacing: spacing) {
            VStack(spacing: spacing) {
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
                    capsuleFitsRow: capsuleFitsRow,
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
                        capsuleFitsRow: capsuleFitsRow,
                        action: performTranscriptionAction
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var backgroundProbeControl: some View {
        #if DEBUG
        if AdFreePassBackgroundProbe.isUserInterfaceEnabled {
            NowPlayingSoundLabAdFreePassBackgroundProbeControl(
                onRun: onAdFreePassBackgroundProbe
            )
        }
        #endif
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
