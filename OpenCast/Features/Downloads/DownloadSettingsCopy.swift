enum DownloadSettingsCopy {
    /// Names the in-use states only; the trim's transcript-audio exception is left out on purpose.
    static let keptDownloadsSentence = "The current episode and episodes being transcribed or scanned for ads are kept."

    /// Shown always: showing it only when a scanned episode is removable takes a hash
    /// comparison per row.
    static let scannedEpisodesSentence = "Removing a scanned episode’s audio turns off its automatic ad skips until it is scanned again."

    static let detectAdsInNewEpisodesFooter = "Detect Ads in New Episodes scans each of these downloads on this device as it arrives, so ad skips are ready before you play. Scans run while opencast is open or playing, and each uses your AI Services key or trial like any ad detection."
}
