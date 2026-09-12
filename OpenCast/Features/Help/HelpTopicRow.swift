import SwiftUI

struct HelpTopicRow: View {
    let topic: HelpTopic

    var body: some View {
        NavigationLink(value: AppRoute.settings(.helpTopic(id: topic.id))) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                    Text(topic.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: topic.symbol)
            }
        }
        .accessibilityIdentifier("Help Topic \(topic.id)")
    }
}
