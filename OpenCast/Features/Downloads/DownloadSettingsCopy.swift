/// Copy Download Settings and a show's download settings share.
enum DownloadSettingsCopy {
    /// What Keep Downloaded and Delete Downloads After Played never remove,
    /// in short: the cleanup coordinator's in-use states. The trim's one
    /// other exception, an unplayed episode's transcript audio, is left out
    /// of the footer on purpose.
    static let keptDownloadsSentence = "The current episode and episodes being transcribed or scanned for ads are kept."
}
