import OSLog
import SwiftUI

struct TwoPaneRootClearanceProbe: ViewModifier {
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "TwoPaneRoot")

    @Environment(TabAccessoryGeometryStore.self) private var accessoryStore: TabAccessoryGeometryStore?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var viewport: CGRect?

    let name: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newViewport in
                viewport = newViewport
            }
            .onChange(of: sample, initial: true) { _, sample in
                Self.log(name: name, sample: sample)
            }
    }

    private var sample: Sample {
        Sample(
            accessory: accessoryStore?.geometry ?? .absent,
            viewport: viewport,
            rowSpacing: LibraryGridMetrics.rowSpacing(
                isCompact: horizontalSizeClass == .compact || verticalSizeClass == .compact
            )
        )
    }

    private struct Sample: Equatable {
        var accessory: TabAccessoryGeometry
        var viewport: CGRect?
        var rowSpacing: Double
    }

    private static func log(name: String, sample: Sample) {
        guard let viewport = sample.viewport else {
            return
        }
        let clearance = sample.accessory.bottomClearance(over: viewport, rowSpacing: sample.rowSpacing)
        let accessory = sample.accessory.frame.map { TwoPaneRootLog.describe($0) } ?? "none"
        logger.notice(
            "clearance viewport=\(name, privacy: .public) frame=\(TwoPaneRootLog.describe(viewport), privacy: .public) accessory=\(String(describing: sample.accessory), privacy: .public) accessoryFrame=\(accessory, privacy: .public) rowGap=\(sample.rowSpacing, privacy: .public) clearance=\(clearance, privacy: .public)"
        )
    }
}

extension View {
    func twoPaneRootClearanceProbe(_ name: String) -> some View {
        modifier(TwoPaneRootClearanceProbe(name: name))
    }
}
