import SwiftUI

struct HelpParagraphBlockView: View {
    let text: AttributedString

    var body: some View {
        Text(text)
            .textSelection(.enabled)
    }
}
