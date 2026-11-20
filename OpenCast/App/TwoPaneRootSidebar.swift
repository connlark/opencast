import SwiftUI

/// Present only inside a split's sidebar; everywhere else links keep
/// `NavigationLink`.
struct TwoPaneRootSidebar {
    let selectedRoute: AppRoute?
    let activate: (AppRoute) -> Void

    func isSelected(_ route: AppRoute) -> Bool {
        selectedRoute == route
    }
}

/// Set on the split's detail root only, which `dismiss` cannot remove.
struct TwoPaneRootCloseAction {
    let route: AppRoute
    let close: () -> Void
}

extension EnvironmentValues {
    @Entry var twoPaneRootSidebar: TwoPaneRootSidebar?
    @Entry var twoPaneRootClose: TwoPaneRootCloseAction?
}

enum TwoPaneRootSelectionStyle {
    case listRow
    case tile
    case inline
    case menuItem
}

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

private struct TwoPaneRootSelectionModifier: ViewModifier {
    @Environment(\.twoPaneRootSidebar) private var sidebar

    let route: AppRoute
    let style: TwoPaneRootSelectionStyle

    func body(content: Content) -> some View {
        if let sidebar {
            highlighted(content, isSelected: sidebar.isSelected(route))
        } else {
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

    /// Translucent, so it reads on the sidebar's white and grouped gray alike.
    private static let highlight = Color(uiColor: .systemFill)

    private static var rowHighlight: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(highlight)
            .padding(.horizontal, 10)
    }
}

extension View {
    /// For a root item that opens `route` through a callback rather than a
    /// `TwoPaneRootLink`.
    func twoPaneRootSelection(_ route: AppRoute, style: TwoPaneRootSelectionStyle = .listRow) -> some View {
        modifier(TwoPaneRootSelectionModifier(route: route, style: style))
    }
}
