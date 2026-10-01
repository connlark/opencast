import CarPlay

/// Makes room for a list above Now Playing without changing ordinary browse
/// history until the driver actually opens Up Next or the current show.
final class CarPlayTemplateNavigator {
    typealias Completion = @MainActor (Bool, (any Error)?) -> Void

    private let templates: () -> [CPTemplate]
    private let pop: (CPTemplate, @escaping Completion) -> Void
    private let push: (CPTemplate, Bool, @escaping Completion) -> Void
    private var isNavigating = false
    private var isInvalidated = false

    init(
        templates: @escaping () -> [CPTemplate],
        pop: @escaping (CPTemplate, @escaping Completion) -> Void,
        push: @escaping (CPTemplate, Bool, @escaping Completion) -> Void
    ) {
        self.templates = templates
        self.pop = pop
        self.push = push
    }

    convenience init(interfaceController: CPInterfaceController) {
        self.init(
            templates: { interfaceController.templates },
            pop: { template, completion in
                interfaceController.pop(to: template, animated: false, completion: completion)
            },
            push: { template, animated, completion in
                interfaceController.pushTemplate(template, animated: animated, completion: completion)
            }
        )
    }

    func invalidate() {
        isInvalidated = true
    }

    func pushNowPlayingList(_ list: CPListTemplate, completion: @escaping Completion) {
        guard !isInvalidated, !isNavigating else { return }
        let stack = templates()
        guard let nowPlaying = stack.last as? CPNowPlayingTemplate else { return }

        isNavigating = true
        guard stack.count >= 5 else {
            pushList(list, completion: completion)
            return
        }

        // Keep root + two browse levels, then restore Now Playing at level
        // four. Its child list is level five, and Back still returns to it.
        pop(stack[2]) { [weak self] didPop, error in
            guard let self, !isInvalidated else { return }
            guard didPop else {
                finish(false, error: error, completion: completion)
                return
            }
            push(nowPlaying, false) { [weak self] didPush, error in
                guard let self, !isInvalidated else { return }
                guard didPush else {
                    finish(false, error: error, completion: completion)
                    return
                }
                pushList(list, completion: completion)
            }
        }
    }

    private func pushList(_ list: CPListTemplate, completion: @escaping Completion) {
        push(list, true) { [weak self] didPush, error in
            guard let self, !isInvalidated else { return }
            finish(didPush, error: error, completion: completion)
        }
    }

    private func finish(_ succeeded: Bool, error: (any Error)?, completion: Completion) {
        isNavigating = false
        completion(succeeded, error)
    }
}
