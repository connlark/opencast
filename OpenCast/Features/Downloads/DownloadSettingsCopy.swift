/// Copy Download Settings and a show's download settings share.
enum DownloadSettingsCopy {
    /// What Keep Downloaded and Delete Downloads After Played never remove,
    /// in short: the cleanup coordinator's in-use states. The trim's one
    /// other exception, an unplayed episode's transcript audio, is left out
    /// of the footer on purpose.
    static let keptDownloadsSentence = "The current episode and episodes being transcribed or scanned for ads are kept."

    /// What every removal of downloaded audio costs a scanned episode: its
    /// skips need the audio its transcript was made from. Always shown, as
    /// counting the scanned episodes among the removable ones would take a
    /// hash comparison per row.
    static let scannedEpisodesSentence = "Removing a scanned episode’s audio turns off its automatic ad skips until it is scanned again."

    /// A show's Download New Episodes footer, as its second paragraph. It
    /// names the spend: each scan uses the listener's key or trial.
    static let detectAdsInNewEpisodesFooter = "Detect Ads in New Episodes scans each of these downloads on this device as it arrives, so ad skips are ready before you play. Scans run while opencast is open or playing, and each uses your AI Services key or trial like any ad detection."
}
