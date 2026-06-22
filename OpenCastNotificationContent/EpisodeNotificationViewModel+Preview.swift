import UIKit
import UserNotifications

extension EpisodeNotificationViewModel {
    static var preview: EpisodeNotificationViewModel {
        let content = UNMutableNotificationContent()
        content.title = "The Rest Is Science"
        content.subtitle = "A Paleontology Of The Future"
        content.body = "We spend the hour looking at deep time, fossil traces, and what future scientists might infer from the present."
        content.userInfo = [
            "opencast": [
                "kind": "episode",
                "episode_duration_text": "1 HR 6 MIN",
                "episode_summary": "We spend the hour looking at deep time, fossil traces, and what future scientists might infer from the present.",
            ],
        ]
        return EpisodeNotificationViewModel(content: content)
    }
}
