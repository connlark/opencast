import SwiftUI

/// A smart playlist's rule as six glass chips that edit it in place:
/// Episodes, Shows, Sort, Length, Age and Limit. Each chip reads as its
/// current value. The chips only report a changed rule through `onChange`;
/// the caller saves it. At accessibility sizes they stack one per line.
struct SmartPlaylistRuleChips: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let rule: PlaylistRule
    let onChange: (PlaylistRule) -> Void

    private static let sortOptions = PodcastEpisodeSortOrder.allCases.map { sortOrder in
        (value: sortOrder, title: sortOrder.title)
    }
    private static let lengthOptions = PlaylistRuleLengthPreset.allCases.map { preset in
        (value: Optional(preset), title: preset.title)
    }
    private static let ageOptions = PlaylistRule.agePresets.map { days in
        (value: days, title: PlaylistRule.ageTitle(maximumAgeDays: days))
    }
    private static let limitOptions = PlaylistRule.limitPresets.map { limit in
        (value: limit, title: PlaylistRule.limitTitle(limit: limit))
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(FlowLayout(spacing: 8))

        GlassEffectContainer(spacing: 8) {
            layout {
                PlaylistEpisodesRuleMenu(rule: rule, onChange: commit)
                PlaylistShowsRuleMenu(rule: rule, onChange: commit)
                PlaylistRulePickerChip(
                    clause: "Sort",
                    systemImage: "arrow.up.arrow.down",
                    title: rule.sortTitle,
                    options: Self.sortOptions,
                    selection: sortOrderBinding
                )
                PlaylistRulePickerChip(
                    clause: "Length",
                    systemImage: "clock",
                    title: rule.lengthTitle,
                    accessibilityTitle: rule.lengthAccessibilityTitle,
                    options: Self.lengthOptions,
                    selection: lengthBinding
                )
                PlaylistRulePickerChip(
                    clause: "Age",
                    systemImage: "calendar",
                    title: rule.ageTitle,
                    options: Self.ageOptions,
                    selection: maximumAgeDaysBinding
                )
                PlaylistRulePickerChip(
                    clause: "Limit",
                    systemImage: "list.number",
                    title: rule.limitTitle,
                    options: Self.limitOptions,
                    selection: limitBinding
                )
            }
        }
        .font(.subheadline)
        // A menu label in a list row resolves the automatic label style to
        // icon-only, and a chip must read as its value. Set here, not on each
        // chip's Label: applied inside the menu's label closure it crashed
        // SwiftUI (EXC_BAD_ACCESS in the Shows menu's label) on iOS 27.
        .labelStyle(.titleAndIcon)
    }

    private var sortOrderBinding: Binding<PodcastEpisodeSortOrder> {
        Binding {
            rule.sortOrder
        } set: { sortOrder in
            var updated = rule
            updated.sortOrder = sortOrder
            commit(updated)
        }
    }

    /// Nil while the stored bounds match no preset, so no option is checked.
    private var lengthBinding: Binding<PlaylistRuleLengthPreset?> {
        Binding {
            PlaylistRuleLengthPreset.matching(
                minimumMinutes: rule.minimumMinutes,
                maximumMinutes: rule.maximumMinutes
            )
        } set: { preset in
            guard let preset else {
                return
            }
            var updated = rule
            updated.minimumMinutes = preset.minimumMinutes
            updated.maximumMinutes = preset.maximumMinutes
            commit(updated)
        }
    }

    private var maximumAgeDaysBinding: Binding<Int?> {
        Binding {
            rule.maximumAgeDays
        } set: { maximumAgeDays in
            var updated = rule
            updated.maximumAgeDays = maximumAgeDays
            commit(updated)
        }
    }

    private var limitBinding: Binding<Int?> {
        Binding {
            rule.limit
        } set: { limit in
            var updated = rule
            updated.limit = limit
            commit(updated)
        }
    }

    /// Re-picking the current option calls the binding too; only a real
    /// change reaches the caller.
    private func commit(_ updated: PlaylistRule) {
        let normalized = updated.normalized()
        guard normalized != rule else {
            return
        }
        onChange(normalized)
    }
}

#Preview("Dark") {
    SmartPlaylistRuleChips(rule: .default) { _ in }
        .padding()
        .tint(PlaylistTint.indigo.color)
        .environment(OpenCastAppModel())
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    SmartPlaylistRuleChips(
        rule: PlaylistRule(
            status: .inProgress,
            downloadedOnly: true,
            maximumMinutes: 45,
            maximumAgeDays: 30,
            sortOrder: .shortestFirst
        )
    ) { _ in }
        .padding()
        .frame(width: 360)
        .tint(PlaylistTint.yellow.color)
        .environment(OpenCastAppModel())
        .preferredColorScheme(.light)
}
