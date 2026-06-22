import SwiftUI
import Testing
import UserNotifications

@Suite("Episode notification card layout")
@MainActor
struct EpisodeNotificationCardLayoutTests {
    @Test("Card fits largest accessibility Dynamic Type by requesting taller content")
    func cardFitsLargestAccessibilityDynamicType() {
        let view = EpisodeNotificationCardView(viewModel: Self.viewModel)
            .environment(\.dynamicTypeSize, .accessibility5)
        let controller = UIHostingController(rootView: view)
        let fittingWidth: CGFloat = 368
        let fittingHeight = controller.sizeThatFits(
            in: CGSize(width: fittingWidth, height: 1_200)
        ).height
        let initialRatioHeight = fittingWidth * 0.62

        #expect(fittingHeight > initialRatioHeight)
        #expect(fittingHeight < 1_200)
    }

    private static var viewModel: EpisodeNotificationViewModel {
        let content = UNMutableNotificationContent()
        content.title = "The Rest Is Science"
        content.subtitle = "A Paleontology Of The Future"
        content.userInfo = [
            "opencast": [
                "kind": "episode",
                "episode_duration_text": "1 HR 6 MIN",
                "episode_summary": "What will humanity leave behind? In this episode, Professor Hannah Fry and VSauce's Michael Stevens explore the traces humans leave behind.",
            ],
        ]
        return EpisodeNotificationViewModel(content: content)
    }
}
