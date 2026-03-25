import XCTest
import CoreGraphics
@testable import DropShot

final class DropShotTests: XCTestCase {
    func testShellBootstraps() {
        XCTAssertTrue(true)
    }

    func testScreenCaptureKitSourceRectFlipsYAxisIntoTopOrigin() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let selectedRect = CGRect(x: 240, y: 180, width: 830, height: 420)

        let sourceRect = ScreenCaptureManager.screenCaptureKitSourceRect(
            for: selectedRect,
            within: screenFrame
        )

        XCTAssertEqual(sourceRect.origin.x, 240)
        XCTAssertEqual(sourceRect.origin.y, 382)
        XCTAssertEqual(sourceRect.size.width, 830)
        XCTAssertEqual(sourceRect.size.height, 420)
    }

    func testScreenCaptureKitSourceRectClipsToScreenBoundsBeforeConversion() {
        let screenFrame = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let selectedRect = CGRect(x: 50, y: 20, width: 400, height: 200)

        let sourceRect = ScreenCaptureManager.screenCaptureKitSourceRect(
            for: selectedRect,
            within: screenFrame
        )

        XCTAssertEqual(sourceRect.origin.x, 0)
        XCTAssertEqual(sourceRect.origin.y, 650)
        XCTAssertEqual(sourceRect.size.width, 350)
        XCTAssertEqual(sourceRect.size.height, 170)
    }
}
