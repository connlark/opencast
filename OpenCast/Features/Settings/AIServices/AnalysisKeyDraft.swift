/// The key typed into the key sheet. Its text has no textual or reflected
/// form, so dumping the sheet's state never shows it.
nonisolated struct AnalysisKeyDraft: Equatable {
    var text = ""
}

nonisolated extension AnalysisKeyDraft: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "AnalysisKeyDraft(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
