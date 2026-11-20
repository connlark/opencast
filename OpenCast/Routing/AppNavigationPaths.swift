import SwiftUI

struct AppNavigationPaths: Equatable {
    private var pathsBySection: [AppSection: [AppRoute]] = [:]

    subscript(section: AppSection) -> [AppRoute] {
        get { pathsBySection[section] ?? [] }
        set { pathsBySection[section] = newValue }
    }

    mutating func removeAll() {
        pathsBySection.removeAll()
    }

    mutating func removeAll(where shouldRemove: (AppRoute) -> Bool) {
        for section in pathsBySection.keys {
            pathsBySection[section]?.removeAll(where: shouldRemove)
        }
    }
}

extension Binding where Value == AppNavigationPaths {
    subscript(section: AppSection) -> Binding<[AppRoute]> {
        Binding<[AppRoute]>(
            get: { wrappedValue[section] },
            set: { wrappedValue[section] = $0 }
        )
    }
}
