import SwiftUI

struct HelpLinkBlockView: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            Label(title, systemImage: "arrow.up.forward")
        }
        .buttonStyle(.glass)
    }
}
