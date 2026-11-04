import SwiftUI

/// What a split's sidebar gives the root content inside it: the route its
/// highlight follows (the path's head) and the activation that opens a
/// route as the detail's root. Absent everywhere else (the stack's root, the
/// detail column, other tabs, sheets), where links keep `NavigationLink`.
struct TwoPaneRootSidebar {
    let selectedRoute: AppRoute?
    let activate: (AppRoute) -> Void

    func isSelected(_ route: AppRoute) -> Bool {
        selectedRoute == route
    }
}

/// The split detail root's own close, for a page that closes itself with
/// `dismiss` (an unavailable page's Go Back, the feed migration's exit):
/// there the page is the detail stack's root, not a pushed page, so
/// `dismiss` cannot remove it. Set on the detail root only; a pushed page
/// keeps `dismiss`.
struct TwoPaneRootCloseAction {
    /// The detail root this closes.
    let route: AppRoute
    let close: () -> Void
}

extension EnvironmentValues {
    @Entry var twoPaneRootSidebar: TwoPaneRootSidebar?
    @Entry var twoPaneRootClose: TwoPaneRootCloseAction?
}

/// How a root item shows that it is the split's selection.
enum TwoPaneRootSelectionStyle {
    /// A `List` row: the row's background.
    case listRow
    /// A grid tile: a rounded background behind the tile.
    case tile
    /// An entry inside a shared row (the Library's collection rows).
    case inline
    /// A context menu's item: no highlight, the menu's own look.
    case menuItem
}

/// A root item that opens `route`. In a split's sidebar it is a button that
/// makes the route the detail's root and shows the selection; elsewhere it
/// is today's `NavigationLink(value:)`, which pushes in the stack (and in a
/// split's detail column).
struct TwoPaneRootLink<Label: View>: View {
    @Environment(\.twoPaneRootSidebar) private var sidebar

    let route: AppRoute
    var selectionStyle: TwoPaneRootSelectionStyle = .listRow
    @ViewBuilder let label: Label

    var body: some View {
        if let sidebar {
            if selectionStyle == .menuItem {
                Button {
                    sidebar.activate(route)
                } label: {
                    label
                }
            } else {
                Button {
                    sidebar.activate(route)
                } label: {
                    label
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .twoPaneRootSelection(route, style: selectionStyle)
            }
        } else {
            NavigationLink(value: route) {
                label
            }
        }
    }
}

/// The split's highlight on a root item whose route is the path's head.
private struct TwoPaneRootSelectionModifier: ViewModifier {
    @Environment(\.twoPaneRootSidebar) private var sidebar

    let route: AppRoute
    let style: TwoPaneRootSelectionStyle

    func body(content: Content) -> some View {
        if let sidebar {
            highlighted(content, isSelected: sidebar.isSelected(route))
        } else {
            // Outside a split's sidebar (every stack, the iPhone, the iPad)
            // the item is exactly as before.
            content
        }
    }

    @ViewBuilder
    private func highlighted(_ content: Content, isSelected: Bool) -> some View {
        switch style {
        case .listRow:
            content
                .listRowBackground(isSelected ? Self.rowHighlight : nil)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        case .tile:
            content
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Self.highlight)
                            .padding(-6)
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        case .inline:
            content
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Self.highlight)
                            .padding(.horizontal, -8)
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        case .menuItem:
            content
        }
    }

    /// The selected item's fill: a translucent gray that reads on the
    /// sidebar's white and on its grouped gray alike.
    private static let highlight = Color(uiColor: .systemFill)

    private static var rowHighlight: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(highlight)
            .padding(.horizontal, 10)
    }
}

extension View {
    /// Shows the split's selection on a root item that opens `route` through
    /// a callback rather than a `TwoPaneRootLink`. Nothing outside a split's
    /// sidebar.
    func twoPaneRootSelection(_ route: AppRoute, style: TwoPaneRootSelectionStyle = .listRow) -> some View {
        modifier(TwoPaneRootSelectionModifier(route: route, style: style))
    }
}
