import OSLog
import SwiftUI

/// The window as the two-pane roots read it: the pose and the size from ONE
/// window-sized reader in the same layout pass, never a column's size, the
/// Now Playing overlay's geometry, the orientation, the idiom or the screen.
/// The vertical size class and the region count ride along for the log only.
nonisolated struct TwoPaneRootWindow: Equatable, Sendable {
    var pose: WindowPose
    var size: CGSize
    var horizontalSizeClass: UserInterfaceSizeClass?
    var verticalSizeClass: UserInterfaceSizeClass?
    /// The usable (active) `.division` regions this layout reported.
    var activeRegions: [CGRect]

    /// Before the first layout: no size, no fold.
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

/// Reads the window for the two-pane roots. It is a sibling layer of the
/// tab view, as the Duo probes' overlay readers are, ignoring the safe area
/// so its proxy is the window; it reports on every change of size, size
/// class or `.division` region, the first layout included.
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

/// The two-pane roots' trace: every change of the rule's inputs and every
/// container change, so a fold's single-switch behaviour can be read back
/// from the log.
nonisolated enum TwoPaneRootLog {
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "TwoPaneRoot")

    /// Only in a foldable scene (the only scenes the rule can split): a scene
    /// that never reports a fold (every iPad, every other iPhone) logs
    /// nothing. The latch's arrival logs the inputs it found.
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
