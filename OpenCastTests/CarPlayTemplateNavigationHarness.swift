import CarPlay
import Foundation
@testable import OpenCast

@MainActor
final class CarPlayTemplateNavigationHarness {
    var stack: [CPTemplate]
    private(set) var maximumDepth: Int
    private var pending: [(Bool) -> Void] = []

    var pendingCount: Int { pending.count }

    lazy var navigator = CarPlayTemplateNavigator(
        templates: { [unowned self] in stack },
        pop: { [unowned self] template, completion in
            pending.append { [unowned self] succeeded in
                if succeeded, let index = stack.firstIndex(where: { $0 === template }) {
                    stack = Array(stack.prefix(index + 1))
                }
                completion(succeeded, succeeded ? nil : CocoaError(.coderInvalidValue))
            }
        },
        push: { [unowned self] template, _, completion in
            pending.append { [unowned self] succeeded in
                if succeeded {
                    stack.append(template)
                    maximumDepth = max(maximumDepth, stack.count)
                }
                completion(succeeded, succeeded ? nil : CocoaError(.coderInvalidValue))
            }
        }
    )

    init(browseTitles: [String]) {
        stack = [CPListTemplate(title: "Root", sections: [])]
            + browseTitles.map { CPListTemplate(title: $0, sections: []) }
            + [CPNowPlayingTemplate.shared]
        maximumDepth = stack.count
    }

    func completeNext(succeeded: Bool = true) {
        pending.removeFirst()(succeeded)
    }
}
