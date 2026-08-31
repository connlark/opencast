import Foundation
import OpenCastPlayback

/// Row assembly for every diagnostics section. Values are deliberately raw
/// and unredacted — full URLs, paths, and hashes — because the report exists
/// to debug real incidents.
extension EpisodeDiagnosticsModel {
    static func reportSection(generatedAt: Date) -> EpisodeDiagnosticsSection {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return EpisodeDiagnosticsSection(rows: [
            ("App Version", "\(version ?? "Unknown") (\(build ?? "Unknown"))"),
            ("OS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("Device", BenchmarkHarnessSupport.machineIdentifier()),
            ("Generated", EpisodeDiagnosticsFormatting.date(generatedAt)),
        ])
    }

    func episodeSection(
        appModel: OpenCastAppModel,
        episode: EpisodeListItemSnapshot?
    ) -> EpisodeDiagnosticsSection {
        guard let episode else {
            return EpisodeDiagnosticsSection(rows: [
                ("Episode ID", episodeID),
                ("Status", "Episode not found in library or downloads."),
            ])
        }

        let podcastCache = appModel.library.podcastCache(for: episode.podcastID)
        let subscription = appModel.library.subscriptions.first { $0.feedURL == episode.podcastID }
        var rows: [(String, String)] = [
            ("Episode ID", episode.episodeID),
            ("GUID", EpisodeDiagnosticsFormatting.value(episode.guid)),
            ("Feed URL", episode.podcastID),
            ("Enclosure URL", EpisodeDiagnosticsFormatting.value(episode.audioURL)),
            ("Podcast", episode.podcastTitle),
            ("Podcast Author", EpisodeDiagnosticsFormatting.value(podcastCache?.author)),
            ("RSS Duration", EpisodeDiagnosticsFormatting.seconds(episode.duration)),
            ("Published", EpisodeDiagnosticsFormatting.date(episode.publishedAt)),
            ("Cached At", EpisodeDiagnosticsFormatting.date(episode.cachedAt)),
            ("Artwork URL", EpisodeDiagnosticsFormatting.value(episode.artworkURL)),
            ("Subscribed", EpisodeDiagnosticsFormatting.bool(appModel.library.isActivelySubscribed(to: episode.podcastID))),
        ]
        if let subscription {
            rows.append(("Subscribed Since", EpisodeDiagnosticsFormatting.date(subscription.subscribedAt)))
            rows.append(("Archived", EpisodeDiagnosticsFormatting.bool(subscription.isArchived)))
        }
        if let refreshLog = appModel.library.latestRefreshLog(feedURL: episode.podcastID) {
            rows.append(("Last Refresh Started", EpisodeDiagnosticsFormatting.date(refreshLog.startedAt)))
            rows.append(("Last Refresh Finished", EpisodeDiagnosticsFormatting.date(refreshLog.finishedAt)))
            rows.append(("Last Refresh Result", Self.refreshResult(refreshLog)))
        } else {
            rows.append(("Last Refresh", "Never"))
        }
        return EpisodeDiagnosticsSection(rows: rows)
    }

    private static func refreshResult(_ log: RefreshLogSnapshot) -> String {
        if let message = log.errorMessage, !message.isEmpty {
            return message == RefreshLogSnapshot.partialFeedSalvageMessage ? "Partial: \(message)" : "Failed: \(message)"
        }
        return log.finishedAt == nil ? "Interrupted or still running" : "Success"
    }

    func progressAndSettingsSection(
        appModel: OpenCastAppModel,
        episode: EpisodeListItemSnapshot?
    ) -> EpisodeDiagnosticsSection {
        var rows: [(String, String)] = []
        if let progressRecord = appModel.library.progressRecord(for: episodeID) {
            rows.append(("Position", EpisodeDiagnosticsFormatting.seconds(progressRecord.position)))
            rows.append(("Progress Duration", EpisodeDiagnosticsFormatting.seconds(progressRecord.duration)))
            rows.append(("Played", EpisodeDiagnosticsFormatting.bool(progressRecord.isPlayed)))
            rows.append(("Progress Updated", EpisodeDiagnosticsFormatting.date(progressRecord.updatedAt)))
        } else {
            rows.append(("Progress", "No progress record."))
        }

        let detectionMode: String = switch appModel.adDetectionSettings.mode {
        case .onDevice:
            "On-Device"
        case .cloud:
            "Cloud"
        case nil:
            "Ask First Time"
        }
        rows.append(("Detection Mode", detectionMode))
        rows.append((
            "Auto-Skip Promos & Ads",
            EpisodeDiagnosticsFormatting.bool(appModel.playbackSettings.isAutoSkipPromosAndAdsEnabled)
        ))

        if let episode {
            rows.append((
                "Auto Ad Detection (Show)",
                EpisodeDiagnosticsFormatting.bool(appModel.library.isAdAutoDetectEnabled(forPodcastID: episode.podcastID))
            ))
            let skipSettings = appModel.library.podcastPlaybackSkipSettings(forPodcastID: episode.podcastID)
            rows.append(("Skip Intro (Show)", EpisodeDiagnosticsFormatting.seconds(skipSettings.skipIntroSeconds)))
            rows.append(("Skip Outro (Show)", EpisodeDiagnosticsFormatting.seconds(skipSettings.skipOutroSeconds)))
        }
        return EpisodeDiagnosticsSection(rows: rows)
    }

    func playbackSection(snapshot: EpisodeDiagnosticsPlaybackSnapshot) -> EpisodeDiagnosticsSection {
        guard snapshot.isCurrentEpisode(episodeID) else {
            return EpisodeDiagnosticsSection(rows: [("Status", "Episode not currently loaded.")])
        }

        var rows: [(String, String)] = [
            ("State", snapshot.stateDescription),
            ("Rate", snapshot.rate.formatted(.number.precision(.fractionLength(2)))),
            ("Position", EpisodeDiagnosticsFormatting.seconds(snapshot.position)),
            ("Player Duration", EpisodeDiagnosticsFormatting.seconds(snapshot.duration)),
            ("Asset URL", EpisodeDiagnosticsFormatting.value(snapshot.assetURL)),
            ("Source Kind", EpisodeDiagnosticsFormatting.value(snapshot.sourceKindDescription)),
            ("Item Duration", EpisodeDiagnosticsFormatting.seconds(snapshot.itemDuration)),
            ("Auto-Skip Enabled", EpisodeDiagnosticsFormatting.bool(snapshot.isAutoSkipEnabled)),
            ("Installed Auto Zones", EpisodeDiagnosticsFormatting.zoneList(snapshot.installedAutoSkipZones)),
            ("Display-Only Zones", EpisodeDiagnosticsFormatting.zoneList(snapshot.displayOnlyZones)),
        ]
        if let zoneID = snapshot.lastAutoSkipZoneID, let sequence = snapshot.lastAutoSkipSequence {
            rows.append(("Last Auto Skip", "zone #\(zoneID) (event \(sequence))"))
        } else {
            rows.append(("Last Auto Skip", "None"))
        }
        return EpisodeDiagnosticsSection(rows: rows)
    }

    func downloadSection(
        record: EpisodeDownloadRecord,
        fileURL: URL?,
        byteProgress: DownloadByteProgress?,
        enrichment: DownloadEnrichment?
    ) -> EpisodeDiagnosticsSection {
        var rows: [(String, String)] = [
            ("State", record.state.rawValue),
            ("Source URL", record.sourceAudioURL),
            ("Relative Path", EpisodeDiagnosticsFormatting.value(record.localRelativePath)),
            ("File URL", EpisodeDiagnosticsFormatting.value(fileURL?.absoluteString)),
            ("Received", EpisodeDiagnosticsFormatting.byteCount(byteProgress?.bytesReceived ?? record.bytesReceived)),
            ("Expected", EpisodeDiagnosticsFormatting.byteCount(byteProgress?.bytesExpected ?? record.bytesExpected)),
            ("ETag", EpisodeDiagnosticsFormatting.value(record.entityTag)),
            ("Last-Modified", EpisodeDiagnosticsFormatting.value(record.lastModifiedHeader)),
            ("Recorded SHA-256", EpisodeDiagnosticsFormatting.value(record.sourceFileSHA256)),
            ("Created", EpisodeDiagnosticsFormatting.date(record.createdAt)),
            ("Updated", EpisodeDiagnosticsFormatting.date(record.updatedAt)),
        ]
        if let errorMessage = record.errorMessage {
            rows.append(("Error", errorMessage))
        }
        if let enrichment {
            if let fileInfo = enrichment.fileInfo {
                if let fileError = fileInfo.errorDescription {
                    rows.append(("File Check", "Failed: \(fileError)"))
                } else {
                    rows.append(("File Exists", EpisodeDiagnosticsFormatting.bool(fileInfo.exists)))
                    if fileInfo.exists {
                        rows.append(("File Size", EpisodeDiagnosticsFormatting.byteCount(fileInfo.byteCount)))
                        rows.append((
                            "Size Matches Received",
                            EpisodeDiagnosticsFormatting.bool(fileInfo.byteCount == record.bytesReceived)
                        ))
                    }
                }
            }
            if let computedSHA256 = enrichment.computedSHA256 {
                rows.append(("Computed SHA-256", computedSHA256))
                if !record.sourceFileSHA256.isEmpty {
                    rows.append((
                        "SHA-256 Matches Record",
                        EpisodeDiagnosticsFormatting.bool(computedSHA256 == record.sourceFileSHA256)
                    ))
                }
            } else if let sha256Error = enrichment.sha256ErrorDescription {
                rows.append(("Computed SHA-256", "Failed: \(sha256Error)"))
            }
            if let localDuration = enrichment.localDuration {
                rows.append(("Local Media Duration", EpisodeDiagnosticsFormatting.seconds(localDuration)))
            } else if let durationError = enrichment.localDurationErrorDescription {
                rows.append(("Local Media Duration", "Failed: \(durationError)"))
            }
        } else if record.localRelativePath == nil {
            rows.append(("File", "No file path recorded."))
        }
        return EpisodeDiagnosticsSection(rows: rows, footnote: "Stored on this device only.")
    }

    func transcriptSection(
        record: EpisodeTranscriptRecord,
        fileURL: URL?,
        outcome: DocumentOutcome<EpisodeTranscriptDocument>?
    ) -> EpisodeDiagnosticsSection {
        var rows: [(String, String)] = [
            ("State", record.state.rawValue),
            ("Engine", record.engineProvenance.rawValue),
            ("Model", EpisodeDiagnosticsFormatting.value(record.modelIdentifier)),
            ("Model Version", EpisodeDiagnosticsFormatting.value(record.modelVersion)),
            ("Language", record.languageCode),
            ("Measured Duration", EpisodeDiagnosticsFormatting.seconds(record.audioDuration)),
            ("Completed Duration", EpisodeDiagnosticsFormatting.seconds(record.completedDuration)),
            ("Checkpoints", "\(record.checkpointCount)"),
            ("Source SHA-256", EpisodeDiagnosticsFormatting.value(record.sourceFileSHA256)),
            ("Source Bytes", EpisodeDiagnosticsFormatting.byteCount(record.sourceFileByteCount)),
            ("Relative Path", EpisodeDiagnosticsFormatting.value(record.transcriptRelativePath)),
            ("File URL", EpisodeDiagnosticsFormatting.value(fileURL?.absoluteString)),
            ("Created", EpisodeDiagnosticsFormatting.date(record.createdAt)),
            ("Updated", EpisodeDiagnosticsFormatting.date(record.updatedAt)),
        ]
        if let errorMessage = record.errorMessage {
            rows.append(("Error", errorMessage))
        }
        if let outcome {
            if let fileInfo = outcome.fileInfo {
                if let fileError = fileInfo.errorDescription {
                    rows.append(("File Check", "Failed: \(fileError)"))
                } else {
                    rows.append(("File Exists", EpisodeDiagnosticsFormatting.bool(fileInfo.exists)))
                    if fileInfo.exists {
                        rows.append(("File Size", EpisodeDiagnosticsFormatting.byteCount(fileInfo.byteCount)))
                    }
                }
            }
            if let document = outcome.document {
                rows.append(("Document Schema", "\(document.schemaVersion)"))
                rows.append(("Segments", "\(document.segments.count)"))
                rows.append(("Text Length", "\(document.text.count)"))
                if let providerModel = document.providerModelIdentifier {
                    rows.append(("Provider Model", providerModel))
                }
                if let revision = document.providerModelRevision {
                    rows.append(("Provider Revision", revision))
                }
                if let matchMode = document.remoteSourceMatchMode {
                    rows.append(("Remote Match Mode", matchMode))
                }
            } else if let documentError = outcome.documentErrorDescription {
                rows.append(("Document Error", documentError))
            }
        }
        return EpisodeDiagnosticsSection(rows: rows)
    }

    func adAnalysisSection(
        record: EpisodeAdAnalysisRecord,
        fileURL: URL?,
        outcome: DocumentOutcome<EpisodeAdAnalysisDocument>?,
        isCurrentForTranscript: Bool?
    ) -> EpisodeDiagnosticsSection {
        var rows: [(String, String)] = [
            ("State", record.state.rawValue),
            ("Model", EpisodeDiagnosticsFormatting.value(record.model)),
            ("Policy", EpisodeDiagnosticsFormatting.value(record.policy)),
            ("Spans", "\(record.spanCount)"),
            ("Warnings", "\(record.warningCount)"),
            ("Transcript Fingerprint", EpisodeDiagnosticsFormatting.value(record.transcriptFingerprint)),
            ("Transcript Updated", EpisodeDiagnosticsFormatting.date(record.transcriptUpdatedAt)),
            ("Transcript Segments", "\(record.transcriptSegmentCount)"),
            ("Relative Path", EpisodeDiagnosticsFormatting.value(record.analysisRelativePath)),
            ("File URL", EpisodeDiagnosticsFormatting.value(fileURL?.absoluteString)),
            ("Job Accepted", EpisodeDiagnosticsFormatting.date(record.jobAcceptedAt)),
            ("Created", EpisodeDiagnosticsFormatting.date(record.createdAt)),
            ("Updated", EpisodeDiagnosticsFormatting.date(record.updatedAt)),
        ]
        if let failureKind = record.failureKind {
            rows.append(("Failure Kind", failureKind.rawValue))
        }
        if let errorMessage = record.errorMessage {
            rows.append(("Error", errorMessage))
        }
        if let outcome {
            if let fileInfo = outcome.fileInfo {
                if let fileError = fileInfo.errorDescription {
                    rows.append(("File Check", "Failed: \(fileError)"))
                } else {
                    rows.append(("File Exists", EpisodeDiagnosticsFormatting.bool(fileInfo.exists)))
                }
            }
            if let document = outcome.document {
                rows.append(("Request ID", document.requestID))
                if !document.warnings.isEmpty {
                    rows.append(("Warning Messages", document.warnings.joined(separator: " | ")))
                }
                if let usage = document.usage {
                    rows.append((
                        "Token Usage",
                        "prompt \(usage.promptTokenCount), candidates \(usage.candidatesTokenCount), total \(usage.totalTokenCount)"
                    ))
                }
                rows.append(("Document Updated", EpisodeDiagnosticsFormatting.date(document.updatedAt)))
            } else if let documentError = outcome.documentErrorDescription {
                rows.append(("Document Error", documentError))
            }
        }
        if let isCurrentForTranscript {
            rows.append(("Current For Transcript", EpisodeDiagnosticsFormatting.bool(isCurrentForTranscript)))
        }
        return EpisodeDiagnosticsSection(rows: rows)
    }

    func adSpansSection(outcome: DocumentOutcome<EpisodeAdAnalysisDocument>) -> EpisodeDiagnosticsSection {
        guard let document = outcome.document else {
            return EpisodeDiagnosticsSection(rows: [
                ("Status", outcome.documentErrorDescription ?? "No analysis document."),
            ])
        }

        var rows: [(String, String)] = [("Span Count", "\(document.spans.count)")]
        for span in document.spans {
            let tier = span.confidence >= EpisodeAdAnalysisZoneMapper.autoSkipConfidenceFloor
                ? "auto-skip"
                : "display-only"
            rows.append((
                "Span #\(span.id) — \(span.kind.displayName)",
                "\(EpisodeDiagnosticsFormatting.seconds(span.startTime))–\(EpisodeDiagnosticsFormatting.seconds(span.endTime)) • segments \(span.startSegmentID)–\(span.endSegmentID) • confidence \(span.confidence.formatted(.number.precision(.fractionLength(3)))) • \(tier)"
            ))
            if !span.evidenceQuote.isEmpty {
                rows.append(("Span #\(span.id) Evidence", span.evidenceQuote))
            }
        }
        return EpisodeDiagnosticsSection(
            rows: rows,
            footnote: "Raw spans as stored. Spans at or above confidence \(EpisodeAdAnalysisZoneMapper.autoSkipConfidenceFloor.formatted()) install as automatic skips; lower spans render display-only."
        )
    }

    func zoneMatrixSection(
        outcome: DocumentOutcome<EpisodeAdAnalysisDocument>,
        rssDuration: TimeInterval?,
        transcriptDuration: TimeInterval?,
        localMediaDuration: TimeInterval?,
        snapshot: EpisodeDiagnosticsPlaybackSnapshot
    ) -> EpisodeDiagnosticsSection {
        guard let document = outcome.document else {
            return EpisodeDiagnosticsSection(rows: [
                ("Status", outcome.documentErrorDescription ?? "No analysis document."),
            ])
        }

        let isCurrentEpisode = snapshot.isCurrentEpisode(episodeID)
        let namedDurations: [(label: String, duration: TimeInterval?)] = [
            ("RSS", rssDuration),
            ("Transcript", transcriptDuration),
            ("Local Media", localMediaDuration),
            ("Player", isCurrentEpisode ? snapshot.duration : nil),
        ]
        var bases = namedDurations.compactMap { named in
            named.duration.map { EpisodeDiagnosticsZoneMatrix.DurationBasis(label: named.label, duration: $0) }
        }
        bases.append(EpisodeDiagnosticsZoneMatrix.DurationBasis(label: "Unclamped", duration: nil))

        let matrix = EpisodeDiagnosticsZoneMatrix.make(
            document: document,
            bases: bases,
            installedAutoSkipZones: isCurrentEpisode ? snapshot.installedAutoSkipZones : nil
        )

        var rows: [(String, String)] = []
        for named in namedDurations where named.duration == nil {
            rows.append(("\(named.label) Duration", "Unavailable"))
        }
        for column in matrix.columns {
            let label = column.basis.label
            rows.append(("\(label) Duration", EpisodeDiagnosticsFormatting.seconds(column.basis.duration)))
            rows.append(("\(label) Auto Zones", EpisodeDiagnosticsFormatting.zoneList(column.autoSkipZones)))
            rows.append(("\(label) Display Zones", EpisodeDiagnosticsFormatting.zoneList(column.displayOnlyZones)))
            for spanOutcome in column.spanOutcomes {
                rows.append(("\(label) Span #\(spanOutcome.spanID)", Self.fateDescription(spanOutcome)))
            }
            if let matches = column.matchesInstalledAutoSkipZones {
                rows.append(("\(label) vs Installed", matches ? "Match" : "MISMATCH"))
            }
        }
        return EpisodeDiagnosticsSection(
            rows: rows,
            footnote: "Span fates come from the production zone mapper at each candidate duration. 'vs Installed' compares against the auto-skip zones active in the player right now."
        )
    }

    private static func fateDescription(_ outcome: EpisodeDiagnosticsZoneMatrix.SpanOutcome) -> String {
        var description: String = switch outcome.fate {
        case .preserved:
            "preserved"
        case .clamped(let startTime, let endTime):
            "clamped → \(EpisodeDiagnosticsFormatting.seconds(startTime))–\(EpisodeDiagnosticsFormatting.seconds(endTime))"
        case .dropped:
            "dropped"
        }
        if let mergedID = outcome.mergedIntoZoneID {
            description += " • merged into zone #\(mergedID)"
        }
        if !outcome.isAutoSkip {
            description += " • display-only tier"
        }
        return description
    }

    func chaptersSummarySection(appModel: OpenCastAppModel) -> EpisodeDiagnosticsSection {
        guard let record = appModel.transcriptAnalyses.record(for: episodeID) else {
            return EpisodeDiagnosticsSection(rows: [("Status", "No chapters/summary record.")])
        }
        let fileURL = appModel.transcriptAnalyses.diagnosticsDocumentFileURL(for: episodeID)
        var rows: [(String, String)] = [
            ("State", record.state.rawValue),
            ("Model", EpisodeDiagnosticsFormatting.value(record.model)),
            ("Policy", EpisodeDiagnosticsFormatting.value(record.policy)),
            ("Chapters", "\(record.chapterCount)"),
            ("Warnings", "\(record.warningCount)"),
            ("Relative Path", EpisodeDiagnosticsFormatting.value(record.analysisRelativePath)),
            ("File URL", EpisodeDiagnosticsFormatting.value(fileURL?.absoluteString)),
            ("Updated", EpisodeDiagnosticsFormatting.date(record.updatedAt)),
        ]
        if let failureKind = record.failureKind {
            rows.append(("Failure Kind", failureKind.rawValue))
        }
        if let errorMessage = record.errorMessage {
            rows.append(("Error", errorMessage))
        }
        return EpisodeDiagnosticsSection(
            rows: rows,
            footnote: "Statuses and storage locations only; generated prose stays out of this report."
        )
    }

    static func probeSection(probe: EpisodeDiagnosticsHeadProbe, footnote: String?) -> EpisodeDiagnosticsSection {
        var rows: [(String, String)] = [("Requested URL", probe.requestedURL)]
        if probe.redirectURLs.isEmpty {
            rows.append(("Redirects", "None"))
        } else {
            for (index, redirectURL) in probe.redirectURLs.enumerated() {
                rows.append(("Redirect \(index + 1)", redirectURL))
            }
        }
        rows.append(("Final URL", EpisodeDiagnosticsFormatting.value(probe.finalURL)))
        rows.append(("Status", probe.statusCode.map(String.init) ?? "No response"))
        rows.append(("MIME Type", EpisodeDiagnosticsFormatting.value(probe.mimeType)))
        rows.append(("Content-Length", EpisodeDiagnosticsFormatting.byteCount(probe.contentLength)))
        rows.append(("Accept-Ranges", EpisodeDiagnosticsFormatting.value(probe.acceptRanges)))
        rows.append(("ETag", EpisodeDiagnosticsFormatting.value(probe.entityTag)))
        rows.append(("Last-Modified", EpisodeDiagnosticsFormatting.value(probe.lastModified)))
        if let errorDescription = probe.errorDescription {
            rows.append(("Error", errorDescription))
        }
        return EpisodeDiagnosticsSection(rows: rows, footnote: footnote)
    }
}
