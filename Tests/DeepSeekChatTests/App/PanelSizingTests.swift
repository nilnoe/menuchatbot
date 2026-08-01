import AppKit
import XCTest

@testable import DeepSeekChat

final class PanelSizingTests: XCTestCase {
    func testDefaultFrameFillsMostOfVisibleScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = PanelController.PanelSizing.defaultFrame(for: visible)
        XCTAssertEqual(frame.width, visible.width * 0.93, accuracy: 0.5)
        XCTAssertEqual(frame.height, visible.height * 0.93, accuracy: 0.5)
        XCTAssertGreaterThan(frame.width, visible.width * 0.9)
    }

    func testDefaultFrameCentered() {
        let visible = NSRect(x: 100, y: 200, width: 1728, height: 1117)
        let frame = PanelController.PanelSizing.defaultFrame(for: visible)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.5)
    }

    /// 每个窗口大小档位都应按对应比例铺开并居中（0.3 设置页档位共用此计算）。
    func testFrameForEveryWindowSizePreset() {
        let visible = NSRect(x: 100, y: 200, width: 1728, height: 1117)
        for preset in WindowSizePreset.allCases {
            let frame = PanelController.PanelSizing.frame(
                for: visible,
                fillRatio: preset.fillRatio
            )
            XCTAssertEqual(frame.width, visible.width * preset.fillRatio, accuracy: 0.5)
            XCTAssertEqual(frame.height, visible.height * preset.fillRatio, accuracy: 0.5)
            XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.5)
            XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.5)
        }
    }

    /// 档位比例必须在合理区间（不会把窗口缩成一条缝或撑出屏幕）。
    func testWindowSizePresetRatiosAreReasonable() {
        for preset in WindowSizePreset.allCases {
            XCTAssertGreaterThan(preset.fillRatio, 0.5)
            XCTAssertLessThanOrEqual(preset.fillRatio, 0.95)
        }
    }
}
