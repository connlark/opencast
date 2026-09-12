import SwiftUI

struct HelpRelatedTopicsView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let ids: [String]

    var body: some View {
        let topics = ids.compactMap(appModel.helpContent.topic)
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Related")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                ForEach(topics) { topic in
                    NavigationLink(value: AppRoute.settings(.helpTopic(id: topic.id))) {
                        Label(topic.title, systemImage: topic.symbol)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.top, 12)
        }
    }
}
