import AppKit
import XCTest

@testable import DeepSeekChat

final class PanelSizingTests: XCTestCase {
    func testDefaultFrameFillsMostOfVisibleScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = AppDelegate.PanelSizing.defaultFrame(for: visible)
        XCTAssertEqual(frame.width, visible.width * 0.93, accuracy: 0.5)
        XCTAssertEqual(frame.height, visible.height * 0.93, accuracy: 0.5)
        XCTAssertGreaterThan(frame.width, visible.width * 0.9)
    }

    func testDefaultFrameCentered() {
        let visible = NSRect(x: 100, y: 200, width: 1728, height: 1117)
        let frame = AppDelegate.PanelSizing.defaultFrame(for: visible)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.5)
    }
}
