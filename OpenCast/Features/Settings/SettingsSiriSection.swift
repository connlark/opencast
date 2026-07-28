import SwiftUI

struct SettingsSiriSection: View {
    var body: some View {
        Section {
            Label("“Play Security Now in OpenCast”", systemImage: "play.fill")
            Label("“Resume my podcast in OpenCast”", systemImage: "arrow.counterclockwise")
            Label("“Play at double speed in OpenCast”", systemImage: "gauge.with.dots.needle.67percent")
        } header: {
            Text("Siri")
        } footer: {
            Text("Include “in OpenCast” so Siri knows which podcast app to use.")
        }
    }
}
