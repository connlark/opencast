import SwiftUI

struct SettingsSiriSection: View {
    var body: some View {
        Section {
            Label("“Play Security Now in opencast”", systemImage: "play.fill")
            Label("“Resume my podcast in opencast”", systemImage: "arrow.counterclockwise")
            Label("“Play at double speed in opencast”", systemImage: "gauge.with.dots.needle.67percent")
        } header: {
            Text("Siri")
        } footer: {
            Text("Include “in opencast” so Siri knows which podcast app to use.")
        }
    }
}
