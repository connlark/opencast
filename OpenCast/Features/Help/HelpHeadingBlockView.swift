import SwiftUI

struct HelpHeadingBlockView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.bold())
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
