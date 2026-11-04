import SwiftUI

/// Identifies one hosting navigation stack for as long as SwiftUI keeps it:
/// the stack container's `NavigationStack`, or one split detail stack (a new
/// one per detail root). Its host owns it in state; writers hold it weakly,
/// so once the host is gone (a switch, a new head, even a return to an
/// earlier head) everything that host handed out stops writing.
final class TwoPaneRootWriterToken {}

/// The writes one hosting stack may make to its section's canonical path:
/// its `NavigationStack` binding, its pages' visit scope and its detail
/// root's close. Each write is applied only while the writer is current:
/// its host is alive, the scene's container is the writer's, and, for a
/// split detail stack, its head is still the path's head. Reads always see
/// the live path.
struct TwoPaneRootWriter {
    enum Kind: Equatable {
        /// The stack container's `NavigationStack`, over the root content.
        case stack
        /// A split detail stack built for `head` (nil: the placeholder).
        case detail(head: AppRoute?)
    }

    let kind: Kind
    weak var token: TwoPaneRootWriterToken?
    let path: Binding<[AppRoute]>
    /// The scene's container, read live.
    let container: () -> TwoPaneRootContainer
    /// For the log only.
    var section = ""

    /// A host's writer. It captures only the token (weakly) and the two
    /// bindings, never the host: a closure over the host would keep its
    /// state, and so its token, alive after the host has gone.
    static func make(
        _ kind: Kind,
        token: TwoPaneRootWriterToken,
        path: Binding<[AppRoute]>,
        container: Binding<TwoPaneRootContainer>,
        section: String
    ) -> TwoPaneRootWriter {
        TwoPaneRootWriter(
            kind: kind,
            token: token,
            path: path,
            container: { container.wrappedValue },
            section: section
        )
    }

    var isCurrent: Bool {
        guard token != nil else {
            return false
        }
        switch kind {
        case .stack:
            return container() == .stack
        case .detail(let head):
            return container() == .split && path.wrappedValue.first == head
        }
    }

    /// The stack container's path: the whole section path.
    var stackPath: Binding<[AppRoute]> {
        Binding(
            get: { path.wrappedValue },
            set: { newPath in
                guard isCurrent, let updated = TwoPaneRootPath.writingStackPath(newPath, currentContainer: container())
                else {
                    TwoPaneRootLog.ignoredWrite("stack", section: section)
                    return
                }
                path.wrappedValue = updated
            }
        )
    }

    /// A split detail stack's path: the routes after the head.
    var detailSuffix: Binding<[AppRoute]> {
        Binding(
            get: { TwoPaneRootPath.suffix(of: path.wrappedValue) },
            set: { suffix in
                guard case .detail(let head) = kind, isCurrent,
                      let updated = TwoPaneRootPath.writingDetailSuffix(
                          suffix,
                          forHead: head,
                          into: path.wrappedValue,
                          currentContainer: container()
                      )
                else {
                    TwoPaneRootLog.ignoredWrite("detail", section: section)
                    return
                }
                path.wrappedValue = updated
            }
        )
    }

    /// The ledger as this stack's pages see it.
    func visitScope(_ state: TwoPaneRootVisitState) -> TwoPaneRootVisitScope {
        TwoPaneRootVisitScope(
            state: state,
            section: section,
            path: { path.wrappedValue },
            isCurrent: { isCurrent }
        )
    }

    /// The detail root's own close: clears the path while this detail stack
    /// is current and `route` is still its head.
    func closeAction(for route: AppRoute) -> TwoPaneRootCloseAction {
        TwoPaneRootCloseAction(route: route) {
            guard isCurrent, let updated = TwoPaneRootPath.closingRoot(route, in: path.wrappedValue) else {
                TwoPaneRootLog.ignoredWrite("close", section: section)
                return
            }
            path.wrappedValue = updated
        }
    }
}
