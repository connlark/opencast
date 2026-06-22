import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var hostingController: UIHostingController<EpisodeNotificationCardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    func didReceive(_ notification: UNNotification) {
        let viewModel = EpisodeNotificationViewModel(notification: notification)
        let cardView = EpisodeNotificationCardView(viewModel: viewModel)

        if let hostingController {
            hostingController.rootView = cardView
        } else {
            installHostingController(with: cardView)
        }
    }

    private func updatePreferredContentSize() {
        guard let hostingController else {
            return
        }

        let width = view.bounds.width
        guard width > 0 else {
            return
        }

        let fittingSize = CGSize(width: width, height: 1_200)
        let height = ceil(hostingController.sizeThatFits(in: fittingSize).height)
        guard height.isFinite, height > 0 else {
            return
        }

        let nextSize = CGSize(width: width, height: height)
        guard abs(preferredContentSize.width - nextSize.width) > 0.5
            || abs(preferredContentSize.height - nextSize.height) > 0.5
        else {
            return
        }

        preferredContentSize = nextSize
    }

    private func installHostingController(with cardView: EpisodeNotificationCardView) {
        let hostingController = UIHostingController(rootView: cardView)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hostingController)
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
    }
}
