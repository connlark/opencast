struct SettingsOpening: Equatable {
    let section: AppSection
    let path: [AppRoute]

    static func opening(_ route: SettingsRoute, showsUpNextTab: Bool) -> SettingsOpening {
        guard showsUpNextTab else {
            return SettingsOpening(section: .settings, path: [.settings(route)])
        }
        return SettingsOpening(section: .library, path: libraryPath(continuing: [.settings(route)]))
    }

    static func libraryPath(continuing settingsPath: [AppRoute]) -> [AppRoute] {
        [.settings(.hub)] + settingsPath
    }
}
