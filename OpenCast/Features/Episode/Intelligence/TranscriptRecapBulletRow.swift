import SwiftUI

struct TranscriptRecapBulletRow: View {
    let bullet: TranscriptRecapResultBullet
    let onSeek: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(bullet.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            TranscriptCitationChip(time: bullet.start, action: onSeek)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
