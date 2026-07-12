import SwiftUI

struct SymbolBadgeView: View {
    let systemImage: String
    let color: Color
    let isShowingProgress: Bool
    let fillOpacity: Double

    @ScaledMetric(relativeTo: .title3) private var badgeSize: CGFloat = 48

    init(
        systemImage: String,
        color: Color = .red,
        isShowingProgress: Bool = false,
        fillOpacity: Double = 0.14
    ) {
        self.systemImage = systemImage
        self.color = color
        self.isShowingProgress = isShowingProgress
        self.fillOpacity = fillOpacity
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: badgeSize - 2, height: badgeSize - 2)
                .opacity(fillOpacity)

            if isShowingProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.title3)
                    .bold()
                    .foregroundStyle(color)
            }
        }
        .frame(width: badgeSize, height: badgeSize)
        .accessibilityHidden(true)
    }
}
