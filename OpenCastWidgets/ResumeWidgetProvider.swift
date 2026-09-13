import Foundation
import WidgetKit

struct ResumeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ResumeWidgetEntry {
        ResumeWidgetEntry(date: .now, snapshot: ResumeWidgetSnapshot(episodeID: "preview", title: "Your next listen", showTitle: "OpenCast", updatedAt: .now, progressBucket: 0, artwork: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (ResumeWidgetEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ResumeWidgetEntry>) -> Void) {
        let entry = readEntry()
        var entries = [entry]
        if let snapshot = entry.snapshot, !snapshot.isStale(at: entry.date) {
            entries.append(ResumeWidgetEntry(date: snapshot.updatedAt.addingTimeInterval(ResumeWidgetSnapshot.staleInterval + 1), snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func readEntry() -> ResumeWidgetEntry {
        let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ResumeWidgetSnapshot.appGroup)
        return ResumeWidgetEntry(date: .now, snapshot: try? ResumeWidgetSnapshot.read(from: directory))
    }
}
