import SwiftUI
import Testing
@testable import OpenCast

/// The real sheet content presented through `.sheet(item:)` with the
/// player's detents, in a window the size of the Closed card and of the
/// pinned iPhone, read from the views SwiftUI renders through.
@MainActor
@Suite("Sound Lab sheet: hosted presentation")
struct NowPlayingSoundLabSheetPresentationTests {
    @Observable
    final class Presenter {
        var sheet: PlayerUtilitySheet?
        var dismissals = 0
    }

    struct Harness: View {
        @Bindable var presenter: Presenter

        var body: some View {
            Color.clear
                .sheet(item: $presenter.sheet, onDismiss: dismissed) { _ in
                    NowPlayingSoundLabPanel(
                        presentation: .sheet,
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
        }

        private func dismissed() {
            presenter.dismissals += 1
        }
    }

    /// Frames in `root`'s own points: the system draws the medium-detent
    /// sheet as a card inset from the window's sides and scaled to fit, so
    /// window coordinates are about 4 % smaller than the layout.
    static func rendered(in root: UIView) -> [(view: UIView, frame: CGRect)] {
        var views: [(view: UIView, frame: CGRect)] = []
        func collect(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else {
                return
            }
            let frame = view.convert(view.bounds, to: root)
            if frame.width > 0, frame.height > 0 {
                views.append((view, frame))
            }
            view.subviews.forEach(collect)
        }
        root.subviews.forEach(collect)
        return views
    }

    /// 466 × 678 is the Closed card (`NowPlayingContentMetricsTests`), 402 ×
    /// 874 the pinned iPhone; AX XXXL wraps the labels.
    @Test(
        "Presented, the sheet shows the three labelled rows and the switch inside it; dismissed, it is gone",
        arguments: [
            (width: 466.0, height: 678.0, size: DynamicTypeSize.large),
            (width: 402.0, height: 874.0, size: .large),
            (width: 466.0, height: 678.0, size: .accessibility5),
            (width: 402.0, height: 874.0, size: .accessibility5)
        ]
    )
    func presentsAndDismisses(width: Double, height: Double, size: DynamicTypeSize) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let presenter = Presenter()
        let host = UIHostingController(rootView: Harness(presenter: presenter).environment(\.dynamicTypeSize, size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let pixel = 1 / window.traitCollection.displayScale

        presenter.sheet = .soundLab
        #expect(await waitUntil(timeout: .seconds(10)) {
            host.presentedViewController?.isBeingPresented == false
        })
        let sheet = try #require(host.presentedViewController)
        // The rows' glass settles a moment after the presentation ends.
        try await Task.sleep(for: .milliseconds(300))
        sheet.view.layoutIfNeeded()
        let sheetBounds = sheet.view.bounds
        let views = Self.rendered(in: sheet.view)
        let rows = views.filter { String(describing: type(of: $0.view)).contains("GlassInteraction") }.map(\.frame)
        let switches = views.filter { $0.view is UISwitch }.map(\.frame)

        #expect(rows.count == 3, "rows \(rows)")
        #expect(switches.count == 1, "switches \(switches)")
        for row in rows {
            #expect(row.minX >= sheetBounds.minX - pixel && row.maxX <= sheetBounds.maxX + pixel, "row \(row) sheet \(sheetBounds)")
            // Labelled: each row spans the sheet's width, past the width
            // below which the panel drops its titles.
            #expect(row.width >= NowPlayingSoundLabLayout.iconOnlyRowAreaWidth, "row \(row)")
            #expect(row.height >= NowPlayingSoundLabLayout.compactRowHeight - pixel, "row \(row)")
        }
        let toggleRow = try #require(rows.min { $0.minY < $1.minY })
        let toggleSwitch = try #require(switches.first)
        #expect(toggleSwitch.minX >= toggleRow.minX - pixel && toggleSwitch.maxX <= toggleRow.maxX + pixel)
        #expect(toggleSwitch.minY >= toggleRow.minY - pixel && toggleSwitch.maxY <= toggleRow.maxY + pixel)
        if !size.isAccessibilitySize {
            // At the medium detent all three rows show on screen without scrolling.
            let visible = window.bounds
            for row in rows {
                let onScreen = sheet.view.convert(row, to: window)
                #expect(
                    onScreen.minY >= visible.minY - pixel && onScreen.maxY <= visible.maxY + pixel,
                    "row \(onScreen) window \(visible)"
                )
            }
        }

        presenter.sheet = nil
        #expect(await waitUntil(timeout: .seconds(10)) {
            host.presentedViewController == nil && presenter.dismissals == 1
        })
    }
}
