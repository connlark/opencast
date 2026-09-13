import SwiftUI
import WidgetKit

struct ResumeWidgetView: View {
    let entry: ResumeWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = entry.snapshot {
                HStack {
                    if let data = snapshot.artwork, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
                    } else {
                        Image(systemName: "headphones").font(.title).foregroundStyle(.tint)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
                }
                Text(snapshot.title).font(.headline).lineLimit(2)
                Text(snapshot.showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(snapshot.isStale(at: entry.date) ? "Open to Continue" : "Resume Playback")
                    .font(.caption).bold()
            } else {
                Image(systemName: "headphones").font(.largeTitle).foregroundStyle(.tint)
                Text("Ready when you are").font(.headline)
                Text("Choose an episode in OpenCast.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(entry.snapshot?.resumeURL ?? URL(string: "opencast://open"))
    }
}
