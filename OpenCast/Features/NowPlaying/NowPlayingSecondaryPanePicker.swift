import SwiftUI

struct NowPlayingSecondaryPanePicker: View {
    @Binding var selection: NowPlayingSecondaryPane

    var body: some View {
        Picker("Secondary Pane", selection: $selection) {
            ForEach(NowPlayingSecondaryPane.allCases) { pane in
                Text(pane.title).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(NowPlayingSecondaryPane.pickerAccessibilityIdentifier)
    }
}
