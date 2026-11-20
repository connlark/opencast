import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Sound Lab hosted fit")
struct NowPlayingSoundLabHostedFitTests {
    struct Rendered {
        let square: CGRect
        let views: [(view: UIView, frame: CGRect)]
        /// SwiftUI snaps rendered edges to the pixel grid: a frame can sit a pixel from its layout value.
        let pixel: CGFloat

        var rows: [CGRect] {
            views.filter { String(describing: type(of: $0.view)).contains("GlassInteraction") }.map(\.frame)
        }

        var switches: [CGRect] {
            views.filter { $0.view is UISwitch }.map(\.frame)
        }
    }

    static func threeRowPanel(side: CGFloat, dynamicTypeSize: DynamicTypeSize) -> some View {
        NowPlayingSoundLabPanel(
            presentation: .inline(revealProgress: 1),
            voiceBoostEnabled: .constant(true),
            voiceBoostControlEnabled: true,
            adFreePassRow: NowPlayingSoundLabAdFreePassRowModel(presentation: .idle),
            transcriptionRow: NowPlayingSoundLabTranscriptionRowModel(
                hasCompletedTranscript: true,
                mode: .local,
                remoteActivity: .none,
                localActivity: .none
            ),
            onAdFreePassAction: {},
            onTranscribeRemotely: {},
            onTranscriptAction: {},
            onAdFreePassBackgroundProbe: {}
        )
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    }

    // A unit-test host builds no accessibility elements, so frames come from the UIKit views. Raw
    // frames do not shrink when an ancestor clips them, so an overflowing control shows here.
    static func render(_ content: some View, square side: CGFloat) throws -> Rendered {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        host.view.layoutIfNeeded()

        var views: [(view: UIView, frame: CGRect)] = []
        func collect(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else {
                return
            }
            let frame = view.convert(view.bounds, to: window)
            if frame.width > 0, frame.height > 0 {
                views.append((view, frame))
            }
            view.subviews.forEach(collect)
        }
        host.view.subviews.forEach(collect)
        return Rendered(
            square: CGRect(x: 0, y: 0, width: side, height: side),
            views: views,
            pixel: 1 / window.traitCollection.displayScale
        )
    }

    static func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat) -> Bool {
        inner.minX >= outer.minX - tolerance && inner.minY >= outer.minY - tolerance
            && inner.maxX <= outer.maxX + tolerance && inner.maxY <= outer.maxY + tolerance
    }

    @Test(
        "Panel frames: every rendered control inside the square and clear of the derived close target",
        arguments: [
            (side: 154.0, size: DynamicTypeSize.large),
            (side: 156.33, size: .large),
            (side: 166.92, size: .accessibility4),
            (side: 214.24, size: .accessibility5),
            (side: 220.0, size: .large),
            (side: 280.8, size: .large)
        ]
    )
    func controlsInsideTheSquare(side: Double, size: DynamicTypeSize) throws {
        let side = CGFloat(side)
        let layout = NowPlayingSoundLabLayout(panelWidth: side)
        let rendered = try Self.render(Self.threeRowPanel(side: side, dynamicTypeSize: size), square: side)

        #expect(!rendered.views.isEmpty)
        for (view, frame) in rendered.views {
            #expect(
                Self.contains(rendered.square, frame, tolerance: rendered.pixel),
                "\(type(of: view)) \(frame) outside \(side)"
            )
        }

        let rows = rendered.rows
        #expect(rows.count == 3, "rows \(rows)")
        let switches = rendered.switches
        #expect(switches.count == 1, "switches \(switches)")

        let closeTarget = layout.artworkHitSpan(panelSide: side, isSettledOpen: true).upperBound
        for control in rows + switches {
            #expect(
                control.minX >= closeTarget - rendered.pixel,
                "control \(control) under the close target \(closeTarget)"
            )
            #expect(
                control.maxX <= side - layout.contentInset + rendered.pixel,
                "control \(control) past the trailing inset"
            )
        }
        let toggleRow = try #require(rows.min { $0.minY < $1.minY })
        let toggleSwitch = try #require(switches.first)
        #expect(
            Self.contains(toggleRow, toggleSwitch, tolerance: rendered.pixel),
            "switch \(toggleSwitch) row \(toggleRow)"
        )
    }

    @Test("Closed at L: the rows begin at 27.33 pt and the switch ends inside the 120 pt row")
    func closedAtLargeGeometry() throws {
        let side: CGFloat = 156.33
        let rendered = try Self.render(Self.threeRowPanel(side: side, dynamicTypeSize: .large), square: side)
        let rows = rendered.rows.sorted { $0.minY < $1.minY }
        try #require(rows.count == 3)
        for row in rows {
            #expect(abs(row.minX - 27.33) <= rendered.pixel, "row \(row)")
            #expect(abs(row.width - 120) <= rendered.pixel, "row \(row)")
        }
        #expect(abs(rows[0].minY - 9) <= rendered.pixel)
        #expect(abs(rows[0].height - 44) <= rendered.pixel)
        let toggleSwitch = try #require(rendered.switches.first)
        #expect(toggleSwitch.maxX <= rows[0].maxX)
    }
}
