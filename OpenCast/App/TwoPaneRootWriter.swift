import SwiftUI

/// Owned in state by one hosting stack and held weakly by its writers, so once
/// the host is gone (a switch, a new head, even a return to an earlier head)
/// everything it handed out stops writing.
final class TwoPaneRootWriterToken {}

struct TwoPaneRootWriter {
    enum Kind: Equatable {
        case stack
        /// A nil head is the placeholder.
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

    func visitScope(_ state: TwoPaneRootVisitState) -> TwoPaneRootVisitScope {
        TwoPaneRootVisitScope(
            state: state,
            section: section,
            path: { path.wrappedValue },
            isCurrent: { isCurrent }
        )
    }

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
