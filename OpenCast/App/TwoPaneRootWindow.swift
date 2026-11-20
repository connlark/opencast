import OSLog
import SwiftUI

/// Pose and size come from one window-sized reader in the same layout pass,
/// never a column's size, the orientation, the idiom or the screen. The
/// vertical size class and the regions are for the log only.
nonisolated struct TwoPaneRootWindow: Equatable, Sendable {
    var pose: WindowPose
    var size: CGSize
    var horizontalSizeClass: UserInterfaceSizeClass?
    var verticalSizeClass: UserInterfaceSizeClass?
    var activeRegions: [CGRect]

    static let unmeasured = TwoPaneRootWindow(
        pose: .compact,
        size: .zero,
        horizontalSizeClass: nil,
        verticalSizeClass: nil,
        activeRegions: []
    )

    init(
        pose: WindowPose,
        size: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        activeRegions: [CGRect]
    ) {
        self.pose = pose
        self.size = size
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.activeRegions = activeRegions
    }

    init(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        size: CGSize,
        divisionRegions: [WindowDivisionRegion]
    ) {
        self.init(
            pose: WindowPose(horizontalSizeClass: horizontalSizeClass, divisionRegions: divisionRegions),
            size: size,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            activeRegions: divisionRegions.filter(\.isUsable).map(\.frame)
        )
    }
}

/// Ignores the safe area so its proxy is the window.
struct TwoPaneRootWindowReader: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let onChange: (TwoPaneRootWindow) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: window(in: proxy), initial: true) { _, window in
                    onChange(window)
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func window(in proxy: GeometryProxy) -> TwoPaneRootWindow {
        TwoPaneRootWindow(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            size: proxy.size,
            divisionRegions: WindowDivisionRegion.current(in: proxy)
        )
    }
}

nonisolated enum TwoPaneRootLog {
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "TwoPaneRoot")

    static func inputs(_ window: TwoPaneRootWindow, isFoldableScene: Bool, container: TwoPaneRootContainer) {
        guard isFoldableScene else {
            return
        }
        let regions = window.activeRegions.map { describe($0) }.joined(separator: ";")
        let line = "inputs pose=\(describe(window.pose)) size=\(describe(window.size)) hsc=\(describe(window.horizontalSizeClass)) vsc=\(describe(window.verticalSizeClass)) regions=[\(regions)] latch=\(isFoldableScene) rule=\(container.rawValue)"
        logger.notice("\(line, privacy: .public)")
    }

    static func containerChange(from old: TwoPaneRootContainer, to new: TwoPaneRootContainer) {
        logger.notice("container \(old.rawValue, privacy: .public) -> \(new.rawValue, privacy: .public)")
    }

    static func ignoredWrite(_ writer: String, section: String) {
        logger.notice("ignored \(writer, privacy: .public) write section=\(section, privacy: .public)")
    }

    static func describe(_ pose: WindowPose) -> String {
        switch pose {
        case .compact:
            "compact"
        case .regularFlat:
            "regularFlat"
        case .foldedVertical(let band):
            "foldedVertical@\(describe(band))"
        case .foldedHorizontal(let band):
            "foldedHorizontal@\(describe(band))"
        }
    }

    static func describe(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact:
            "compact"
        case .regular:
            "regular"
        case nil:
            "nil"
        @unknown default:
            "unknown"
        }
    }

    static func describe(_ size: CGSize) -> String {
        "\(rounded(size.width))x\(rounded(size.height))"
    }

    static func describe(_ rect: CGRect) -> String {
        "\(rounded(rect.minX)),\(rounded(rect.minY)),\(rounded(rect.width)),\(rounded(rect.height))"
    }

    private static func rounded(_ value: CGFloat) -> String {
        "\((value * 10).rounded() / 10)"
    }
}
