import Foundation

/// Copy for the Up Next tab accessory. Grammar agreement resolves only on
/// the attributed localization path; `String(localized:)` leaves the
/// inflection markup literal.
enum UpNextAccessoryText {
    static func subtitle(queuedCount: Int) -> String {
        String(AttributedString(localized: "Up Next · ^[\(queuedCount) episode](inflect: true)").characters)
    }

    static func queuedEpisodes(_ queuedCount: Int) -> String {
        String(AttributedString(localized: "^[\(queuedCount) episode](inflect: true) queued").characters)
    }
}
