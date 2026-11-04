import SwiftUI
import Testing
@testable import OpenCast

/// The insets are fixtures shaped like A1's open-landscape reading (an 84 pt
/// trailing rail inset) and the pinned iPad's (none).
@Suite("Regular-width List margins inside the safe area")
struct SafeAreaHorizontalContentMarginsTests {
    @Test("Compact width keeps the system's margins")
    func compactWidth() {
        let margins = SafeAreaHorizontalContentMargins.margins(
            regularMargin: 32,
            isRegularWidth: false,
            safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
        )
        #expect(margins.leading == nil)
        #expect(margins.trailing == nil)
    }

    @Test("With no horizontal inset the margin is unchanged")
    func noInsetIsUnchanged() {
        let margins = SafeAreaHorizontalContentMargins.margins(
            regularMargin: 32,
            isRegularWidth: true,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )
        #expect(margins.leading == 32)
        #expect(margins.trailing == 32)
    }

    @Test("Beside a rail the margin counts from the safe edge", arguments: [(leading: CGFloat(0), trailing: CGFloat(84)), (leading: CGFloat(84), trailing: CGFloat(0))])
    func besideRail(leading: CGFloat, trailing: CGFloat) {
        let margins = SafeAreaHorizontalContentMargins.margins(
            regularMargin: 32,
            isRegularWidth: true,
            safeAreaInsets: EdgeInsets(top: 0, leading: leading, bottom: 34, trailing: trailing)
        )
        #expect(margins.leading == leading + 32)
        #expect(margins.trailing == trailing + 32)
    }
}
