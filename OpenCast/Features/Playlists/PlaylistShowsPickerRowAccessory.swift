/// What a show picker row shows at its trailing edge: the Shows picker's
/// checkmark, or the Priority picker's add and remove controls.
enum PlaylistShowsPickerRowAccessory: Equatable {
    case checkmark(isSelected: Bool)
    case add
    case remove
}
