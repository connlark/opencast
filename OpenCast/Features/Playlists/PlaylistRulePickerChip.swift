import SwiftUI

/// A smart rule chip whose menu is one inline picker: Sort, Length, Age and
/// Limit. The label shows the current value; a stored value that matches no
/// option opens the menu with nothing checked.
struct PlaylistRulePickerChip<Value: Hashable>: View {
    let clause: String
    let systemImage: String
    let title: String
    /// The spoken value when the visible one abbreviates ("Under 45 minutes").
    var accessibilityTitle: String?
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        Menu {
            Picker(clause, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title)
                        .tag(option.value)
                }
            }
        } label: {
            PlaylistRuleChipLabel(title: title, systemImage: systemImage)
        }
        .smartRuleChipMenu(clause: clause, title: title, accessibilityTitle: accessibilityTitle)
    }
}
