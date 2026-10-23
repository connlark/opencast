import SwiftUI

/// The Storage screen's summary row: the bar, the downloads' total and the
/// device's free space.
struct DownloadsStorageSummaryView: View {
    @State private var availableByteCount: Int64?

    let model: DownloadsStorageGraphModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.segments.isEmpty {
                DownloadsStorageBarView(model: model)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    DownloadsStorageText.summary(
                        episodeCount: model.totalEpisodeCount,
                        byteCount: model.totalByteCount
                    )
                )
                if let availableByteCount {
                    Text("\(DownloadsStorageText.size(availableByteCount)) available on this device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: model.totalByteCount) {
            availableByteCount = await DownloadsDeviceCapacity.availableForImportantUsage()
        }
    }
}
