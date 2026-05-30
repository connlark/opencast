enum ForcedAppearance {
    case system
    case dark
    case light

    static func resolving(dark: Bool, light: Bool) -> ForcedAppearance {
        switch (dark, light) {
        case (true, false):
            .dark
        case (false, true):
            .light
        default:
            .system
        }
    }
}
