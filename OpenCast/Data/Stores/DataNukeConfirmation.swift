import Foundation

enum DataNukeConfirmation {
    static func isConfirmed(_ text: String) -> Bool {
        text
            .lowercased()
            .filter(\.isLetter)
            .contains("nuke")
    }
}
