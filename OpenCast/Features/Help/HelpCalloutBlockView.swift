import SwiftUI

struct HelpCalloutBlockView: View {
    let symbol: String
    let title: String?
    let text: AttributedString

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.headline)
                }
                Text(text)
                    .font(.subheadline)
            }
        } icon: {
            Image(systemName: symbol)
                .font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
