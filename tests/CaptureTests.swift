import ScreenCaptureKit
import Testing

@testable import SkillIssue

@MainActor
struct CaptureTests {
    @Test(arguments: [
        (CGSize(width: 1512, height: 982), Float(2), CGSize(width: 2560, height: 1662)),
        (CGSize(width: 1512, height: 982), Float(1), CGSize(width: 1512, height: 982)),
        (CGSize(width: 1280, height: 720), Float(2), CGSize(width: 2560, height: 1440)),
        (CGSize(width: 2560, height: 1440), Float(2), CGSize(width: 2560, height: 1440)),
        (CGSize(width: 982, height: 1512), Float(2), CGSize(width: 1662, height: 2560)),
        (CGSize(width: 3440, height: 1440), Float(1), CGSize(width: 2560, height: 1071)),
        (CGSize(width: 2048, height: 1365), Float(1.25), CGSize(width: 2560, height: 1706)),
        (CGSize(width: 1, height: 10000), Float(1), CGSize(width: 1, height: 2560)),
    ])
    func screenshotUsesBackingPixelsAndFitsTheLongestEdge(
        contentSize: CGSize, pointPixelScale: Float, expected: CGSize
    ) throws {
        let config = try Capture.screenshotConfiguration(
            contentSize: contentSize, pointPixelScale: pointPixelScale)
        #expect(CGSize(width: config.width, height: config.height) == expected)
        #expect(!config.showsCursor)
    }

    @Test(arguments: [
        (CGSize.zero, Float(2)),
        (CGSize(width: 1512, height: 982), Float(0)),
        (CGSize(width: 1512, height: 982), Float(-1)),
        (CGSize(width: 1512, height: 982), Float.nan),
        (CGSize(width: 1512, height: 982), Float.infinity),
        (CGSize(width: CGFloat.infinity, height: 982), Float(2)),
    ])
    func invalidScreenshotGeometryFailsWithoutConvertingToInteger(
        contentSize: CGSize, pointPixelScale: Float
    ) {
        #expect(throws: AppFailure.self) {
            try Capture.screenshotConfiguration(
                contentSize: contentSize, pointPixelScale: pointPixelScale)
        }
    }
}
