/// The Library's Notes row counts the notes only while Show Note Button is
/// on, and again whenever a note changes.
struct LibraryNotesCountKey: Hashable {
    let isEnabled: Bool
    let revision: Int
}
