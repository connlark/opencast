import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case library
    case inbox
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .library:
            "Library"
        case .inbox:
            "Inbox"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            "books.vertical"
        case .inbox:
            "tray"
        case .settings:
            "gearshape"
        }
    }

    var label: some View {
        Label(title, systemImage: systemImage)
    }
}
