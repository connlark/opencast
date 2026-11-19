/// Where a Settings screen opens: on the Settings tab, or, while the Up Next
/// Tab switch is on and there is no Settings tab, in the Library over the
/// Settings hub, so Back reaches the hub and then the Library.
struct SettingsOpening: Equatable {
    let section: AppSection
    let path: [AppRoute]

    static func opening(_ route: SettingsRoute, showsUpNextTab: Bool) -> SettingsOpening {
        guard showsUpNextTab else {
            return SettingsOpening(section: .settings, path: [.settings(route)])
        }
        return SettingsOpening(section: .library, path: libraryPath(continuing: [.settings(route)]))
    }

    /// The Library's path for Settings screens: the hub, then them.
    static func libraryPath(continuing settingsPath: [AppRoute]) -> [AppRoute] {
        [.settings(.hub)] + settingsPath
    }
}
