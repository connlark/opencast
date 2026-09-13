import SwiftUI
import WidgetKit

@main
struct OpenCastResumeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ResumeWidgetSnapshot.kind, provider: ResumeWidgetProvider()) { entry in
            ResumeWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Resume Playback")
        .description("Continue your current OpenCast episode.")
        .supportedFamilies([.systemSmall])
    }
}
